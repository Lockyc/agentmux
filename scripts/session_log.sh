#!/bin/sh
# session_log.sh — durable roster of the agent windows amux opens, for recovery
# after a tmux server dies (kill-server / reboot). POSIX sh; deps: tmux, jq, toml2json.
# Invoked as a subprocess (never sourced).
#
# Subcommands:
#   open  <agent> [target] [socket]   append an open record (target defaults to current
#                            pane; socket is only needed when invoked OUTSIDE the tmux
#                            server the session lives on — see _sl_ctx)
#   resume <label> <cmd> [fork_cmd] [target] [socket]
#                            append/refresh a generic resume hint (+ optional
#                            fork hint) for the current window. fork_cmd is owned by the
#                            agent adapter, never composed here — this core stays agnostic.
#                            target/socket serve the same CLI-path case as `open`: a
#                            caller outside the tmux server (amux's restore) names the
#                            window and shard it just created.
#   forkcmd [target]         emit `agent<TAB>fork_cmd` for one LIVE window (or nothing)
#   dropped <cwd>|--global|--new <cwd>
#                            restorable dropped tabs (dead server, open-at-death),
#                            one TSV row each; --new also marks them offered
#   dropped --pending <cwd>  the same question as a BOOLEAN, for warden's presence
#                            poll: one synthetic line if a restore would be offered
#                            here, nothing if not. Its consumer tests emptiness and
#                            never reads the row, which is what lets the sidecar
#                            fast path answer it. Exit code is three-state INSIDE
#                            that path (_sl_pending_fast: 0 = drop, 1 = none,
#                            2 = cannot answer → fall back to the ledger fold);
#                            the subcommand itself always exits 0
#   prune                    trim the ledger to what a query can still reach (every
#                            live server, plus the newest dead one per cwd)
#   snapshot <socket> <pid>  re-record a live server's window set (window-unlinked hook)
#   discard  <socket> <pid>  mark a server's windows deliberately closed (empty
#                            sidecar) — the amux --kill path, so a torn-down shard
#                            isn't recovered as a crash
#   migrate                  one-shot backfill: bring the sidecars already on disk up
#                            to the current contract (enrich legacy bare-id lines from
#                            the ledger, write missing `.sock` companions). Idempotent;
#                            never changes a sidecar's window-id membership
#
# We reconcile against the set of windows that were open. For a LIVE server that
# set is queried directly (tmux list-windows). A DEAD server can't be queried, so
# while alive each server keeps a per-(socket,pid) "live-set" sidecar at
# <state>/live/<sockethash>-<pid>.windows, overwritten in place — no growth. Each
# line is FOUR tab-separated fields: window_id, cwd, agent, resumable (the same
# facts sl_dropped needs to render a restore row without re-querying tmux). A
# line whose cwd is UNKNOWN — a bare single-field line (just window_id, no tabs,
# the pre-migration shape) or a four-field line from a window whose @amux_*
# options were never stamped (`@2<TAB><TAB><TAB>`) — is still accepted everywhere
# the sidecar is read (`cut -f1` on either returns the window id), and
# `_SL_SHAPE_FN` is the one place that tells the two apart. UNENFORCED,
# deliberately: `cwd` is user
# data (a launch dir), and neither a tab nor a newline in it is escaped — a tab
# shifts every later field, a newline splits the record into two lines. Nothing
# breaks today (`cut -f1` on the split remainder just yields a token matching no
# real window id, so it's silently ignored), but no consumer should assume `cwd`
# is opaque within the line. A companion file at the same path plus
# `.sock` holds the socket path alone — kept separate so `.windows` keeps its
# "empty means nothing was open at death" meaning, while the presence poll still
# has the path it needs to run the real (tmux-based) liveness check. It is
# refreshed PURELY event-driven — no background loop:
#   - OPEN  → sl_open/sl_resume snapshot (the window set just grew);
#   - CLOSE → a `window-unlinked` tmux hook (agentmux.conf) runs this script's
#             `snapshot` subcommand. The trick that makes closes catchable: we do
#             NOT try to identify the exited pane (pane-exit hooks fire with the
#             ACTIVE pane's context once the pane is gone — unreliable, and the
#             reason a naive close hook was avoided). We just re-query the WHOLE
#             live set, in which the closed window is already absent (verified: at
#             window-unlinked time list-windows excludes it). Every add and close
#             keeps the sidecar exact, with zero long-running processes.
# At read time: live → intersect real list-windows; dead + sidecar → intersect
# the sidecar (rows not in it were closed before death → omitted); dead + no
# sidecar (server predating this feature) → show all, the pre-sidecar behavior.

TAB=$(printf '\t')

_sl_state_dir() {
  printf '%s' "${AGENTMUX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agentmux}"
}
# The ledger's filename, carried as a variable so the presence-poll fast path can
# build the path from an already-resolved state dir without a second subshell (its
# whole budget is forks). This is the ONE encoding of the name — never restate it.
_SL_LEDGER_NAME=sessions.jsonl
_sl_ledger() { printf '%s/%s' "$(_sl_state_dir)" "$_SL_LEDGER_NAME"; }
# Confirmed-dead (socket,pid) memo — one "socket|pid" per line.
#
# Server death is MONOTONIC: a (socket,pid) that failed a liveness probe can never
# answer again, because the only way that pair returns is tmux reusing the pid on the
# same socket — and that path logs a fresh `open`, which drops the memo entry (see
# sl_open). Without this, every presence poll re-probed every dead server recorded for
# the cwd: warden polls `dropped --pending` per session-less tab, each _sl_server_live
# forks a tmux, and the dead-server count only ever grows between prunes.
# That is O(dead servers) forks per poll, forever, for an answer that cannot change.
_sl_dead_file() { printf '%s/dead' "$(_sl_state_dir)"; }

# Logging on unless explicitly disabled. Env override wins; else toml [log].sessions.
_sl_enabled() {
  case "${AGENTMUX_SESSION_LOG:-}" in
    0|false|no|off)  return 1 ;;
    1|true|yes|on)   return 0 ;;
  esac
  cfg="${AGENTMUX_CONFIG:-$HOME/.agentmux/amux.toml}"
  [ -f "$cfg" ] || return 0
  val=$(toml2json < "$cfg" 2>/dev/null | jq -r '.log.sessions // true' 2>/dev/null)
  [ "$val" != "false" ]
}

# Append one line, failing soft (never block a launch).
_sl_append() {
  dir=$(_sl_state_dir)
  mkdir -p "$dir" 2>/dev/null || return 0
  printf '%s\n' "$1" >> "$dir/sessions.jsonl" 2>/dev/null || true
}

# Emit tmux context for [target] as one TSV line. With no explicit target, fall
# back to $TMUX_PANE (the pane THIS process runs in). A context-less
# `display-message` resolves to the session's ACTIVE window, not our own — which
# misattributes the resume hint to whatever window you happen to be viewing.
#
# [socket] names the tmux -L socket to query explicitly. Callers invoked FROM
# INSIDE the tmux server (a hook's run-shell, or a process running in the pane
# itself — launch_agent.sh, fork_session.sh, the window-unlinked snapshot hook,
# the Claude Code adapter) inherit the correct $TMUX from that server and never
# need it: bare `tmux` already resolves to the (possibly per-project sharded)
# socket they're running under. A caller OUTSIDE the tmux server — bin/amux's
# own CLI process, which calls this before it attaches to the session it just
# created — has no such ambient $TMUX pointing at the right shard, so bare
# `tmux -t <target>` falls back to the literal tmux "default" socket and finds
# nothing there once sessions are sharded (the open event silently drops). Pass
# the resolved agent socket explicitly in that case; -L overrides any inherited
# $TMUX regardless (env -u TMUX is belt-and-suspenders, matching _amux_atmux).
_sl_ctx() {
  # SESSION_LOG_CTX overrides the tmux query for tests (mirrors the
  # SESSION_LOG_LIVE_* / SESSION_LOG_RESUME_MAP hooks), bypassing tmux entirely.
  if [ -n "${SESSION_LOG_CTX+x}" ]; then
    printf '%s\n' "$SESSION_LOG_CTX"
    return 0
  fi
  fmt="#{socket_path}${TAB}#{pid}${TAB}#{session_name}${TAB}#{window_id}${TAB}#{window_name}${TAB}#{pane_current_path}"
  _t="${1:-${TMUX_PANE:-}}"
  _sock="${2:-}"
  if [ -n "$_sock" ]; then
    if [ -n "$_t" ]; then
      env -u TMUX tmux -L "$_sock" display-message -p -t "$_t" "$fmt" 2>/dev/null
    else
      env -u TMUX tmux -L "$_sock" display-message -p "$fmt" 2>/dev/null
    fi
  elif [ -n "$_t" ]; then
    tmux display-message -p -t "$_t" "$fmt" 2>/dev/null
  else
    tmux display-message -p "$fmt" 2>/dev/null
  fi
}

sl_open() {  # <agent> [target] [socket]
  _sl_enabled || return 0
  _agent="$1"; _target="${2:-}"; _sock="${3:-}"
  IFS="$TAB" read -r _socket _pid _session _wid _wname _cwd <<EOF
$(_sl_ctx "$_target" "$_sock")
EOF
  # Require BOTH pid and window id: a display-message against a target that
  # doesn't resolve on the queried socket can still exit 0 with the server's
  # #{pid} populated (socket-level, not target-scoped) while the target-scoped
  # fields (window_id/cwd) come back empty — pid alone is not proof the target
  # actually resolved. Writing that row would corrupt the ledger with a
  # windowless "open" event. A real target always populates window_id too.
  [ -n "$_pid" ] && [ -n "$_wid" ] || return 0
  # Stamp the two facts the presence probe needs onto the WINDOW itself. They are
  # born and destroyed with the window, so they cannot outlive what they describe —
  # the lifetime rule the sidecar depends on. $_cwd is the LAUNCH dir, deliberately
  # not pane_current_path, which follows the user's cd and would drift off the tab.
  if [ -n "$_sock" ]; then
    env -u TMUX tmux -L "$_sock" set-option -w -t "$_wid" @amux_cwd   "$_cwd"   2>/dev/null || true
    env -u TMUX tmux -L "$_sock" set-option -w -t "$_wid" @amux_agent "$_agent" 2>/dev/null || true
  else
    tmux set-option -w -t "$_wid" @amux_cwd   "$_cwd"   2>/dev/null || true
    tmux set-option -w -t "$_wid" @amux_agent "$_agent" 2>/dev/null || true
  fi
  _line=$(jq -cn \
    --argjson ts "$(date +%s)" \
    --arg sp "$_socket" --argjson pid "$_pid" --arg s "$_session" \
    --arg wid "$_wid" --arg wn "$_wname" --arg cwd "$_cwd" --arg ag "$_agent" \
    '{ts:$ts,event:"open",socket_path:$sp,server_pid:$pid,session:$s,window_id:$wid,window_name:$wn,cwd:$cwd,agent:$ag}')
  _sl_append "$_line"
  # The window set just grew — record it in the live-set sidecar (closes are
  # caught by the window-unlinked hook, not here).
  _sl_snapshot "$_socket" "$_pid"
  # Launch is the natural trim point; sl_prune self-gates on the line cap, so
  # this is a cheap `wc -l` no-op until the ledger actually grows large.
  sl_prune
}

# Is the tmux server instance at <socket> still the one with <pid>?
# Querying tmux (not kill -0) defeats PID reuse after a reboot.
_SL_NL='
'
# Load the confirmed-dead memo ONCE per query into $_SL_DEAD (one fork), so the
# per-server check below is a pattern match rather than a tmux round-trip. Callers
# that sweep many servers (sl_dropped, sl_prune) must call this first; not calling it
# is safe — an unset $_SL_DEAD simply misses every time and probes as before.
_sl_load_dead() {
  _SL_DEAD_FILE=$(_sl_dead_file)
  _SL_DEAD="$_SL_NL$(cat "$_SL_DEAD_FILE" 2>/dev/null)$_SL_NL"
}

_sl_server_live() {  # <socket> <pid>
  if [ -n "${SESSION_LOG_LIVE_PIDS+x}" ]; then
    case " $SESSION_LOG_LIVE_PIDS " in *" $2 "*) return 0 ;; *) return 1 ;; esac
  fi
  # Memo hit → already proven dead, and death is monotonic (see _sl_dead_file). No fork.
  case "${_SL_DEAD:-}" in *"$_SL_NL$1|$2$_SL_NL"*) return 1 ;; esac
  got=$(tmux -S "$1" display-message -p '#{pid}' 2>/dev/null) || { _sl_mark_dead "$1" "$2"; return 1; }
  [ "$got" = "$2" ] || { _sl_mark_dead "$1" "$2"; return 1; }
}

# Record a confirmed death. Append-only and best-effort: losing a write costs one
# re-probe, never correctness. Skipped when the memo was never loaded (no file path
# resolved) or when the test hook is driving liveness.
_sl_mark_dead() {  # <socket> <pid>
  [ -n "${_SL_DEAD_FILE:-}" ] || return 0
  printf '%s|%s\n' "$1" "$2" >> "$_SL_DEAD_FILE" 2>/dev/null || true
}

# Window ids currently open on the live server at <socket>. Used to intersect a
# live server's ledger rows against reality (a window closed since its open was
# logged is gone from this list), replacing the unreliable close hook.
#
# EMPTY IS A REAL ANSWER, and tmux cannot give it: on the server whose LAST window
# just closed, `list-windows -a` exits 1 with "no current target" rather than
# printing nothing. Treating that as a failed query is what made a graceful
# teardown indistinguishable from a crash — the caller kept the previous
# (populated) sidecar, so sl_dropped re-offered the very tab you had just closed.
# Closing the last window is the ORDINARY way to finish with a project, so this
# fired constantly, not in some corner. Disambiguate on server liveness, which is
# the only thing that separates the two states (verified against a real server:
# windowless-but-alive answers `display-message -p '#{pid}'` with its pid and
# `list-sessions` with rc=0 + no output; a dead one fails both):
#   reachable + unqueryable → zero windows → succeed with an empty set;
#   unreachable             → a set we genuinely cannot observe → fail, and the
#                             caller keeps what it already recorded.
# That asymmetry is deliberate: a wrongly-empty sidecar silently destroys the
# crash-recovery data this whole feature exists for, so only POSITIVE evidence of
# a live windowless server may empty it.
_sl_live_windows() {  # <socket> [pid]
  if [ -n "${SESSION_LOG_LIVE_WINDOWS+x}" ]; then
    # Unquoted on purpose: emit one window id per line, mirroring tmux's output
    # (so tests exercise the real newline-separated shape).
    # shellcheck disable=SC2086
    printf '%s\n' $SESSION_LOG_LIVE_WINDOWS
    return 0
  fi
  # One call returns every fact the presence probe needs. Verified on tmux 3.7b:
  # #{@option} is supported in list-windows -F. Keep the `&& return 0` — an empty
  # result from a live windowless server is a REAL answer (see the comment above).
  tmux -S "$1" list-windows -a \
    -F "#{window_id}${TAB}#{@amux_cwd}${TAB}#{@amux_agent}${TAB}#{@amux_resumable}" 2>/dev/null && return 0
  # _sl_server_live (not a bare socket probe) so a pid that no longer matches —
  # a DIFFERENT server now owning this socket — reads as unreachable and leaves
  # our dead server's recorded set alone.
  _sl_server_live "$1" "$2"
}

# Path to a server's live-set sidecar, keyed by (socket, pid) — NOT pid alone.
# The ledger identifies a server by (socket_path, server_pid); the sidecar name
# must fold in the same socket or the two identities disagree: a same-boot pid
# reuse on a DIFFERENT socket (pid-counter wrap) would let a live server B
# (/s/b, pid 100) overwrite dead server A's (/s/a, pid 100) sidecar, and A's
# recovery rows would then intersect against B's window set and silently vanish —
# the exact loss this feature exists to prevent. Folding a cksum of the socket in
# (whitelist-safe: digits + '-' + digits) keeps them aligned, mirroring
# tmux-status.sh's pane_key.
_sl_sock_hash() { printf '%s' "$1" | cksum | cut -d' ' -f1; }  # <socket>
_sl_live_file() { printf '%s/live/%s-%s.windows' "$(_sl_state_dir)" "$(_sl_sock_hash "$1")" "$2"; }  # <socket> <pid>

# Drop a (socket,pid) from the confirmed-dead memo. The ONLY way a memoised pair can
# answer a liveness probe again is tmux reusing that pid on that socket — and such a
# server always records a snapshot (open, or the window-unlinked hook) before anything
# polls it, so clearing here is the complete invalidation. Costs a rewrite, but runs on
# session events only, never on the poll path.
_sl_clear_dead() {  # <socket> <pid>
  _df=$(_sl_dead_file); [ -s "$_df" ] || return 0
  grep -qxF "$1|$2" "$_df" 2>/dev/null || return 0
  _dt="$_df.$$.tmp"
  # `grep -v` EXITS 1 when it emits nothing — which is exactly the case that matters here
  # (removing the memo's only line). Gating the mv on its status would silently keep the
  # stale entry forever, so the write is unconditional. Safe: this file is a pure cache,
  # and the worst case of losing it is one re-probe.
  grep -vxF "$1|$2" "$_df" > "$_dt" 2>/dev/null
  mv "$_dt" "$_df" 2>/dev/null || rm -f "$_dt"
}

# Overwrite (socket,pid)'s sidecar with the server's current window set — the
# identity is always the PAIR, never pid alone (see _sl_live_file). Reuses
# _sl_live_windows so the SESSION_LOG_LIVE_WINDOWS test hook drives it too. The
# `.windows` write is atomic (temp + mv) so a reader never sees a half-written
# set; fails soft. An EMPTY set is written as such (see _sl_live_windows): that
# is the last-window close, and the resulting empty sidecar means "nothing was
# open at death" — the same state _sl_discard writes for a deliberate `amux
# --kill`.
#
# The `.sock` companion (the socket path alone, kept separate so `.windows`
# keeps its "empty means nothing was open at death" meaning while the presence
# poll still has the path it needs to run the real tmux-based liveness check)
# is written the SAME way — temp + mv — and only AFTER `.windows` has actually
# landed: writing it any earlier would let a snapshot whose liveness query
# fails (server genuinely gone, not merely windowless) leave a `.sock` with no
# `.windows` sibling on disk, and sl_prune only ever iterates live/*.windows —
# an orphan like that can never be swept and would survive forever. The guard
# is `-s` (non-empty), not `-f`: content is deterministic per filename (it's
# just $1), so a real write never needs repeating, but an `-f` guard would
# treat a 0-byte file (a writer killed mid-write — SIGKILL, power loss,
# ENOSPC) as already-done and leave the presence poll reading an empty socket
# path forever. `-s` self-heals that on the very next snapshot instead.
_sl_snapshot() {  # <socket> <pid>
  _sl_clear_dead "$1" "$2"
  _lf=$(_sl_live_file "$1" "$2"); _dir=${_lf%/*}
  mkdir -p "$_dir" 2>/dev/null || return 0
  _tmp="$_dir/.$2.$$.tmp"
  if _sl_live_windows "$1" "$2" > "$_tmp" 2>/dev/null; then
    mv "$_tmp" "$_lf" 2>/dev/null || rm -f "$_tmp"
    _sockf="$_dir/${_lf##*/}.sock"
    [ -s "$_sockf" ] || { printf '%s\n' "$1" > "$_sockf.$$.tmp" && mv "$_sockf.$$.tmp" "$_sockf"; } 2>/dev/null || true
  else
    rm -f "$_tmp"
  fi
}

# Mark a server's windows as DELIBERATELY closed by writing an EMPTY live-set
# sidecar. Used by `amux --kill`: killing a per-project shard's only session tears
# down the whole tmux server, so the window-unlinked snapshot hook never runs and
# the sidecar keeps its last (populated) set — a dead server + populated sidecar
# reads as a crash. An empty sidecar makes sl_dropped intersect every row against
# the empty set → nothing offered. This must WRITE an empty file, never delete it:
# an ABSENT sidecar means "dead server predating this feature → offer ALL windows",
# the opposite of what a deliberate kill wants.
_sl_discard() {  # <socket> <pid>
  _lf=$(_sl_live_file "$1" "$2"); _dir=${_lf%/*}
  mkdir -p "$_dir" 2>/dev/null || return 0
  : > "$_lf" 2>/dev/null || true
}

# Public snapshot subcommand: re-record a live server's window set. Invoked by the
# `window-unlinked` tmux hook on CLOSE (re-queries the whole set, so the closed
# window is naturally absent) — event-driven, no loop, no background process.
# sl_open/sl_resume call _sl_snapshot directly on OPEN.
sl_snapshot() {  # <socket> <pid>
  _sl_enabled || return 0
  _sl_snapshot "$1" "$2"
}

# Public discard subcommand: mark a server's windows as deliberately closed (empty
# live-set sidecar). Invoked by bin/amux right before it kills an agent session, so
# the torn-down shard isn't mistaken for a crash. See _sl_discard.
sl_discard() {  # <socket> <pid>
  _sl_enabled || return 0
  _sl_discard "$1" "$2"
}

# Epoch of the last boot, to tell a reboot from a same-boot kill (a server whose
# newest record predates boot is gone even if a new server reused its pid). Linux
# /proc/stat btime; macOS sysctl kern.boottime. Empty if unavailable → callers
# fall back to the pid check alone, which already covers same-boot kills.
_sl_boot_epoch() {
  [ -n "${SESSION_LOG_BOOT_EPOCH+x}" ] && { printf '%s' "$SESSION_LOG_BOOT_EPOCH"; return 0; }
  if [ -r /proc/stat ]; then
    awk '/^btime /{print $2; exit}' /proc/stat 2>/dev/null
  elif command -v sysctl >/dev/null 2>&1; then
    sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*{ sec = \([0-9]*\).*/\1/p'
  fi
}

# Mtime of <file> in epoch seconds; empty when it cannot be read. `stat` is not in
# POSIX and the two flavours spell this differently, so try GNU FIRST: BSD `stat -c`
# is a hard error (clean fallthrough), while GNU `stat -f` means --file-system and
# would SUCCEED with a mount point — a wrong answer, not a failure. Callers must
# treat empty as "cannot tell" and fall back to whatever they do without the fact.
# Deliberately NO SESSION_LOG_* override: the selftest drives it with a real
# `touch -t`, so the flavour detection above is itself under test.
_sl_mtime() {  # <file>
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# Fold ledger → TSV, one row per opened window (latest open + latest resume per
# (socket,pid,window_id) tuple). Columns: socket pid window_id session
# window_name cwd agent resume_cmd maxts fork_cmd. `maxts` (the newest event ts
# for the window) drives sl_dropped's recency work — which crash it recovers from
# and which duplicate row survives — while `window_id` orders what it emits.
# fork_cmd is
# APPENDED last on purpose: sl_dropped reads these columns positionally, so a
# new column may only go on the end. Whether a window is still open is decided
# at read time by sl_dropped (live server → intersect with reality), not here.
# Read line-by-line with `fromjson?` so a single torn/blank line (e.g. a
# kill-server mid-append) is skipped, not fatal — the whole point is surviving
# a crash, and a slurp (`-s`) aborts the entire roster on one bad line.
_sl_fold() {  # <ledger>
  [ -s "$1" ] || return 0
  jq -rRn '
    [ inputs | fromjson? | select(.event=="open" or .event=="resume") ]
    | group_by([.socket_path, .server_pid, .window_id])
    | map(
        ( map(select(.event=="open"))   | last ) as $o
        | select($o != null)
        | ( map(select(.event=="resume")) | last ) as $r
        | [ $o.socket_path, ($o.server_pid|tostring), $o.window_id, $o.session,
            $o.window_name, $o.cwd, $o.agent, ($r.resume_cmd // ""),
            (map(.ts) | max | tostring), ($r.fork_cmd // "") ] | @tsv )
    | .[]
  ' "$1"
}

# The ONE encoding of the agent→program swap: replace a command's leading token
# with the agent's `[[agents]] resume` program (claude --resume X → claude-work
# --resume X), leaving the rest — the adapter-owned syntax — untouched. An empty
# program means no override, so the command passes through.
#
# Carried as awk SOURCE rather than a shell function because both consumers apply
# it mid-awk-pipeline: sl_dropped (resume commands) and sl_forkcmd (fork commands)
# each interpolate this ahead of their own program. Do not re-encode it inline —
# two copies of one rule is exactly the drift this exists to prevent.
_SL_SWAP_FN='
function swap_prog(cmd, p,   sp) {
  if (p == "") return cmd
  sp = index(cmd," ")
  return (sp > 0) ? p substr(cmd, sp) : p
}'

# The ONE encoding of "is this sidecar line in the CURRENT (enriched) shape?" —
# window_id, cwd, agent, resumable. Two passes have to tell the shapes apart and
# they must never disagree: _sl_pending_fast (a non-current line's cwd is unknown,
# so it is resolved against the ledger instead of being read as a non-match) and
# sl_migrate (a non-current line is the one it backfills). They already drifted
# once — both encoded the test as a bare field count, and both therefore misread
# the SAME line — so the rule lives here, not at either call site.
#
# FIELD COUNT ALONE IS NOT THE TEST. `_sl_live_windows` formats every window with
# the full four-field -F string, so a window whose @amux_* options were never
# stamped still yields four fields, all but the id EMPTY (`@2<TAB><TAB><TAB>`).
# That is a legacy line wearing the current shape: counted as current, its empty
# cwd fails the `$2 == c` match and the query resolves to "definitely not this
# cwd" — a silent 1 where the ledger offers a restore. The stamps are best-effort
# (`set-option … 2>/dev/null || true`) and every window open before they shipped
# re-snapshots this way, so the shape is ordinary, not a corner. `$2` is the
# discriminator: `#{pane_current_path}` is never empty for a real window, so an
# empty cwd can only mean "unknown".
#
# Carried as awk SOURCE, like _SL_SWAP_FN above, because both consumers apply it
# mid-pass. Reads the current record (NF/$2), so it takes no arguments.
_SL_SHAPE_FN='
function sl_line_current() {
  return (NF >= 4 && $2 != "")
}'

# Map of agent name → resume program, from amux.toml's [[agents]] `resume` fields.
# Emits `agent<TAB>program` lines. The program replaces the leading token of a
# window's stored resume_cmd at display time (claude → claude-work), letting the
# log stay agent-agnostic (the adapter owns the `--resume <id>` syntax) while
# amux config overrides just the executable. SESSION_LOG_RESUME_MAP overrides for
# tests (mirrors the SESSION_LOG_LIVE_* hooks), bypassing toml2json.
_sl_resume_map() {
  if [ -n "${SESSION_LOG_RESUME_MAP+x}" ]; then
    printf '%s\n' "$SESSION_LOG_RESUME_MAP"
    return 0
  fi
  cfg="${AGENTMUX_CONFIG:-$HOME/.agentmux/amux.toml}"
  [ -f "$cfg" ] || return 0
  toml2json < "$cfg" 2>/dev/null \
    | jq -r '.agents[]? | select(.resume) | [.name, .resume] | @tsv' 2>/dev/null
}

# Answer "is there a restorable drop for <cwd>?" from the live-set sidecars alone.
#
# THE HOT PATH: warden polls `dropped --pending <cwd>` once per session-less tab per
# probe interval, across every tab its root scan discovers. The ledger path this
# replaces folds the whole ledger through jq and then spawns three processes per
# candidate server just to re-derive a sidecar path — spawns, not data, were its
# entire cost. Everything this question needs is already recorded at EVENT time in
# <state>/live/<sockethash>-<pid>.windows, so answering it is a directory scan.
#
# THE SPAWN BUDGET IS THE WHOLE POINT, AND IT IS PER-QUERY, NOT PER-SIDECAR. A
# state dir accumulates one sidecar per tmux server between prunes — hundreds on a
# dir that has not been pruned since the cap moved — so anything run once per FILE
# loses the race by itself: a
# per-file `awk` over 214 sidecars measured 1458ms against 34ms for one `awk` given
# all 214 as arguments, i.e. an order of magnitude WORSE than the ledger fold it
# was meant to replace. So the classify-every-sidecar pass is exactly one awk over
# the whole glob, and the per-server work that follows (reading the socket back,
# the liveness probe, the offer gate) runs only for the handful of sidecars that
# actually name this cwd — usually none. Keep it that way: a fork moved inside the
# scan is a silent 40x regression that no test asserts on.
#
# Exit 0 = yes, 1 = no, 2 = CANNOT ANSWER (fall through to the ledger path).
#
# 2 IS DELIBERATELY NOT 1. Missing sidecar dir, no sidecars at all, a legacy
# single-field sidecar, a .windows with no readable .sock companion, a server the
# LEDGER names for this cwd that has no sidecar at all — every one of those is
# absence of information, not evidence of no drop. Answering "no" on any of them
# would silently stop ghosting recoverable sessions, which is the exact data loss
# this subsystem exists to prevent, and it would do so invisibly: nothing is
# logged, nothing fails, the dot simply never lights. An EMPTY sidecar is the one
# shape that IS a real answer — it records "nothing was open when this server
# died" (a clean teardown), so it contributes no drop and never reads as 2.
#
# EVERY BAIL IS SCOPED TO THE QUERIED cwd, AND THAT SCOPING IS THE WHOLE VALUE.
# A state dir accumulates the residue of every project on the machine, so an
# unresolvable sidecar is not rare — it is guaranteed. Bailing on sight makes the
# fast path answer for NO cwd at all (measured: 11 legacy lines in 6 sidecars, all
# on long-dead servers belonging to other projects, deferred all 47 cwds), i.e. it
# costs the whole feature. So each of the three unresolvable shapes bails only
# when it could affect THIS cwd — and "could" is decided from information we
# actually hold, never from the assumption that absence means irrelevance:
#   - a LEGACY line hides its own cwd, so the sidecar cannot say whom it concerns.
#     Two independent tests can still retire it, and it only bails when BOTH fail.
#     PLACEMENT: the ledger records cwd per (socket_path, server_pid, window_id), so
#     a legacy window the ledger places in another cwd is irrelevant here (the ledger
#     path drops it on the same `cwd != scope` test, so ignoring it cannot disagree).
#     One the ledger places in THIS cwd stays unresolvable. INERTNESS: a sidecar line
#     only ever GATES a ledger row — it is the was-open-at-death set the fold
#     intersects with — and never contributes one, so a window the ledger holds NO
#     row for can be emitted by neither path and its cwd cannot change the answer,
#     placed or not. Only a window the ledger holds a row for while naming no cwd for
#     it (`resume` rows alone) is genuinely unknown, and that bails on a server whose
#     ledger rows DO mention this cwd. The `.sock` companion is what joins sidecar →
#     ledger socket path; without it the join degrades to the pid alone, which can
#     only rule the sidecar out (no ledger row for this cwd carries that pid, or none
#     names its windows at all), never in.
#   - a .sock-LESS sidecar blocks the liveness probe, so it bails only where the
#     probe would have run: a candidate row in this cwd (the per-candidate loop
#     below), or the sidecar of a ledger server named for this cwd (the END join).
#   - a SIDECAR-LESS ledger server is bailed on only for the cwds the ledger says
#     that server had — the ledger knows them exactly.
#
# THE SIDECAR-LESS SERVER IS THE CASE THAT MAKES THE LEDGER AN INPUT HERE. The
# ledger path treats a dead server with no sidecar as "every one of its windows was
# open at death" (sl_dropped's '*' branch) and offers them. Sidecars alone cannot
# see such a server at all, so scanning only live/ answers "no" on precisely the
# state recovery exists for: a crash at launch, where sl_open appends the ledger row
# and the follow-up _sl_snapshot's liveness query then fails because the server has
# already gone. So the ledger joins the same single awk pass — as a plain text scan,
# never a jq fold — purely to ask whether every server it names FOR THIS CWD has a
# sidecar. Any that doesn't makes the query unanswerable here.
_sl_pending_fast() {  # <cwd>
  _pf_cwd=$1
  _pf_boot=""; _pf_bootq=0   # boot epoch, resolved lazily and at most once per call
                             # (sh has no locals, and this function is called many
                             # times in one process by the selftest)
  # jq stores a control character in a cwd \u-escaped, and the ledger scan below
  # matches the ledger's RAW bytes — so for such a cwd the sidecar-less-server check
  # could not run soundly, and an unsound check here means a wrong 1. Defer instead.
  # (Mirrors sl_dropped's own screening of its raw-grep ledger fast path.)
  case "$_pf_cwd" in *[[:cntrl:]]*) return 2 ;; esac
  _pf_sd=$(_sl_state_dir)
  [ -d "$_pf_sd/live" ] || return 2
  # Hand the whole glob to awk as-is. Do NOT pre-filter it in the shell: a loop that
  # rebuilds the positional list per file (`set -- "$@" "$f"`) is quadratic, and at
  # 214 sidecars it measured 373ms — ten times the scan it was guarding. There is
  # nothing to gain either, because awk already yields no records for an empty file,
  # which is exactly the answer an empty sidecar should contribute: that server was
  # torn down cleanly, so it offers no drop (and if every sidecar is empty, awk finds
  # no candidate and the whole query is a plain "no", never a 2).
  #
  # TWO input groups, ONE awk (the fork budget is the whole point): every .windows
  # sidecar, then the ledger LAST. The .sock companions are deliberately NOT globbed
  # in even though the ledger join needs them — that doubles the files awk reads
  # (measured +4.6ms per query at 216 sidecars, against +1.6ms for the whole ledger)
  # and all but a handful of those reads are wasted, so awk opens by name the few it
  # actually needs (see the END block).
  set -- "$_pf_sd"/live/*.windows
  [ -e "$1" ] || return 2                  # unmatched glob: no sidecars = no information
  # Built from the already-resolved state dir: `$(_sl_ledger)` would be two more
  # forks (it resolves the dir again in its own subshell) on the one path whose
  # entire cost is forks.
  _pf_ledger="$_pf_sd/$_SL_LEDGER_NAME"
  [ -s "$_pf_ledger" ] && set -- "$@" "$_pf_ledger"
  # ONE pass over every input. Emits the files holding a candidate row — an agent
  # window (never `shell`) in this cwd that recorded a resume hint, the same three
  # conditions the ledger path applies to its own rows. A line the shared
  # classifier (_SL_SHAPE_FN) does not call current has an unknown cwd — a bare
  # legacy id, or a 4-field line from an unstamped window whose cwd is empty —
  # so it is REMEMBERED, not bailed on, and resolved against the ledger in
  # the END block, which bails with a distinctive status (3) only if the window
  # could belong to this cwd. A ledger server with no sidecar bails the same way
  # (4). Any other non-zero (a genuine awk failure) lands in the same place, which
  # is the safe direction — 2 defers to the ledger, it never invents an answer.
  #
  # The cwd arrives through ENVIRON, NOT `-v`: `-v` runs its value through escape
  # processing, so a cwd containing a backslash would be compared mangled and the
  # query would false-negative. ENVIRON is the byte-exact channel.
  _pf_cands=$(SL_PF_CWD="$_pf_cwd" awk -F"$TAB" "$_SL_SHAPE_FN"'
      BEGIN {
        c = ENVIRON["SL_PF_CWD"]
        # The ledger stores cwd JSON-encoded, so match on the ENCODED needle. Built
        # by a character loop rather than gsub(): backslash handling in a gsub()
        # replacement string is implementation-specific, and the one character that
        # must survive intact here is the backslash.
        j = ""
        for (i = 1; i <= length(c); i++) {
          ch = substr(c, i, 1)
          if (ch == "\\" || ch == "\"") j = j "\\" ch; else j = j ch
        }
        need = "\"cwd\":\"" j "\""
        # Index the sidecar FILENAMES by pid, straight off ARGV — no file is read to
        # build this, and unlike a FILENAME-driven index it still sees the EMPTY
        # sidecars (awk yields no records for those, but an empty sidecar is a real
        # answer, so a ledger server holding one must not read as missing).
        for (i = 1; i < ARGC; i++) {
          f = ARGV[i]
          if (f !~ /\.windows$/) continue
          p = f; sub(/\.windows$/, "", p); sub(/.*-/, "", p)
          fpid[f] = p
          byp[p] = byp[p] "\n" f
        }
      }
      FNR == 1 { mode = (FILENAME ~ /\.windows$/) ? 1 : 3 }
      mode == 1 {
        if (!sl_line_current()) {
          # Legacy shape: cwd unknown — a bare window id, or an UNSTAMPED window,
          # whose four fields are all empty but the id (see _SL_SHAPE_FN: the field
          # count alone cannot tell them apart, and reading the latter as current
          # resolves it to a false non-match). Remember it (per sidecar,
          # and its pid, which is all the ledger scan below needs to know whether to
          # index a row) and let END decide whether it can concern this cwd. A BLANK
          # line names no window at all, so it hides nothing and is simply skipped —
          # treating it as legacy would be an unresolvable bail with no window id to
          # resolve, i.e. the global bail this scoping exists to remove.
          if ($1 == "") next
          if (!(FILENAME in legw)) legf[++nlegf] = FILENAME
          legw[FILENAME] = legw[FILENAME] "\n" $1
          legpid[fpid[FILENAME]] = 1
          next
        }
        if ($2 == c && $3 != "shell" && $4 != "") { if (!(seen[FILENAME]++)) print FILENAME }
        next
      }
      {
        # Ledger rows are indexed for three questions: which servers this cwd was open
        # on (`wsock`, for the sidecar-less-server check), and — only when a legacy
        # sidecar exists to resolve — whether the ledger holds ANY row for a given
        # window of that server pid (`lany`, the inertness test the END block leans on)
        # and which cwd it was opened in (`lrel`/`lknown`). A fully-enriched state dir,
        # where `nlegf` is 0, still pays only the one `index` test per row: everything
        # below the first screen is legacy-resolution work.
        #
        # `resume` rows (683 of 1629 on a real ledger) carry no cwd, so they answer
        # neither cwd question — but they ARE ledger rows, so they must reach `lany`.
        # Screening them out on `"cwd":"` (which this pass used to do) would report a
        # window with only `resume` rows as having no ledger row at all, i.e. as inert
        # when it is not. The cheap screen is therefore `nlegf`, not the cwd key.
        hit = index($0, need)
        if (!hit && nlegf == 0) next
        if (!match($0, /"server_pid":[0-9]+/)) next
        pid = substr($0, RSTART + 13, RLENGTH - 13)
        if (!hit && !(pid in legpid)) next
        # Keyed on (server_pid, window_id), NOT on the socket path, and recorded
        # BEFORE the socket_path match can `next` out: `lany` is the evidence a bail
        # is dropped on, so anything that makes it INCOMPLETE turns a live window into
        # a false "inert" — a wrong 1. Pid+window_id is the coarser key (two servers
        # sharing a pid and a window id collide), and coarser is the safe direction
        # here: it can only ever preserve a bail, never invent an answer.
        wid = ""
        if ((pid in legpid) && match($0, /"window_id":"[^"]*"/)) {
          wid = substr($0, RSTART + 13, RLENGTH - 14)
          lany[pid SUBSEP wid] = 1
        }
        if (!match($0, /"socket_path":"[^"]*"/)) next
        sp = substr($0, RSTART + 15, RLENGTH - 16)
        if (hit) { k = sp SUBSEP pid; wsock[k] = sp; wpid[k] = pid }
        # Only an `open` row carries a cwd, and it is the row the ledger fold keys a
        # window on — so a window with a cwd-bearing row has a KNOWN cwd, and one
        # whose every row lacks it (a bare `resume`) stays unknown. `lrel` wins over
        # `lknown` on purpose: a window id reopened in a second cwd is ambiguous, and
        # the safe reading of ambiguity is "could be this cwd".
        if (wid != "" && index($0, "\"cwd\":\"")) {
          w = sp SUBSEP pid SUBSEP wid
          if (hit) lrel[w] = 1; else lknown[w] = 1
        }
      }
      END {
        # 1. Does every server the ledger names FOR THIS CWD actually HAVE a sidecar?
        # The filename only hashes the socket, so the .sock companion is the only join
        # back to the ledger socket_path — read it here, for the pid-matching sidecars
        # alone. A sidecar with no readable companion cannot be matched, so a server
        # whose only candidate sidecar lacks one reads as sidecar-less: 4, correctly,
        # because we cannot tell that it is not.
        for (k in wsock) {
          ok = 0
          n = split(byp[wpid[k]], ff, "\n")
          for (i = 1; i <= n; i++) {
            if (ff[i] == "") continue
            s = ""
            if ((getline s < (ff[i] ".sock")) > 0 && s == wsock[k]) ok = 1
            close(ff[i] ".sock")
            if (ok) break
          }
          if (!ok) exit 4
          cwdsock[k] = 1          # (socket,pid) the ledger places in this cwd
          cwdpid[wpid[k]] = 1     # ...and the pid alone, for the socket-less join
        }
        # 2. Legacy lines, resolved against that index. Reached only for sidecars that
        # actually hold one, so a migrated state dir does no work here at all.
        for (i = 1; i <= nlegf; i++) {
          f = legf[i]; p = fpid[f]
          s = ""
          if ((getline s < (f ".sock")) <= 0) s = ""
          close(f ".sock")
          if (s == "") {
            # No socket path: the ledger join degrades to the pid, which can only rule
            # the sidecar OUT. No ledger row for this cwd carries this pid → no window
            # of this server is in this cwd, so its unreadable lines hide nothing.
            # Otherwise it might BE that server — and then each unreadable LINE is
            # checked for inertness in its own right (see the END-of-loop note below):
            # a window the ledger holds no row for cannot be emitted by the ledger path
            # whichever server this sidecar turns out to be, so it hides nothing either.
            if (p in cwdpid) {
              n = split(legw[f], ww, "\n")
              for (m = 1; m <= n; m++) {
                if (ww[m] == "") continue
                if ((p SUBSEP ww[m]) in lany) exit 3
              }
            }
            continue
          }
          n = split(legw[f], ww, "\n")
          for (m = 1; m <= n; m++) {
            if (ww[m] == "") continue
            w = s SUBSEP p SUBSEP ww[m]
            if (w in lrel) exit 3          # ledger puts this window in THIS cwd
            if (w in lknown) continue      # ...in another one: irrelevant here
            # The ledger names no cwd for this window, so the join cannot place it.
            # INERTNESS is the second question, and it is the one that resolves this:
            # a sidecar line can only ever GATE a ledger row (it is the was-open-at-death
            # set the fold intersects with), never contribute one — so a window the
            # ledger holds NO row for is a set member nothing can be emitted for, and
            # whether it is in this cwd cannot change the answer. It is dropped, not
            # bailed on. A window the ledger DOES hold a row for while naming no cwd
            # (only `resume` rows survived pruning) stays unknown, and bails as before
            # if its server is one the ledger ties to this cwd. This is the condition
            # that used to defer half the cwds on a real state dir: the residual legacy
            # lines are hand-created windows amux never logged at all.
            if (((s SUBSEP p) in cwdsock) && ((p SUBSEP ww[m]) in lany)) exit 3
          }
        }
      }
    ' "$@") || return 2
  [ -n "$_pf_cands" ] || return 1
  # From here on the work is per-CANDIDATE, and candidates are rare — this is the
  # branch a tab with a real crashed session takes, not the polling steady state.
  _sl_load_dead   # one read; every repeat probe of a known-dead server is then fork-free
  _pf_hit=1
  _pf_ifs=$IFS; IFS=$_SL_NL
  # shellcheck disable=SC2086  # deliberate: split the candidate list on newlines only
  set -- $_pf_cands
  IFS=$_pf_ifs
  for _pf_f in "$@"; do
    # A candidate only counts if its server is DEAD. The filename only HASHES the
    # socket, so read the path back from the companion file and run the real
    # (tmux-based) liveness test — never kill -0, which cannot tell a reused pid
    # from the original server after a reboot. `read` is a builtin, so this costs
    # no fork; a missing or empty companion (what _sl_discard leaves behind) means
    # the liveness test cannot run at all, which is 2, not an error and not a "no".
    _pf_sock=""
    [ -f "$_pf_f.sock" ] && IFS= read -r _pf_sock < "$_pf_f.sock" 2>/dev/null
    [ -n "$_pf_sock" ] || return 2
    _pf_base=${_pf_f##*/}; _pf_base=${_pf_base%.windows}
    _pf_pid=${_pf_base##*-}
    if _sl_server_live "$_pf_sock" "$_pf_pid"; then
      # LIVENESS IS NOT THE WHOLE DEADNESS TEST — the ledger path pairs it with the
      # boot epoch (`_sl_server_live … && { -z "$_boot" || smax >= _boot; }`), and the
      # fast path must too. A reboot can hand a NEW tmux server the same pid on the
      # same socket path; it then answers our probe as if it were the dead one, and
      # `continue` here would silently drop a real drop — a collapse to 1 in the
      # unsafe direction, which is the one thing this exit code exists to prevent.
      # The two paths hold the same evidence in different form: the ledger's `smax`
      # is that server's newest recorded event, and the sidecar's MTIME is the same
      # fact (it is rewritten on every open and every window-unlinked close). Older
      # than boot → the recorded set belongs to a pre-reboot server → the ledger's
      # business, so defer (2) rather than answer. Deferring, not offering, because
      # the fast path has no way to check that server's OTHER windows.
      #
      # Costs a fork only HERE — a live server holding an agent window with a resume
      # hint in the very cwd being polled, which is not the polling steady state
      # (warden probes session-LESS tabs). The dead-candidate branch below, and every
      # poll answered before the loop, are untouched. Unknown boot epoch or unreadable
      # mtime → treat as live, exactly the fallback the ledger path takes when
      # `_sl_boot_epoch` comes back empty.
      if [ "$_pf_bootq" = 0 ]; then _pf_boot=$(_sl_boot_epoch); _pf_bootq=1; fi
      if [ -n "$_pf_boot" ]; then
        _pf_mt=$(_sl_mtime "$_pf_f")
        [ -n "$_pf_mt" ] && [ "$_pf_mt" -lt "$_pf_boot" ] 2>/dev/null && return 2
      fi
      continue
    fi
    # The once-per-(server,cwd) offer gate, applied READ-ONLY (no marking) on the
    # same key the ledger path builds. Skipping it here would re-light a ghost amux
    # has already offered and cleared.
    if [ -f "$_pf_sd/notified" ] &&
       grep -qxF "$_pf_sock|$_pf_pid|$_pf_cwd" "$_pf_sd/notified" 2>/dev/null; then
      continue
    fi
    _pf_hit=0
  done
  return "$_pf_hit"
}

# sl_dropped <cwd> | --global | --new <cwd>
# Emit restorable DROPPED tabs from the SINGLE most recent crash — an agent tab
# (agent != shell, resume_cmd non-empty) on a DEAD server (pid no longer answers on its
# socket, or its records predate boot), that was OPEN AT DEATH (in the live-set sidecar;
# a dead server with no sidecar counts all its windows). One TSV row per tab:
# agent<TAB>cwd<TAB>resume_cmd<TAB>maxts, in the ORIGINAL TAB ORDER (window-id
# ascending) — the consumer creates one window per row in order, so this order IS the
# restored tab order; see the ordering comment on the final stage. The resume program is swapped in
# from [[agents]] `resume` (work→claude-work) so the command targets the right profile.
# LAST-CRASH SCOPING: the ledger accumulates every dead server between prunes; a
# reboot-heavy machine would otherwise dump a whole backlog at once. So we keep only the
# rows of the most-recently-active dead server (the crash you're recovering from) — the
# reachability sl_prune's keep set is built from — and DEDUP by
# resume session id (the same session resumed across several server lifetimes, or in two
# windows of one server, surfaces once). `<cwd>` filters to that dir; `--global` = no
# filter; `--new <cwd>` additionally emits ONLY servers not yet offered for that cwd and
# marks them offered (the once-per-server-per-project launch gate); `--pending <cwd>` applies
# that same gate READ-ONLY (no marking) — warden's presence probe polls it to decide whether a
# plain `amux` launch here would offer a restore, and a marking read would burn the gate.
sl_dropped() {
  _sl_enabled || return 0
  # PRESENCE-POLL FAST PATH. --pending's only consumer (bin/amux's _amux_probe) tests
  # its output for EMPTINESS, never reads the rows, so a single synthetic line answers
  # it — that narrowing is what lets the sidecars replace the ledger fold here. Exit 2
  # means the sidecars cannot answer, so the ledger path below runs unchanged.
  # AMUX_PENDING_NO_FAST forces that fallback: it is the seam the selftest uses to
  # observe both paths against one fixture and prove they agree.
  if [ "${1:-}" = "--pending" ] && [ -n "${2:-}" ] && [ -z "${AMUX_PENDING_NO_FAST:-}" ]; then
    _sl_pending_fast "$2"
    case $? in
      0) printf 'pending\n'; return 0 ;;
      1) return 0 ;;
      *) ;;                      # 2 = cannot answer; fall through to the ledger path
    esac
  fi
  # One read; turns the per-server liveness sweep below fork-free for known-dead
  # servers. Deliberately BELOW the fast-path block: nothing between here and the top
  # of the function reads $_SL_DEAD (_sl_pending_fast loads its own, only once it has
  # candidates), so hoisting it would spend 2 forks on every poll that the sidecars
  # answer outright — the common case, and the case this whole path exists for.
  _sl_load_dead
  # _gate_new: apply the once-per-(server,cwd) offer filter. _mark_new: also record the
  # offer. --new does both (the launch picker consumes it once). --pending gates WITHOUT
  # marking: warden's presence probe polls this every few seconds, so a marking read would
  # burn the gate on the first pass and the ghost would render once and never again.
  _mark_new=0; _gate_new=0; _scope=""
  case "$1" in
    --new)     _mark_new=1; _gate_new=1; _scope="${2:-}" ;;
    --pending) _gate_new=1; _scope="${2:-}" ;;
    --global)  _scope="--global" ;;
    *)         _scope="${1:-}" ;;
  esac
  _ledger=$(_sl_ledger); [ -s "$_ledger" ] || return 0
  # Fast path: a scoped query for a cwd that never appears in the ledger has nothing to emit,
  # so skip the (expensive) fold + per-server liveness checks. grep -qF searches the raw,
  # JSON-ENCODED ledger, so it is only a sound necessary condition when $_scope needs no JSON
  # escaping — a cwd containing " , \ , or a control char is stored escaped in the ledger, and
  # grepping the bare form would false-miss a real session. So those fall through to the correct
  # (decoded) slow path; every ordinary path (spaces and UTF-8 included) takes the fast path.
  # --global (no cwd) and the empty scope skip the gate entirely.
  case "$_scope" in
    --global|"") ;;
    *[\"\\]* | *[[:cntrl:]]*) ;;
    *) grep -qF "$_scope" "$_ledger" || return 0 ;;
  esac
  _boot=$(_sl_boot_epoch)
  _notmark="$(_sl_state_dir)/notified"
  rows=$(mktemp) || return 1
  _sl_fold "$_ledger" > "$rows"
  if [ ! -s "$rows" ]; then rm -f "$rows"; return 0; fi

  # Per (socket,pid): decide dead vs live, and capture the recorded live-set (or '*'
  # for a dead server with no sidecar → all windows count). Live servers emit nothing.
  #
  # SCOPE THE LIVENESS SWEEP TO THE QUERIED cwd. A scoped query (--pending/--new/bare
  # cwd) can only ever emit rows for servers that opened a window in that cwd — the awk
  # below drops every other-cwd row (cwd!=scope). So only those servers' liveness needs
  # checking, and _sl_server_live spawns a tmux per server: a ledger holding N dead
  # servers across many projects otherwise pays O(N) tmux probes on EVERY per-dir
  # presence poll — the slow path warden hits every few seconds for each session-less
  # tab with prior history (one project's --pending was ~5s at ~90 stale servers). Filter
  # on the DECODED cwd (fold col 6), so it stays correct for cwds the grep fast-path above
  # can't screen (quotes / control chars). --global and the empty scope keep the full set.
  state=$(mktemp) || { rm -f "$rows"; return 1; }
  # Emit the server set WITH each server's max ts, in ONE pass. The max ts used to be
  # re-derived by a fresh awk per server inside the loop below — and a process spawn is the
  # whole cost of this query, not the data: at 13 servers for one cwd that was 13 spawns of
  # ~30ms against a ledger that parses in 36ms total. It is also self-amplifying, since the
  # spawns load the machine that makes every later spawn slower. Max ts is computed over ALL
  # of a server's rows (m[]) while the scoped set is chosen by cwd (s[]), which is exactly
  # what the per-server awk did — scoping must not truncate a server's history.
  case "$_scope" in
    --global | "")
      _servers=$(awk -F"$TAB" -v OFS="$TAB" '
        {k=$1 OFS $2; if($9+0>m[k]) m[k]=$9+0}
        END{for(k in m) print k, m[k]}' "$rows" | sort -u) ;;
    *)
      _servers=$(awk -F"$TAB" -v OFS="$TAB" -v c="$_scope" '
        {k=$1 OFS $2; if($9+0>m[k]) m[k]=$9+0; if($6==c) s[k]=1}
        END{for(k in s) print k, m[k]}' "$rows" | sort -u) ;;
  esac
  printf '%s\n' "$_servers" | while IFS="$TAB" read -r socket pid smax; do
    [ -n "$pid" ] || continue
    if _sl_server_live "$socket" "$pid" && { [ -z "$_boot" ] || [ "$smax" -ge "$_boot" ] 2>/dev/null; }; then
      continue
    fi
    if [ "$_gate_new" = 1 ]; then
      _gk="$socket|$pid|$_scope"
      if [ -f "$_notmark" ] && grep -qxF "$_gk" "$_notmark" 2>/dev/null; then
        continue                                   # already offered for this cwd
      fi
      if [ "$_mark_new" = 1 ]; then
        mkdir -p "$(_sl_state_dir)" 2>/dev/null && printf '%s\n' "$_gk" >> "$_notmark" 2>/dev/null || true
      fi
    fi
    # Resolve the sidecar path ONCE. _sl_live_file hashes the socket via `cksum | cut`
    # (two spawns), and spawns are the entire cost of this query, so a second call to
    # re-derive the same path per server would be pure waste.
    _lf=$(_sl_live_file "$socket" "$pid")
    if [ -f "$_lf" ]; then
      # Each line may carry 4 tab-separated fields (window_id, cwd, agent,
      # resumable); keep only the window_id column before flattening to
      # space-separated, or the remaining fields spill into $5, $6, … below
      # and every window past the first silently drops out of lw[]. `cut -f1`
      # on a legacy bare-id line (no tabs) returns the line unchanged, so both
      # shapes are handled by the one pipeline.
      _sw=$(cut -f1 < "$_lf" | tr '\n' ' ')
      printf 'S\t%s\t%s\t%s\n' "$socket" "$pid" "$_sw"
    else
      printf 'S\t%s\t%s\t*\n' "$socket" "$pid"
    fi
  done > "$state"

  {
    cat "$state"
    _sl_resume_map | while IFS="$TAB" read -r _ag _prog; do
      [ -n "$_ag" ] || continue
      printf 'P\t%s\t%s\n' "$_ag" "$_prog"
    done
    awk '{print "R\t" $0}' "$rows"
  } | awk -F"$TAB" -v OFS="$TAB" -v scope="$_scope" "$_SL_SWAP_FN"'
      $1=="S" { dead[$2 SUBSEP $3]=1; lw[$2 SUBSEP $3]=$4; next }
      $1=="P" { prog[$2]=$3; next }
      $1=="R" {
        socket=$2; pid=$3; wid=$4; cwd=$7; agent=$8; rcmd=$9; ts=$10
        key=socket SUBSEP pid
        if (!(key in dead)) next
        set=lw[key]
        if (set != "*") {
          inset=0; n=split(set,a," ")
          for (i=1;i<=n;i++) if (a[i]==wid) { inset=1; break }
          if (!inset) next
        }
        if (agent=="shell" || rcmd=="") next
        if (scope!="--global" && cwd!=scope) next
        rcmd=swap_prog(rcmd, prog[agent])
        # Carry the server key + ts so the next stage can isolate ONE crash, and the
        # window id so the LAST stage can restore the original tab order. The id goes
        # on the END: `sort -k2,2nr` below breaks a ts tie on its whole-line
        # comparison, so appending leaves every pre-existing tie unchanged (it can
        # only decide between two rows identical in server, ts, agent, cwd AND resume
        # command — the same-session-in-two-windows case, whose emitted row is the
        # same either way).
        print socket "|" pid, ts, agent, cwd, rcmd, wid
      }
    ' \
  | sort -t"$TAB" -k2,2nr \
  | awk -F"$TAB" -v OFS="$TAB" '
      # LAST CRASH ONLY: rows are ts-desc, so the first row names the single
      # most-recently-active dead server (the crash we recover from); every other
      # dead server in the ledger is history, not a recovery target. Then DEDUP by
      # the resume session id (last token of the resume command) so a session that
      # lived in >1 window of that server surfaces once. First-seen wins = newest
      # (input already ts-desc).
      #
      # Then RE-ORDER to the original tab order, window-id ascending: the emitted
      # rows ARE the restored tab order (_amux_restore_into makes one window per
      # line, in order), so leaving them ts-desc restored a crashed session with
      # its tabs reversed. Both orderings are needed and they are not the same
      # ordering — recency selects WHICH rows survive, window id decides where each
      # surviving tab lands. Emit the sort key as a leading numeric column (`@`
      # stripped, so @10 sorts after @2 rather than between @1 and @2) and cut it
      # off after. Every surviving row is from ONE server (best, above), so the ids
      # are mutually comparable; a legacy row with no window id sorts to the front.
      NR==1 { best=$1 }
      $1 != best { next }
      { m=split($5, g, " "); uuid=g[m]
        if (uuid in seen) next
        seen[uuid]=1
        wn=$6; sub(/^@/, "", wn)
        print wn+0, $3, $4, $5, $2 }
    ' \
  | sort -t"$TAB" -k1,1n \
  | cut -f2-

  rm -f "$rows" "$state"
}

# sl_forkcmd [target]
# Emit the fork command for ONE LIVE window as `agent<TAB>fork_cmd`, or nothing
# when the window has no forkable session (no resume record yet, the `shell`
# agent, or an agent whose adapter records no fork_cmd — i.e. one that cannot
# fork). Target defaults to $TMUX_PANE via _sl_ctx.
#
# Distinct from sl_dropped, which by design only reports windows on DEAD servers.
# The (socket,pid,window_id) triple is the key: window ids are unique per tmux
# SERVER only, so two servers collide — guaranteed under `amux --frame`, where
# the agent runs a second tmux deep.
#
# The `[[agents]] resume` program is swapped into the leading token exactly as
# sl_dropped does it (claude → claude-work), so the fork targets the right profile.
sl_forkcmd() {  # [target]
  _sl_enabled || return 0
  IFS="$TAB" read -r _socket _pid _ _wid _ _ <<EOF
$(_sl_ctx "${1:-}")
EOF
  [ -n "$_pid" ] || return 0
  _ledger=$(_sl_ledger); [ -s "$_ledger" ] || return 0
  {
    _sl_resume_map | while IFS="$TAB" read -r _ag _prog; do
      [ -n "$_ag" ] || continue
      printf 'P\t%s\t%s\n' "$_ag" "$_prog"
    done
    _sl_fold "$_ledger" | awk '{print "R\t" $0}'
  } | awk -F"$TAB" -v OFS="$TAB" -v s="$_socket" -v p="$_pid" -v w="$_wid" "$_SL_SWAP_FN"'
      $1=="P" { prog[$2]=$3; next }
      $1=="R" {
        if ($2!=s || $3!=p || $4!=w) next
        agent=$8; fcmd=$11
        if (agent=="shell" || fcmd=="") next
        print agent, swap_prog(fcmd, prog[agent])
        exit
      }
    '
}

# Generic resume-hint enrichment. Runs inside the agent's own pane, on EVERY
# working hook — synchronously, ahead of the detached summariser — so the
# steady-state (already-logged) path must NOT fork. It derives the dedup marker
# key from tmux's exported env ($TMUX = "socket,serverpid,sessionid"; $TMUX_PANE =
# "%N"), which costs ZERO subprocesses: a repeat label short-circuits without the
# `tmux display-message` that _sl_ctx spawns. tmux exports both to every pane
# process (the summariser already relies on this), so they're present in the hook
# env. A pane is stable per agent and 1:1 with its window, so it dedups as well as
# window_id; the "p" prefix keeps its key namespace disjoint from the window_id
# fallback (a pane "%3" and a window "@3" must not collide). _sl_ctx (the tmux
# call) is DEFERRED to a miss, where the authoritative socket/window_id are needed
# for the ledger line + sidecar. No usable $TMUX (manual/selftest) → fall back to
# deriving the key from _sl_ctx too.
# Mark/unmark a window as having a resume command. Its own function (not inlined into
# sl_resume) because the sidecar read path in Task 3 is specified against this exact
# option, and the selftest drives it directly without a full sl_resume record.
_sl_mark_resumable() {  # <socket_path> <window_id> <resume_cmd>
  [ -n "$2" ] || return 0
  if [ -n "$3" ]; then
    env -u TMUX tmux -S "$1" set-option -w -t "$2" @amux_resumable 1 2>/dev/null || true
  else
    env -u TMUX tmux -S "$1" set-option -uw -t "$2" @amux_resumable 2>/dev/null || true
  fi
}

sl_resume() {  # <label> <resume_cmd> [fork_cmd] [target] [socket]
  _label="$1"; _rcmd="$2"; _fcmd="${3:-}"; _rtarget="${4:-}"; _rsock="${5:-}"
  [ -n "$_label" ] || return 0
  _dir=$(_sl_state_dir)
  # The marker stores the FULL record signature, not just the label: its job is
  # "have we already recorded THIS record for this pane". Keying on the label
  # alone meant a live pane whose marker already matched could never write an
  # enriched record — so an added field (e.g. fork_cmd, on upgrade) would never
  # reach a running tab. Signature-keying self-heals on the next prompt, and
  # costs nothing extra: it is a string compare either way.
  _sig="$_label|$_rcmd|$_fcmd"

  # Fast path: env-derived key, no subprocess. Trust $TMUX only if well-formed.
  # SKIPPED ENTIRELY on the explicit-target path (a CLI caller such as bin/amux's
  # restore, which names the window and shard it just created): $TMUX/$TMUX_PANE
  # there describe whatever server the USER happens to be sitting in — commonly a
  # different one — so the env key would namespace the marker under a foreign pane.
  # Same CLI-vs-hook split _sl_ctx documents; the fallback (pid + window id) is
  # derived from the resolved target below and is correct for both.
  _epid=""
  if [ -z "$_rtarget" ] && [ -z "$_rsock" ]; then
    case "$TMUX" in *,*,*) _epid=${TMUX#*,}; _epid=${_epid%%,*} ;; esac
  fi
  _emark=""
  if [ -n "$_epid" ] && [ -n "${TMUX_PANE:-}" ]; then
    _emark="$_dir/seen/${_epid}-p$(printf '%s' "$TMUX_PANE" | tr -d '%')"
    [ -f "$_emark" ] && [ "$(cat "$_emark" 2>/dev/null)" = "$_sig" ] && return 0
  fi

  _sl_enabled || return 0

  # Miss (new label) or no usable env: fetch full context once for the record.
  IFS="$TAB" read -r _socket _pid _ _wid _ _ <<EOF
$(_sl_ctx "$_rtarget" "$_rsock")
EOF
  # Require the window id too, not just the pid: a display-message against a
  # target that doesn't resolve on the queried socket still reports the server's
  # socket-level #{pid} while the target-scoped fields come back empty (the same
  # trap sl_open guards). A windowless resume row belongs to no window, so the
  # fold can never attach it to one — it would only ever be dead weight.
  [ -n "$_pid" ] && [ -n "$_wid" ] || return 0
  _marker="${_emark:-$_dir/seen/${_pid}-$(printf '%s' "$_wid" | tr -d '@')}"
  # Fallback-path dedup: when no env key short-circuited above, re-check here.
  [ -z "$_emark" ] && [ -f "$_marker" ] && [ "$(cat "$_marker" 2>/dev/null)" = "$_sig" ] && return 0

  mkdir -p "$_dir/seen" 2>/dev/null || return 0
  printf '%s' "$_sig" > "$_marker" 2>/dev/null || true
  # Stamp the resumable fact onto the window itself, same lifetime rule as
  # sl_open's @amux_cwd/@amux_agent: born and destroyed with the window.
  _sl_mark_resumable "$_socket" "$_wid" "$_rcmd"
  _line=$(jq -cn \
    --argjson ts "$(date +%s)" --arg sp "$_socket" --argjson pid "$_pid" \
    --arg wid "$_wid" --arg label "$_label" --arg rc "$_rcmd" --arg fc "$_fcmd" \
    '{ts:$ts,event:"resume",socket_path:$sp,server_pid:$pid,window_id:$wid,label:$label,resume_cmd:$rc,fork_cmd:$fc}')
  _sl_append "$_line"
  # A resume reaches a server that may have been attached-to (not opened) this
  # session — refresh its live-set sidecar.
  _sl_snapshot "$_socket" "$_pid"
}

# Trim the ledger to what a QUERY CAN STILL REACH.
#
# THE KEEP SET IS THE QUERY'S OWN REACHABILITY, NOT A CALENDAR. `sl_dropped`
# collapses to ONE dead server per answer — its final stage takes `NR==1` off a
# ts-desc stream and drops every row of every other server (see its LAST CRASH
# ONLY comment). So for each cwd, exactly one dead server is ever emitted, and
# every older dead server that cwd ever had is unreachable dead weight the fold
# still parses on every ledger-path poll. A time-based cutoff cannot see that: on
# a real dir it left 246 servers across 47 cwds, ~200 of which no query could
# name. What survives here instead:
#   - every LIVE server, in full (it is still accumulating rows, and `forkcmd`
#     reads exactly one of them);
#   - per cwd, the dead server holding the newest EMITTABLE row for it — the one
#     `dropped <cwd>` / `--global` would answer with;
#   - per cwd, the same for the servers the `notified` marker has NOT yet burned,
#     which is the answer `--new`/`--pending` gate to.
# A server serving several cwds wins some and loses others; the keep set is the
# UNION, so it survives whole (rows are only ever dropped a whole server at a
# time — the fold keys on the server, and a half-kept server would rewrite the
# very sets a query intersects).
#
# EMITTABLE MEANS THE ROW WOULD SURVIVE sl_dropped's OWN FILTERS: an agent row
# (`agent != "shell"`) with a resume hint, whose window is in the server's
# live-set sidecar (or whose server has no sidecar at all — the pre-sidecar
# "offer everything" case). Applying anything LOOSER is not the safe direction it
# looks like: the keep set is an ARGMAX, so a server wrongly counted emittable
# does not merely over-retain, it SHADOWS the real winner and prunes it. Hence
# the deliberate asymmetry below — when a sidecar cannot be resolved, that server
# is kept unconditionally AND withheld from the competition, so neither it nor
# anything behind it can be lost.
#
# DEADNESS HERE MUST BE THE QUERY'S DEADNESS, liveness AND the boot epoch: a live
# server whose newest record predates boot is a reused pid, which `sl_dropped`
# treats as dead and offers. Testing liveness alone would rule such a server out
# of the competition and prune the winner behind it.
sl_prune() {
  _sl_enabled || return 0
  _sl_load_dead
  _ledger=$(_sl_ledger); [ -s "$_ledger" ] || return 0
  # The cheap gate that makes this a no-op on the launch path (sl_open calls it on
  # every launch). It stays a bare `wc -l`; everything below is comparatively
  # expensive (210ms at steady state against 23ms for the whole no-op invocation),
  # so nothing may move above this line.
  #
  # THE CAP IS SET AGAINST THE STEADY STATE, NOT AGAINST "BIG". The keep set below
  # is reachability-shaped, so the pruned ledger settles at a size fixed by the
  # number of projects and their windows-open-at-death, not by elapsed time —
  # measured at 272 lines on a real 47-project dir (from 1650). A cap far above
  # that is self-defeating: the ledger would sawtooth up to the cap and spend most
  # of its life at multiples of the content anything can reach, which is exactly
  # the parse cost the keep set exists to remove. 500 is ~1.8x the measured steady
  # state: the ledger every query folds never grows past roughly twice its
  # irreducible content, while at the measured 1.7 lines appended per launch a
  # prune fires only once per ~130 launches — ~1.6ms amortised on top of a gate
  # that is already the cheapest thing in the function.
  _max=${AGENTMUX_LOG_MAX_LINES:-500}
  _lines=$(wc -l < "$_ledger" 2>/dev/null | tr -d ' ')
  [ "${_lines:-0}" -gt "$_max" ] 2>/dev/null || return 0

  _dir=$(_sl_state_dir)
  _boot=$(_sl_boot_epoch)
  _rows=$(mktemp) || return 0
  _sl_fold "$_ledger" > "$_rows"
  if [ ! -s "$_rows" ]; then rm -f "$_rows"; return 0; fi

  # SIDECAR INDEX — ONE awk over the whole glob, never a process per server. The
  # sidecar's identity is (socket, pid) but its FILENAME only carries
  # cksum(socket), and cksum is a fork; with 180 distinct sockets on a real dir,
  # resolving the path forward (as sl_dropped does, per candidate) is exactly the
  # per-server spawn this pass must not pay. So invert it: each `.sock` companion
  # names its own socket, so reading the companions maps every sidecar back to its
  # (socket, pid) in one pass. A companion-less sidecar is the one shape that
  # cannot be placed — it is emitted with an empty socket and handled as UNKNOWN
  # below, never guessed at.
  _side=$(mktemp) || { rm -f "$_rows"; return 0; }
  set -- "$_dir"/live/*.windows
  if [ -e "$1" ]; then
    awk -F"$TAB" -v OFS="$TAB" '
      BEGIN {
        # Index off ARGV, not FILENAME: awk yields no records for an EMPTY sidecar,
        # and an empty sidecar is a real answer ("nothing was open at death"), so a
        # FILENAME-driven index would silently report those servers as sidecar-less
        # and offer every window they ever had.
        for (i = 1; i < ARGC; i++) {
          f = ARGV[i]
          s = ""
          if ((getline s < (f ".sock")) <= 0) s = ""
          close(f ".sock")
          sock[f] = s
          p = f; sub(/\.windows$/, "", p); sub(/.*-/, "", p); pid[f] = p
        }
      }
      # $1 on a 4-field line is the window id and on a legacy bare-id line the whole
      # line — the same equivalence `cut -f1` gives sl_dropped, which reads this set.
      $1 != "" { w[FILENAME] = w[FILENAME] " " $1 }
      END {
        for (i = 1; i < ARGC; i++) {
          f = ARGV[i]
          print "D", f, pid[f], sock[f], substr(w[f], 2)
        }
      }
    ' "$@" 2>/dev/null > "$_side"
  fi

  # Per-server max ts (over ALL its rows, never scoped — that is the fact the boot
  # comparison needs), then the ONE liveness probe per server. `_sl_server_live` is
  # fork-free for every server already in the dead memo, which is the steady state.
  _stat=$(mktemp) || { rm -f "$_rows" "$_side"; return 0; }
  awk -F"$TAB" -v OFS="$TAB" '
    { k = $1 OFS $2; if ($9 + 0 > m[k]) m[k] = $9 + 0 }
    END { for (k in m) print k, m[k] }
  ' "$_rows" | while IFS="$TAB" read -r socket pid smax; do
    [ -n "$pid" ] || continue
    if _sl_server_live "$socket" "$pid" && { [ -z "$_boot" ] || [ "$smax" -ge "$_boot" ] 2>/dev/null; }; then
      printf 'V\t%s\t%s\n' "$socket" "$pid"
    else
      printf 'X\t%s\t%s\n' "$socket" "$pid"
    fi
  done > "$_stat"

  _notmark="$_dir/notified"
  _keepf=$(mktemp) || { rm -f "$_rows" "$_side" "$_stat"; return 0; }
  {
    cat "$_side" "$_stat"
    [ -s "$_notmark" ] && awk '{ print "N\t" $0 }' "$_notmark"
    awk '{ print "R\t" $0 }' "$_rows"
  } | awk -F"$TAB" -v OFS="$TAB" '
      # D: a sidecar, already resolved to (socket, pid). An empty socket means the
      # `.sock` companion was missing/unreadable, so the file can only be placed by
      # its pid — recorded as UNKNOWN for that pid rather than guessed onto a server.
      $1 == "D" {
        if ($4 == "") unkpid[$3] = 1
        else { has[$4 SUBSEP $3] = 1; set[$4 SUBSEP $3] = $5 }
        next
      }
      $1 == "V" { keep[$2 "|" $3] = 1; next }          # live → kept whole, unconditionally
      $1 == "X" { dead[$2 SUBSEP $3] = 1; dsrv[$2 "|" $3] = $2 SUBSEP $3; next }
      $1 == "N" { notif[$2] = 1; next }                # raw "socket|pid|cwd" offer key
      $1 == "R" {
        socket = $2; pid = $3; wid = $4; cwd = $7; agent = $8; rcmd = $9; ts = $10 + 0
        k = socket SUBSEP pid
        if (!(k in dead)) next
        # Sidecar unresolvable for this server: keep it AND withhold it from the
        # argmax. Competing on a guess would shadow (and prune) the true winner;
        # dropping it outright would lose a restore target. Neither is acceptable,
        # and abstaining costs only one retained server.
        if (!(k in has) && (pid in unkpid)) { keep[socket "|" pid] = 1; next }
        if (agent == "shell" || rcmd == "" || cwd == "") next
        if (k in has) {                                # sidecar present → intersect it
          n = split(set[k], a, " "); ok = 0
          for (i = 1; i <= n; i++) if (a[i] == wid) { ok = 1; break }
          if (!ok) next
        }                                              # no sidecar at all → all windows count
        srv = socket "|" pid
        ck = cwd SUBSEP srv
        cw[ck] = cwd; sv[ck] = srv
        if (ts > mx[ck]) mx[ck] = ts
        if (!((srv "|" cwd) in notif)) { seenn[ck] = 1; if (ts > mn[ck]) mn[ck] = ts }
      }
      END {
        # Two argmaxes per cwd — ungated (what `dropped <cwd>`/`--global` answer)
        # and offer-gated (what `--new`/`--pending` answer). Ties keep EVERY server
        # holding the maximum: sl_dropped breaks a ts tie on `sort`s whole-line
        # comparison, which this pass deliberately does not model.
        for (k in mx) { c = cw[k]; if (mx[k] > bx[c]) bx[c] = mx[k] }
        for (k in mx) { c = cw[k]; if (mx[k] == bx[c]) keep[sv[k]] = 1 }
        for (k in seenn) { c = cw[k]; if (mn[k] > bn[c]) bn[c] = mn[k] }
        for (k in seenn) { c = cw[k]; if (mn[k] == bn[c]) keep[sv[k]] = 1 }
        # Emit each kept server once as K (the key the `notified` trim and the
        # sidecar sweep run on), then either A (keep every row) or one W per
        # window (keep only these). A DEAD server with a sidecar is restricted to
        # it: that set is FROZEN — nothing rewrites a dead server sidecar — and it
        # is precisely what sl_dropped intersects its rows against, so a row for a
        # window outside it is already invisible to every query. This, not the
        # server count, is what actually bounds the ledger: a long-lived project
        # shard logs one row per launch forever, but only the windows OPEN AT
        # DEATH are ever restorable. A LIVE server is never restricted — its
        # sidecar is a moving target this pass could race against a concurrent
        # open, and `forkcmd` reads its rows directly.
        for (s in keep) {
          print "K" OFS s
          k = dsrv[s]
          if (k != "" && (k in has)) {
            n = split(set[k], a, " ")
            for (i = 1; i <= n; i++) if (a[i] != "") print "W" OFS s "|" a[i]
            # A row carrying no window_id belongs to no window set, so it rides
            # with its server rather than being silently dropped by the restriction.
            print "W" OFS s "|"
          } else print "A" OFS s
        }
      }
    ' > "$_keepf"
  _whole=$(awk -F"$TAB" '$1=="A"{print $2}' "$_keepf" | jq -R -s 'split("\n") | map(select(length>0))')
  _win=$(awk -F"$TAB" '$1=="W"{print $2}' "$_keepf" | jq -R -s 'split("\n") | map(select(length>0))')
  _keep=$(awk -F"$TAB" '$1=="K"{print $2}' "$_keepf" | jq -R -s 'split("\n") | map(select(length>0))')

  _tmp=$(mktemp) || { rm -f "$_rows" "$_side" "$_stat" "$_keepf"; return 0; }
  jq -cRn --argjson whole "$_whole" --argjson win "$_win" '
    inputs | fromjson?
    | (.socket_path + "|" + (.server_pid|tostring)) as $k
    | ($k + "|" + (.window_id // "")) as $kw
    | select(($whole | index($k)) != null or ($win | index($kw)) != null)
  ' "$_ledger" > "$_tmp" 2>/dev/null && mv "$_tmp" "$_ledger" || rm -f "$_tmp"

  # Trim the `notified` marker the same way as the ledger: it grows one
  # "socket|pid|cwd" line per (server,cwd) offered (sl_dropped --new appends,
  # never prunes), so keep only lines whose "socket|pid" PREFIX is still in the
  # KEEP set. Drops stale keys (and blank lines) so it self-cleans instead of
  # growing unbounded. It must stay in step with the ledger in BOTH directions: a
  # marker outliving its server would gate a server that no longer exists, and one
  # dropped early would re-offer a ghost amux has already cleared.
  if [ -s "$_notmark" ]; then
    _tmpn=$(mktemp) || _tmpn=""
    if [ -n "$_tmpn" ]; then
      jq -Rrn --argjson keep "$_keep" '
        inputs | select(length>0)
        | . as $line
        | ($line | split("|")[0:2] | join("|")) as $sp
        | select($keep | index($sp) != null)
      ' "$_notmark" > "$_tmpn" 2>/dev/null && mv "$_tmpn" "$_notmark" || rm -f "$_tmpn"
    fi
  fi

  # Best-effort marker sweep: drop seen/<pid>-* for pids no longer in the ledger.
  # `${m##*/}` rather than `basename`: this walks every marker on disk (643 on a
  # real dir), and a fork apiece is the cost that made the old sweep the expensive
  # half of a prune.
  _livepids=$(jq -rRn '[ inputs | fromjson? | .server_pid ] | unique | .[]' "$_ledger" 2>/dev/null)
  if [ -d "$_dir/seen" ]; then
    for m in "$_dir"/seen/*; do
      [ -e "$m" ] || continue
      mp=${m##*/}; mp=${mp%%-*}
      case "
$_livepids
" in *"
$mp
"*) : ;; *) rm -f "$m" ;; esac
    done
  fi

  # Sidecar sweep, driven by the SAME keep set as the ledger — the two must agree
  # exactly. A sidecar deleted from under a server the ledger still names flips
  # that server to the "no sidecar → every window was open at death" reading and
  # re-offers tabs that were closed; a sidecar outliving its pruned server lets
  # `_sl_pending_fast` answer "pending" from a candidate the ledger path can no
  # longer see. Matching on (socket, pid) from the `.sock` companion is what makes
  # it exact — a pid-only match keeps a same-pid sidecar belonging to a DIFFERENT
  # socket, which is the second failure above. A companion-less sidecar cannot be
  # placed, so it falls back to the pid and is RETAINED on a match: over-retention
  # is inert (a stale file), where a wrong delete is not.
  if [ -s "$_side" ]; then
    awk -F"$TAB" '
      FNR == NR { if ($1 == "K") { keep[$2] = 1; p = $2; sub(/.*\|/, "", p); kpid[p] = 1 } next }
      $1 == "D" {
        if ($4 != "") { if (($4 "|" $3) in keep) next }
        else if ($3 in kpid) next
        print $2
      }
    ' "$_keepf" "$_side" | while IFS= read -r m; do
      [ -n "$m" ] && rm -f "$m" "$m.sock"
    done
  fi

  rm -f "$_rows" "$_side" "$_stat" "$_keepf"
}

# One-shot backfill of the sidecars already on disk, from the ledger.
#
# WHY IT EXISTS. Everything `_sl_pending_fast` needs is written at EVENT time, so a
# sidecar born under the current code is already correct — but the ones already in
# live/ predate it, and each stale one costs the fast path the cwds it cannot then
# resolve. Two independent shortfalls:
#   - a legacy line (bare window id, no tabs) → that window's cwd is unknown, so the
#     fast path has to join it back through the ledger, and defers for every cwd the
#     join cannot rule it out for (exit 3);
#   - a `.windows` with no `.sock` companion → no socket path, so neither the
#     liveness probe nor that ledger join can run (exit 2 / exit 4).
# This fixes BOTH in one pass, and is idempotent: a second run finds every line
# already 4-field and every companion already present, writes nothing. It buys
# SPEED, never correctness — the fast path is sound on an unmigrated dir, it just
# answers for fewer cwds.
#
# WHAT IT MAY AND MAY NOT DO. It may only ADD FIELDS to lines that are already
# there. A sidecar's set of window ids is the record of what was open at that
# server's death, so the migration never adds an id, never removes one, and never
# creates a sidecar for a server that has none (that absence is what makes the fast
# path defer — see its "sidecar-less server" comment — and inventing one would turn
# a deferral into a silent "no drop"). An EMPTY `.windows` is the sharpest case: it
# means "nothing was open when this server died" (a clean teardown, or `amux
# --kill` via _sl_discard), so it stays byte-for-byte empty — awk yields no records
# for it, so it can never become an output file. It still gains its `.sock`, which
# carries no membership. And a line whose ledger row cannot be found is left
# LEGACY: the fast path then keeps deferring for that sidecar, which is the safe
# direction — a guessed row would be a wrong answer, and 2 must never collapse to 1.
#
# THE FORK BUDGET IS A SINGLE PASS, exactly as on the poll path. The state dir holds
# hundreds of sidecars, and anything run per FILE loses by itself (a per-file awk
# over 214 sidecars measured 3241ms against 32ms for one awk given them all). So:
# one awk to list the ledger's distinct socket paths, ONE `cksum` over all of them
# at once, one awk over (hashes + sockets + ledger + every sidecar), and ONE `mv`
# to publish. The `cksum` batch is what joins a sidecar back to its ledger server:
# the filename hashes the socket (see _sl_sock_hash), so the map has to run the same
# checksum over each candidate socket path — the shell writes each to its own file
# (a builtin `printf`, no fork) and hands the lot to one `cksum`, whose per-file
# output IS the hash table. Using the real binary rather than a reimplementation is
# what guarantees the two can never disagree.
#
# PUBLISHING IS ATOMIC, per file, the same way _sl_snapshot writes: every rewrite
# lands in a staging dir first, and the final `mv` renames each into live/ — a
# rename over the old file, so a concurrent reader sees either the whole old
# sidecar or the whole new one, never a half-written set. Staging under the STATE
# dir (not $TMPDIR) keeps the rename same-filesystem, which is what makes it atomic
# at all. Safe against a live server snapshotting underneath us precisely because
# membership never changes: the worst case is that our rewrite carries the same ids
# the file already had, and the server's next window event re-snapshots anyway.
sl_migrate() {
  _sl_enabled || return 0
  _mg_sd=$(_sl_state_dir)
  [ -d "$_mg_sd/live" ] || return 0
  _mg_ledger="$_mg_sd/$_SL_LEDGER_NAME"
  [ -s "$_mg_ledger" ] || return 0
  set -- "$_mg_sd"/live/*.windows
  [ -e "$1" ] || return 0                    # unmatched glob: nothing to migrate
  _mg_tmp="$_mg_sd/live.migrate.$$"
  rm -rf "$_mg_tmp" 2>/dev/null
  mkdir -p "$_mg_tmp/h" "$_mg_tmp/o" 2>/dev/null || return 1
  # Distinct socket paths, read from the ledger's RAW bytes. A path needing JSON
  # escaping (a quote or backslash in it) is deliberately excluded by the character
  # class: matching it raw would be unsound, and an unmatched socket simply leaves
  # its sidecars alone — the same "defer rather than guess" direction as everywhere
  # else here.
  awk 'match($0, /"socket_path":"[^"\\]*"/) {
         _s = substr($0, RSTART + 15, RLENGTH - 16)
         if (_s != "" && !(_s in seen)) { seen[_s] = 1; print _s }
       }' "$_mg_ledger" > "$_mg_tmp/socks" 2>/dev/null
  # One file per socket path, holding the path with NO trailing newline — byte-for-byte
  # what `_sl_sock_hash` feeds `cksum` on stdin. `printf` is a shell builtin, so this
  # loop forks nothing however many sockets the ledger names.
  _mg_n=0
  while IFS= read -r _mg_sp; do
    _mg_n=$((_mg_n + 1))
    printf '%s' "$_mg_sp" > "$_mg_tmp/h/$_mg_n"
  done < "$_mg_tmp/socks"
  if [ "$_mg_n" -eq 0 ]; then rm -rf "$_mg_tmp"; return 0; fi
  cksum "$_mg_tmp"/h/* > "$_mg_tmp/crcs" 2>/dev/null || { rm -rf "$_mg_tmp"; return 1; }
  # ONE pass over: the checksums, the socket list, the ledger, then every sidecar —
  # in that order, because each stage is built from the one before it. Paths arrive
  # through ENVIRON, not `-v`: `-v` runs its value through escape processing, so a
  # state dir containing a backslash would be mangled.
  _mg_sum=$(SL_MG_OUT="$_mg_tmp/o" awk -F"$TAB" "$_SL_SHAPE_FN"'
      function jstr(l, k,   p) {              # "<k>":"<value>", value needing no escaping
        p = "\"" k "\":\"[^\"\\\\]*\""
        if (!match(l, p)) return ""
        return substr(l, RSTART + length(k) + 4, RLENGTH - length(k) - 5)
      }
      function jnum(l, k,   p) {              # "<k>":<digits>
        p = "\"" k "\":[0-9]+"
        if (!match(l, p)) return ""
        return substr(l, RSTART + length(k) + 3, RLENGTH - length(k) - 3)
      }
      # Emit the sidecar being read, but ONLY if a line actually changed. Closing the
      # handle per file keeps at most one output open: awk caps simultaneously-open
      # files well below the hundreds of sidecars in a real state dir.
      function flush(   i, out) {
        if (curf == "") return
        if (dirty) {
          out = outdir "/" bname[curf]
          for (i = 1; i <= nb; i++) print buf[i] > out
          close(out)
          nenrich++
        }
        curf = ""; nb = 0; dirty = 0
      }
      BEGIN {
        outdir = ENVIRON["SL_MG_OUT"]
        # Index the sidecars straight off ARGV — no file is read to build this, so it
        # still sees the EMPTY ones (awk yields no records for those, yet an empty
        # sidecar is a real answer and must still get its .sock companion).
        for (i = 1; i < ARGC; i++) {
          f = ARGV[i]
          if (f !~ /\.windows$/) continue
          b = f; sub(/.*\//, "", b); bname[f] = b
          s = b; sub(/\.windows$/, "", s)
          p = s; sub(/.*-/, "", p)            # <sockethash>-<pid> → pid
          h = s; sub(/-[^-]*$/, "", h)        #                    → sockethash
          fpid[f] = p; fhash[f] = h
          nfiles++; files[nfiles] = f
        }
      }
      FNR == 1 { fno++ }
      # cksum: "<crc> <size> <path>/h/<i>". Keyed by the trailing index rather than by
      # output order, so a lexicographic glob (h/1, h/10, h/2, …) cannot misalign it.
      # The crc is forced to a STRING before it is used as a subscript: as a number it
      # would round-trip through CONVFMT and index as "1.00309e+09".
      fno == 1 {
        if (!match($0, /\/h\/[0-9]+$/)) next
        idx = substr($0, RSTART + 3, RLENGTH - 3)
        split($0, a, " ")
        crc[idx + 0] = a[1] ""
        next
      }
      fno == 2 {                              # socket list: line N is h/N
        c = crc[FNR] ""
        if (c == "") next
        if ((c in sockof) && sockof[c] != $0) ambig[c] = 1   # two paths, one hash: unusable
        sockof[c] = $0
        next
      }
      fno == 3 {
        sp = jstr($0, "socket_path"); if (sp == "") next
        pid = jnum($0, "server_pid"); if (pid == "") next
        wid = jstr($0, "window_id");  if (wid == "") next
        k = sp SUBSEP pid SUBSEP wid
        if (index($0, "\"event\":\"open\"")) {
          # LAST open wins, matching _sl_fold. An open whose cwd/agent cannot be read
          # raw DELETES the earlier readable one rather than leaving it: the newest
          # record is the truth, and if we cannot represent it the line stays legacy.
          cwd = jstr($0, "cwd"); ag = jstr($0, "agent")
          if (cwd != "" && ag != "") { ocwd[k] = cwd; oag[k] = ag }
          else { delete ocwd[k]; delete oag[k] }
        } else if (index($0, "\"event\":\"resume\"")) {
          # `resumable` mirrors exactly what the ledger path gates on (rcmd != ""), and
          # is decided WITHOUT decoding the command: a resume_cmd containing a backslash
          # must still read as resumable, or the fast path would answer "no drop" where
          # the ledger answers "drop".
          if (index($0, "\"resume_cmd\":\"\"") == 0 && index($0, "\"resume_cmd\":\"") > 0) ores[k] = 1
        }
        next
      }
      FILENAME ~ /\.windows$/ {
        if (FILENAME != curf) { flush(); curf = FILENAME }
        nb++
        # Already current (shared classifier — a 4-field line with an EMPTY cwd is
        # an unstamped window, not a current one, and is backfilled like any other
        # legacy line) — never rewritten.
        if (sl_line_current()) { buf[nb] = $0; next }
        if ($1 == "") { buf[nb] = $0; nleg++; next }
        h = fhash[FILENAME] ""
        if ((h in ambig) || sockof[h] == "") { buf[nb] = $0; nleg++; next }
        k = sockof[h] SUBSEP fpid[FILENAME] SUBSEP $1
        if (!(k in ocwd)) { buf[nb] = $0; nleg++; next }   # no ledger row → leave legacy
        buf[nb] = $1 "\t" ocwd[k] "\t" oag[k] "\t" ((k in ores) ? "1" : "")
        dirty = 1
      }
      END {
        flush()
        for (i = 1; i <= nfiles; i++) {
          f = files[i]; h = fhash[f] ""
          if ((h in ambig) || sockof[h] == "") continue
          sf = f ".sock"
          line = ""
          got = (getline line < sf); close(sf)
          if (got > 0 && line != "") continue  # present and non-empty: the -s guard _sl_snapshot uses
          of = outdir "/" bname[f] ".sock"
          print sockof[h] > of
          close(of)
          nsock++
        }
        printf "enriched=%d sock=%d legacy_left=%d\n", nenrich + 0, nsock + 0, nleg + 0
      }
    ' "$_mg_tmp/crcs" "$_mg_tmp/socks" "$_mg_ledger" "$@") || { rm -rf "$_mg_tmp"; return 1; }
  # Publish. One `mv` for every staged file: each rename is atomic on its own, and
  # nothing is staged at all when the run was a no-op, so an already-migrated state
  # dir is not even touched.
  set -- "$_mg_tmp"/o/*
  if [ -e "$1" ]; then
    mv "$_mg_tmp"/o/* "$_mg_sd/live/" 2>/dev/null || true
  fi
  rm -rf "$_mg_tmp"
  printf 'migrate: %s\n' "$_mg_sum"
}

# ---- dispatch ----
if [ "${SESSION_LOG_SELFTEST:-}" != "1" ]; then
  cmd="${1:-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    open)      sl_open      "$@" ;;
    resume)    sl_resume    "$@" ;;
    dropped)   sl_dropped   "$@" ;;
    forkcmd)   sl_forkcmd   "$@" ;;
    prune)     sl_prune     "$@" ;;
    snapshot)  sl_snapshot  "$@" ;;
    discard)   sl_discard   "$@" ;;
    migrate)   sl_migrate   "$@" ;;
    *) echo "session_log.sh: unknown subcommand '$cmd'" >&2; exit 2 ;;
  esac
  exit 0
fi

# ============================ selftest ============================
# SESSION_LOG_SELFTEST=1 sh scripts/session_log.sh
#
# **Footgun** — clear the selftest marker FIRST, before anything spawns a child.
# It arrives as an EXPORTED env var (test.sh runs `env SESSION_LOG_SELFTEST=1 sh
# …`), so every descendant inherits it — including the real tmux SERVERS the
# end-to-end blocks below start, which are daemons that outlive this run and
# invoke this script again from their own hooks at arbitrary later times. A hook
# child that inherits the marker skips the dispatcher entirely and falls into
# THIS selftest, which starts another real server, whose hooks fall in again:
# an exponential fork bomb (observed: ~100k processes, load 50, PID counter
# wrapped). Unsetting here is the single point that keeps every child clean —
# do not push this down to individual `tmux` invocations.
unset SESSION_LOG_SELFTEST

AGENTMUX_STATE_DIR=$(mktemp -d) || exit 1
AGENTMUX_SESSION_LOG=1
export AGENTMUX_STATE_DIR AGENTMUX_SESSION_LOG
trap 'rm -rf "$AGENTMUX_STATE_DIR"' EXIT

pass=0; fail=0
_assert() {  # <desc> <expected> <actual>
  if [ "$3" = "$2" ]; then pass=$((pass+1)); echo "PASS: $1"
  else fail=$((fail+1)); echo "FAIL: $1 — expected '$2' got '$3'"; fi
}

# Stub tmux: canned display-message context, no real server needed. A `-S <socket>` call
# (every _sl_server_live liveness probe / snapshot) returns no pid → the server reads DEAD,
# and when _SL_TEST_PROBED is set the socket is tallied there — the seam the scoping test
# uses to see WHICH servers a query actually probes (inline-set like the SESSION_LOG_* hooks).
tmux() {
  [ -n "${_SL_TEST_PROBED:-}" ] && [ "$1" = "-S" ] && printf '%s\n' "$2" >> "$_SL_TEST_PROBED"
  case "$1 $2" in
    "display-message -p")
      # honour an optional -t TARGET (ignored — fixed context) by shifting it off
      shift 2; [ "$1" = "-t" ] && shift 2
      printf '/tmp/tmux-501/default\t4242\tlocus\t@3\tclaude\t/tmp/work\n' ;;
    *) return 0 ;;
  esac
}

# --- open ---
sl_open claude
ledger="$AGENTMUX_STATE_DIR/sessions.jsonl"
_assert "open writes one line" "1" "$(wc -l < "$ledger" | tr -d ' ')"
_assert "open event"   "open"   "$(jq -r '.event' "$ledger")"
_assert "open agent"   "claude" "$(jq -r '.agent' "$ledger")"
_assert "open pid num" "4242"   "$(jq -r '.server_pid' "$ledger")"
_assert "open cwd"     "/tmp/work" "$(jq -r '.cwd' "$ledger")"

# --- guard requires wid too: pid-populated-but-window-id-empty must NOT write
#     (Finding 2 — a display-message that resolves the SERVER but not the
#     TARGET can exit 0 with #{pid} populated and the target-scoped fields
#     empty; the guard must fail soft on that, never emit a windowless row).
#     Shape verified empirically against a real tmux server: `display-message
#     -p -t <nonexistent-session>` exits 0 and emits "<socket>\t<pid>\t\t\t\t\n"
#     — session_name/window_id/window_name/cwd all empty, pid alone populated
#     (SESSION_LOG_CTX below mirrors that exact shape; it bypasses tmux
#     entirely so this is independent of the stub above). ---
rm -f "$ledger"
SESSION_LOG_CTX="/s/x${TAB}4242${TAB}${TAB}${TAB}${TAB}" sl_open claude
_assert "open: pid without window id writes nothing" "0" \
  "$([ -f "$ledger" ] && wc -l < "$ledger" | tr -d ' ' || echo 0)"
rm -f "$ledger"

# --- disabled → no write ---
rm -f "$ledger"
AGENTMUX_SESSION_LOG=0 sl_open claude
_assert "disabled: no ledger" "0" "$([ -f "$ledger" ] && echo 1 || echo 0)"

# --- fold carries the latest-ts column (recency ordering) ---
rm -f "$ledger"; unset AGENTMUX_SESSION_LOG; AGENTMUX_SESSION_LOG=1
cat > "$ledger" <<'JSON'
{"ts":10,"event":"open","socket_path":"/s/a","server_pid":4242,"session":"locus","window_id":"@1","window_name":"claude","cwd":"/w/locus","agent":"work"}
{"ts":42,"event":"resume","socket_path":"/s/a","server_pid":4242,"window_id":"@1","label":"a1b2","resume_cmd":"claude --resume a1b2"}
{"ts":20,"event":"open","socket_path":"/s/b","server_pid":9981,"session":"red","window_id":"@1","window_name":"claude","cwd":"/w/red","agent":"personal"}
JSON
foldout=$(_sl_fold "$ledger")
_assert "fold lists every opened window" "2" "$(printf '%s\n' "$foldout" | grep -c .)"
_assert "fold spans 2 distinct servers"  "2" "$(printf '%s\n' "$foldout" | cut -f2 | sort -u | grep -c .)"
# maxts is column 9 (fork_cmd is appended after it, at column 10): locus = max(10,42) = 42
_assert "fold trailing col is max ts"    "42" "$(printf '%s\n' "$foldout" | awk -F'\t' '$6=="/w/locus"{print $9}')"

# ============ sl_dropped: restorable dropped tabs ============
RMAP="work$(printf '\t')claude-work
personal$(printf '\t')claude-personal"

# server 4242 LIVE (its windows are not "dropped"); 9981 DEAD with a sidecar
# recording only @1 open at death (@2 was closed earlier → omitted).
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"; mkdir -p "$AGENTMUX_STATE_DIR/live"
cat > "$ledger" <<JSON
{"ts":200,"event":"open","socket_path":"/s/a","server_pid":4242,"session":"locus","window_id":"@1","window_name":"claude","cwd":"/w/locus","agent":"work"}
{"ts":201,"event":"resume","socket_path":"/s/a","server_pid":4242,"window_id":"@1","label":"live1","resume_cmd":"claude --resume live1"}
{"ts":100,"event":"open","socket_path":"/s/b","server_pid":9981,"session":"locus","window_id":"@1","window_name":"claude","cwd":"/w/locus","agent":"work"}
{"ts":101,"event":"resume","socket_path":"/s/b","server_pid":9981,"window_id":"@1","label":"drop1","resume_cmd":"claude --resume drop1"}
{"ts":90,"event":"open","socket_path":"/s/b","server_pid":9981,"session":"old","window_id":"@2","window_name":"claude","cwd":"/w/locus","agent":"work"}
{"ts":91,"event":"resume","socket_path":"/s/b","server_pid":9981,"window_id":"@2","label":"closed2","resume_cmd":"claude --resume closed2"}
{"ts":80,"event":"open","socket_path":"/s/b","server_pid":9981,"session":"notes","window_id":"@3","window_name":"claude","cwd":"/w/notes","agent":"personal"}
{"ts":81,"event":"resume","socket_path":"/s/b","server_pid":9981,"window_id":"@3","label":"drop3","resume_cmd":"claude --resume drop3"}
{"ts":70,"event":"open","socket_path":"/s/b","server_pid":9981,"session":"sh","window_id":"@4","window_name":"shell","cwd":"/w/locus","agent":"shell"}
JSON
printf '@1\n@3\n' > "$(_sl_live_file "/s/b" 9981)"   # @1,@3 open at death; @2 closed earlier

# per-project /w/locus: only @1 (dead, open-at-death, work) — NOT @2 (closed),
# NOT @4 (shell), NOT the live server's window, NOT /w/notes.
out=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped "/w/locus")
_assert "dropped(locus): one row"        "1"          "$(printf '%s\n' "$out" | grep -c .)"
_assert "dropped(locus): agent"          "work"       "$(printf '%s\n' "$out" | cut -f1)"
_assert "dropped(locus): cwd"            "/w/locus"   "$(printf '%s\n' "$out" | cut -f2)"
_assert "dropped(locus): swapped resume" "claude-work --resume drop1" "$(printf '%s\n' "$out" | cut -f3)"
_assert "dropped(locus): omits live"     "0"          "$(printf '%s\n' "$out" | grep -c 'live1')"
_assert "dropped(locus): omits closed"   "0"          "$(printf '%s\n' "$out" | grep -c 'closed2')"
_assert "dropped(locus): omits notes"    "0"          "$(printf '%s\n' "$out" | grep -c 'drop3')"
_assert "dropped(locus): omits shell"    "0"          "$(printf '%s\n' "$out" | grep -c '@4\|shell')"

# --global: both dead dropped tabs (drop1 in locus, drop3 in notes), swapped.
outg=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --global)
_assert "dropped(--global): two rows"    "2"          "$(printf '%s\n' "$outg" | grep -c .)"
_assert "dropped(--global): has drop1"   "1"          "$(printf '%s\n' "$outg" | grep -c 'claude-work --resume drop1')"
_assert "dropped(--global): has drop3"   "1"          "$(printf '%s\n' "$outg" | grep -c 'claude-personal --resume drop3')"

# ============ --pending: --new's filter, without --new's marking ============
# --pending sees an un-offered drop, exactly as --new would.
outp=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending "/w/locus")
# What --pending PROMISES is a boolean: its only consumer (bin/amux's _amux_probe)
# tests the output for emptiness and never reads the rows, so the sidecar fast path
# answers it with one synthetic line. Assert that contract, not the row text.
_assert "pending: sees un-offered drop"  "1"  "$([ -n "$outp" ] && echo 1 || echo 0)"
# This fixture's sidecar is the LEGACY single-field shape (`@1\n@3` above), so the
# fast path reads "cannot answer" and $outp came from the ledger fallback — which is
# why the program-swapped row is still assertable here. That fallback shares its
# emitter with --new, and that emitter is what keeps the restore picker honest, so
# it is worth pinning; the assertion is only meaningful while the fixture stays legacy.
_assert "pending(ledger fallback): swaps the resume program" "1" \
  "$(printf '%s\n' "$outp" | grep -c 'claude-work --resume drop1')"

# GATE (Task 2): a cwd that never appears in the ledger returns empty via the fast path — the
# same answer as the slow path, so this must hold both before and after the gate is added.
outabs=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending "/w/never-logged")
_assert "pending: absent cwd → empty" "0" "$(printf '%s' "$outabs" | grep -c .)"

# GATE FALSE-NEGATIVE GUARD (review fix): a cwd containing a literal " is stored
# JSON-escaped in the ledger ( \" ), so a naive grep -qF for the BARE scope would never
# match it — the gate must recognise that and fall through to the (always-correct) slow,
# jq-decoded path instead of wrongly returning empty for a cwd that has a real restorable
# session. Append a dead, sidecar-less server whose cwd carries a literal ".
cat >> "$ledger" <<JSON
{"ts":150,"event":"open","socket_path":"/s/q","server_pid":9993,"session":"quo","window_id":"@1","window_name":"claude","cwd":"/w/qu\"ote","agent":"work"}
{"ts":151,"event":"resume","socket_path":"/s/q","server_pid":9993,"window_id":"@1","label":"dropq","resume_cmd":"claude --resume dropq"}
JSON
outq=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending '/w/qu"ote')
_assert "pending: quote-containing cwd not false-dropped (gate falls through)" "1" "$(printf '%s\n' "$outq" | grep -c 'dropq')"

# ===== SCOPE THE LIVENESS SWEEP: a scoped query must only tmux-probe servers that ran in
#       that cwd, never every server in the ledger. This is the perf fix for warden's ~5s
#       per-dir presence probe: _sl_server_live spawns a tmux per server, and the old sweep
#       probed ALL of them (a stale-heavy ledger → O(all-servers) per poll). Isolated ledger
#       + a tallying tmux stub (which socket each liveness probe hit) prove which servers ran.
_scope_dir=$(mktemp -d) || exit 1
cat > "$_scope_dir/sessions.jsonl" <<JSON
{"ts":100,"event":"open","socket_path":"/s/here","server_pid":111,"session":"h","window_id":"@1","window_name":"claude","cwd":"/w/here","agent":"work"}
{"ts":101,"event":"resume","socket_path":"/s/here","server_pid":111,"window_id":"@1","label":"drophere","resume_cmd":"claude --resume drophere"}
{"ts":200,"event":"open","socket_path":"/s/elsewhere","server_pid":222,"session":"e","window_id":"@1","window_name":"claude","cwd":"/w/elsewhere","agent":"work"}
{"ts":201,"event":"resume","socket_path":"/s/elsewhere","server_pid":222,"window_id":"@1","label":"dropelse","resume_cmd":"claude --resume dropelse"}
JSON
_scope_probed="$_scope_dir/probed"; : > "$_scope_probed"
# No SESSION_LOG_LIVE_PIDS here — we WANT _sl_server_live to run (via the stub, which reads
# every server dead) so _SL_TEST_PROBED records which sockets the sweep actually probed.
scope_out=$(_SL_TEST_PROBED="$_scope_probed" AGENTMUX_STATE_DIR="$_scope_dir" \
  SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending "/w/here")
_assert "scope: still finds this-cwd drop"       "1" "$(printf '%s\n' "$scope_out" | grep -c 'drophere')"
_assert "scope: omits other-cwd drop"            "0" "$(printf '%s\n' "$scope_out" | grep -c 'dropelse')"
_assert "scope: probed the this-cwd server"      "1" "$(grep -c '/s/here' "$_scope_probed")"
_assert "scope: did NOT probe the other server"  "0" "$(grep -c '/s/elsewhere' "$_scope_probed")"
: > "$_scope_probed"
# Drop the dead-memo the scoped query above just populated. This assertion measures SCOPE
# (does --global narrow the server set?), and the memo is an orthogonal concern with its own
# coverage below — leaving it would make /s/here a memo hit and silently turn a scope
# regression into a passing test. Independent observations need independent memo state.
rm -f "$_scope_dir/dead"
# Wrapped in $() so the prefix assignments stay scoped to the subshell (a bare prefix on a
# function call persists in POSIX sh); the tally write lands in the outer $_scope_probed file.
_ignore=$(_SL_TEST_PROBED="$_scope_probed" AGENTMUX_STATE_DIR="$_scope_dir" \
  SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --global)
_assert "scope(--global): still probes every server" "2" "$(sort -u "$_scope_probed" | grep -c .)"

# --- dead-server memo -----------------------------------------------------------
# Death is monotonic, so a (socket,pid) proven dead must never be re-probed: warden polls
# --pending per session-less tab, and without this every poll forked a tmux per dead server
# recorded for that cwd — unbounded, for an answer that cannot change.
_has_memo() { grep -qxF "$1" "$_scope_dir/dead" 2>/dev/null && echo 1 || echo 0; }
rm -f "$_scope_dir/dead"; : > "$_scope_probed"
_memo1=$(_SL_TEST_PROBED="$_scope_probed" AGENTMUX_STATE_DIR="$_scope_dir" \
  SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending "/w/here")
_assert "memo: first query probes the server"  "1" "$(grep -c '/s/here' "$_scope_probed")"
_assert "memo: records the proven-dead server" "1" "$(_has_memo '/s/here|111')"
: > "$_scope_probed"
_memo2=$(_SL_TEST_PROBED="$_scope_probed" AGENTMUX_STATE_DIR="$_scope_dir" \
  SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending "/w/here")
_assert "memo: second query re-probes nothing" "0" "$(grep -c '/s/here' "$_scope_probed")"
# The point of the memo is that it changes COST, never the ANSWER.
_assert "memo: answer is unchanged"            "$_memo1" "$_memo2"
# Pid reuse is the one way a memoised pair can answer again, and such a server always
# snapshots before anything polls it — so the snapshot is the complete invalidation.
_ignore=$(SESSION_LOG_LIVE_WINDOWS="@1" AGENTMUX_STATE_DIR="$_scope_dir" _sl_snapshot "/s/here" 111)
_assert "memo: snapshot clears the entry"      "0" "$(_has_memo '/s/here|111')"
rm -rf "$_scope_dir"; unset _ignore

# THE REGRESSION GUARD: --pending must not write the notified marker. If it did, warden's
# 5s probe would burn the gate on its first pass and the ghost would render once, never again.
rm -f "$(_sl_state_dir)/notified"
SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending "/w/locus" >/dev/null
_assert "pending: does NOT mark notified" "0" "$([ -s "$(_sl_state_dir)/notified" ] && echo 1 || echo 0)"

# --pending is repeatable: N calls give the same answer (the polling case).
outp2=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending "/w/locus")
_assert "pending: repeatable"            "$outp"  "$outp2"

# --pending respects a marker --new already wrote (the ghost clears once amux has offered).
rm -f "$(_sl_state_dir)/notified"
SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --new "/w/locus" >/dev/null
outp3=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending "/w/locus")
_assert "pending: empty after --new offered" "0" "$(printf '%s' "$outp3" | grep -c .)"
rm -f "$(_sl_state_dir)/notified"

# ---- Task 1: sl_open stamps cwd + agent onto the window --------------------
# unset SESSION_LOG_CTX defensively: an earlier test's prefix assignment
# (SESSION_LOG_CTX="..." sl_open claude) leaks past the command when sl_open
# is a shell FUNCTION and this file runs under `sh` — verified: bash in POSIX
# mode does not restore a prefix-assigned var after a function call, unlike a
# real external command. Without this, _sl_ctx would return the stale mock
# instead of querying the real tmux server started below.
unset SESSION_LOG_CTX
# `command tmux` (not bare `tmux`): a `tmux()` stub function is still active
# here from earlier mocked tests (only unset much further down, for the
# real-tmux e2e blocks) and would otherwise shadow every direct call this
# test makes. sl_open's OWN internal tmux calls are unaffected — they all go
# through `env -u TMUX tmux …`, and `env` execs the real binary via PATH,
# never resolving a same-named shell function.
_t1_dir=$(mktemp -d) || exit 1
_t1_sock="agentmux-t1-$$"
if command -v tmux >/dev/null 2>&1; then
  TMUX_TMPDIR="$_t1_dir" command tmux -L "$_t1_sock" -f /dev/null new-session -d -s t1 -c /tmp 2>/dev/null
  _t1_wid=$(TMUX_TMPDIR="$_t1_dir" command tmux -L "$_t1_sock" display-message -p -t t1 '#{window_id}' 2>/dev/null)
  _ignore=$(AGENTMUX_STATE_DIR="$_t1_dir" TMUX_TMPDIR="$_t1_dir" sl_open work t1 "$_t1_sock")
  _assert "t1: stamps @amux_agent" "work" \
    "$(TMUX_TMPDIR="$_t1_dir" command tmux -L "$_t1_sock" show-options -qvw -t "$_t1_wid" @amux_agent 2>/dev/null)"
  # Expected value is /tmp's REALPATH, not the literal string: tmux's
  # #{pane_current_path} (what $_cwd is sourced from) always reports the
  # resolved physical path, and on macOS /tmp is itself a symlink to
  # /private/tmp — a literal "/tmp" here would fail on any box where that
  # symlink exists, which is every stock macOS install.
  _t1_tmp_real=$(cd /tmp && pwd -P)
  _assert "t1: stamps @amux_cwd" "$_t1_tmp_real" \
    "$(TMUX_TMPDIR="$_t1_dir" command tmux -L "$_t1_sock" show-options -qvw -t "$_t1_wid" @amux_cwd 2>/dev/null)"
  TMUX_TMPDIR="$_t1_dir" command tmux -L "$_t1_sock" kill-server 2>/dev/null
else
  echo "SKIP: t1 (tmux not found)"
fi
rm -rf "$_t1_dir"

# ---- Task 2: sl_resume marks the window resumable --------------------------
# unset defensively: an earlier test's prefix-assigned SESSION_LOG_CTX can
# leak past a function call under this shell (same trap Task 1 hit above).
unset SESSION_LOG_CTX
_t2_dir=$(mktemp -d) || exit 1
_t2_sock="agentmux-t2-$$"
if command -v tmux >/dev/null 2>&1; then
  TMUX_TMPDIR="$_t2_dir" command tmux -L "$_t2_sock" -f /dev/null new-session -d -s t2 -c /tmp 2>/dev/null
  _t2_wid=$(TMUX_TMPDIR="$_t2_dir" command tmux -L "$_t2_sock" display-message -p -t t2 '#{window_id}' 2>/dev/null)
  # _sl_mark_resumable takes a socket PATH (tmux -S), not the -L NAME this test
  # server was started with — resolve the real path tmux reports for it, the
  # same value _sl_ctx's #{socket_path} field yields in production.
  _t2_path=$(TMUX_TMPDIR="$_t2_dir" command tmux -L "$_t2_sock" display-message -p -t t2 '#{socket_path}' 2>/dev/null)
  _assert "t2: not resumable before" "" \
    "$(TMUX_TMPDIR="$_t2_dir" command tmux -L "$_t2_sock" show-options -qvw -t "$_t2_wid" @amux_resumable 2>/dev/null)"
  _ignore=$(AGENTMUX_STATE_DIR="$_t2_dir" TMUX_TMPDIR="$_t2_dir" \
    SESSION_LOG_CTX="/s/x${TAB}999${TAB}t2${TAB}${_t2_wid}${TAB}claude${TAB}/tmp" \
    _sl_mark_resumable "$_t2_path" "$_t2_wid" "claude --resume abc")
  _assert "t2: resumable after"      "1" \
    "$(TMUX_TMPDIR="$_t2_dir" command tmux -L "$_t2_sock" show-options -qvw -t "$_t2_wid" @amux_resumable 2>/dev/null)"
  _ignore=$(AGENTMUX_STATE_DIR="$_t2_dir" TMUX_TMPDIR="$_t2_dir" \
    _sl_mark_resumable "$_t2_path" "$_t2_wid" "")
  _assert "t2: empty cmd clears it"  "" \
    "$(TMUX_TMPDIR="$_t2_dir" command tmux -L "$_t2_sock" show-options -qvw -t "$_t2_wid" @amux_resumable 2>/dev/null)"

  # ---- Task 2 (call-site integration): drive sl_resume() ITSELF, not
  # _sl_mark_resumable directly — the three assertions above all still pass
  # even if sl_resume's call to _sl_mark_resumable (session_log.sh line ~624)
  # is replaced with a no-op, since none of them go through sl_resume. Point
  # SESSION_LOG_CTX at the real test server/window so the option write lands
  # on the real tmux server, and assert on that server's actual option value.
  unset TMUX TMUX_PANE
  _ignore=$(AGENTMUX_STATE_DIR="$_t2_dir" TMUX_TMPDIR="$_t2_dir" \
    SESSION_LOG_CTX="${_t2_path}${TAB}999${TAB}t2${TAB}${_t2_wid}${TAB}claude${TAB}/tmp" \
    sl_resume "t2-integration" "claude --resume t2int")
  _assert "t2: sl_resume() itself marks the window resumable" "1" \
    "$(TMUX_TMPDIR="$_t2_dir" command tmux -L "$_t2_sock" show-options -qvw -t "$_t2_wid" @amux_resumable 2>/dev/null)"

  TMUX_TMPDIR="$_t2_dir" command tmux -L "$_t2_sock" kill-server 2>/dev/null
else
  echo "SKIP: t2 (tmux not found)"
fi
rm -rf "$_t2_dir"

# dead server with NO sidecar (pre-feature) → all its windows count as dropped.
rm -rf "$AGENTMUX_STATE_DIR/live"
outn=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped "/w/locus")
_assert "dropped(no sidecar): shows @1"  "1"          "$(printf '%s\n' "$outn" | grep -c 'drop1')"
_assert "dropped(no sidecar): shows @2"  "1"          "$(printf '%s\n' "$outn" | grep -c 'closed2')"

# --- --new marks a (server,cwd) offered → second call for the SAME cwd is empty,
#     but a DIFFERENT cwd from the same dead server is still offered. ---
rm -rf "$AGENTMUX_STATE_DIR/live"; rm -f "$AGENTMUX_STATE_DIR/notified"
n1=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --new "/w/locus")
_assert "--new(locus): first call shows"  "1" "$(printf '%s\n' "$n1" | grep -c 'drop1')"
n2=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --new "/w/locus")
_assert "--new(locus): second call empty" ""  "$n2"
n3=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --new "/w/notes")
_assert "--new(notes): other cwd still offered" "1" "$(printf '%s\n' "$n3" | grep -c 'drop3')"

# --- LAST-CRASH-ONLY: with multiple dead servers, only the most-recently-active one
#     is offered; older dead servers are history. Plus dedup: a session resumed across
#     both servers surfaces once (from the newer). 7001 older (ts≤103), 7002 newer. ---
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live" "$AGENTMUX_STATE_DIR/notified"
cat > "$ledger" <<JSON
{"ts":100,"event":"open","socket_path":"/s/a","server_pid":7001,"session":"proj","window_id":"@1","window_name":"claude","cwd":"/w/proj","agent":"work"}
{"ts":101,"event":"resume","socket_path":"/s/a","server_pid":7001,"window_id":"@1","label":"older","resume_cmd":"claude --resume older"}
{"ts":102,"event":"open","socket_path":"/s/a","server_pid":7001,"session":"proj","window_id":"@2","window_name":"claude","cwd":"/w/proj","agent":"work"}
{"ts":103,"event":"resume","socket_path":"/s/a","server_pid":7001,"window_id":"@2","label":"shared","resume_cmd":"claude --resume shared"}
{"ts":200,"event":"open","socket_path":"/s/b","server_pid":7002,"session":"proj","window_id":"@1","window_name":"claude","cwd":"/w/proj","agent":"work"}
{"ts":201,"event":"resume","socket_path":"/s/b","server_pid":7002,"window_id":"@1","label":"newer","resume_cmd":"claude --resume newer"}
{"ts":202,"event":"open","socket_path":"/s/b","server_pid":7002,"session":"proj","window_id":"@2","window_name":"claude","cwd":"/w/proj","agent":"work"}
{"ts":203,"event":"resume","socket_path":"/s/b","server_pid":7002,"window_id":"@2","label":"shared","resume_cmd":"claude --resume shared"}
JSON
lc=$(SESSION_LOG_LIVE_PIDS="" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped "/w/proj")
_assert "last-crash: shows newest server's tab"      "1" "$(printf '%s\n' "$lc" | grep -c 'newer')"
_assert "last-crash: hides older server's tab"       "0" "$(printf '%s\n' "$lc" | grep -c 'older')"
_assert "last-crash: shared uuid shown once"         "1" "$(printf '%s\n' "$lc" | grep -c 'shared')"
_assert "last-crash: exactly 2 rows (newest server)" "2" "$(printf '%s\n' "$lc" | grep -c .)"

# --- dedup within one server: same session uuid in two windows → one row ---
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"
cat > "$ledger" <<JSON
{"ts":300,"event":"open","socket_path":"/s/c","server_pid":7003,"session":"p","window_id":"@1","window_name":"claude","cwd":"/w/dup","agent":"work"}
{"ts":301,"event":"resume","socket_path":"/s/c","server_pid":7003,"window_id":"@1","label":"same","resume_cmd":"claude --resume same"}
{"ts":302,"event":"open","socket_path":"/s/c","server_pid":7003,"session":"p","window_id":"@2","window_name":"claude","cwd":"/w/dup","agent":"work"}
{"ts":303,"event":"resume","socket_path":"/s/c","server_pid":7003,"window_id":"@2","label":"same","resume_cmd":"claude --resume same"}
JSON
dd=$(SESSION_LOG_LIVE_PIDS="" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped "/w/dup")
_assert "dedup: same uuid two windows → one row" "1" "$(printf '%s\n' "$dd" | grep -c .)"

# --- ROW ORDER = ORIGINAL TAB ORDER (window-id ascending), NOT recency. The rows
#     feed _amux_restore_into, which creates one window per line IN ORDER (first
#     line replaces window 0), so the emitted order IS the restored tab order —
#     emitting ts-desc restored a crashed session with its tabs reversed. The
#     internal ts-desc sort is still required (last-crash scoping + dedup), so the
#     ordering is re-applied after it. @10 is in the fixture on purpose: a
#     lexicographic sort puts it between @1 and @2. ---
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"
cat > "$ledger" <<JSON
{"ts":100,"event":"open","socket_path":"/s/o","server_pid":7009,"session":"p","window_id":"@1","window_name":"claude","cwd":"/w/ord","agent":"work"}
{"ts":110,"event":"resume","socket_path":"/s/o","server_pid":7009,"window_id":"@1","label":"one","resume_cmd":"claude --resume one"}
{"ts":200,"event":"open","socket_path":"/s/o","server_pid":7009,"session":"p","window_id":"@2","window_name":"claude","cwd":"/w/ord","agent":"work"}
{"ts":210,"event":"resume","socket_path":"/s/o","server_pid":7009,"window_id":"@2","label":"two","resume_cmd":"claude --resume two"}
{"ts":300,"event":"open","socket_path":"/s/o","server_pid":7009,"session":"p","window_id":"@10","window_name":"claude","cwd":"/w/ord","agent":"work"}
{"ts":310,"event":"resume","socket_path":"/s/o","server_pid":7009,"window_id":"@10","label":"ten","resume_cmd":"claude --resume ten"}
JSON
od=$(SESSION_LOG_LIVE_PIDS="" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped "/w/ord")
_assert "order: tabs emit in original (window-id) order" "one two ten" \
  "$(printf '%s\n' "$od" | awk -F'\t' '{n=split($3,g," "); printf "%s%s", (NR>1?" ":""), g[n]} END{print ""}')"
_assert "order: all three rows present" "3" "$(printf '%s\n' "$od" | grep -c .)"
# The maxts column still carries each tab's own recency (the picker renders it as
# an "(ago)" per row), so ordering by window id must not have rewritten it.
_assert "order: maxts still per-row recency" "110 210 310" \
  "$(printf '%s\n' "$od" | awk -F'\t' '{printf "%s%s", (NR>1?" ":""), $4} END{print ""}')"

# --- --global honours last-crash-only too: newest dead server, across all its cwds ---
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"
cat > "$ledger" <<JSON
{"ts":100,"event":"open","socket_path":"/s/a","server_pid":8001,"session":"x","window_id":"@1","window_name":"claude","cwd":"/w/old","agent":"work"}
{"ts":101,"event":"resume","socket_path":"/s/a","server_pid":8001,"window_id":"@1","label":"oldg","resume_cmd":"claude --resume oldg"}
{"ts":200,"event":"open","socket_path":"/s/b","server_pid":8002,"session":"y","window_id":"@1","window_name":"claude","cwd":"/w/new1","agent":"work"}
{"ts":201,"event":"resume","socket_path":"/s/b","server_pid":8002,"window_id":"@1","label":"newg1","resume_cmd":"claude --resume newg1"}
{"ts":202,"event":"open","socket_path":"/s/b","server_pid":8002,"session":"z","window_id":"@2","window_name":"claude","cwd":"/w/new2","agent":"work"}
{"ts":203,"event":"resume","socket_path":"/s/b","server_pid":8002,"window_id":"@2","label":"newg2","resume_cmd":"claude --resume newg2"}
JSON
g=$(SESSION_LOG_LIVE_PIDS="" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --global)
_assert "global last-crash: newest server both cwds" "2" "$(printf '%s\n' "$g" | grep -c .)"
_assert "global last-crash: hides older server"      "0" "$(printf '%s\n' "$g" | grep -c 'oldg')"
_assert "global last-crash: shows newest new1"       "1" "$(printf '%s\n' "$g" | grep -c 'newg1')"
_assert "global last-crash: shows newest new2"       "1" "$(printf '%s\n' "$g" | grep -c 'newg2')"

# --- resume enrichment + dedup, env-less FALLBACK path (no $TMUX → key derived
#     from the stubbed _sl_ctx: pid 4242, @3) ---
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/seen"
unset TMUX TMUX_PANE
sl_resume "9f3c" "claude --resume 9f3c"
_assert "resume writes one" "1" "$(grep -c '"event":"resume"' "$ledger")"
sl_resume "9f3c" "claude --resume 9f3c"
_assert "resume dedups same label" "1" "$(grep -c '"event":"resume"' "$ledger")"
sl_resume "abcd" "claude --resume abcd"
_assert "resume writes on new label" "2" "$(grep -c '"event":"resume"' "$ledger")"

# --- fork_cmd: recorded by the adapter, surfaced as fold column 10 ------------
ledger=$(_sl_ledger)
: > "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/seen"
SESSION_LOG_CTX="/s/f${TAB}5150${TAB}sess${TAB}@7${TAB}win${TAB}/tmp/proj"
export SESSION_LOG_CTX
sl_resume "u1" "claude --resume u1" "claude --resume u1 --fork-session"
_assert "fork_cmd: stored on the resume event" \
  "claude --resume u1 --fork-session" \
  "$(jq -r 'select(.event=="resume") | .fork_cmd' "$ledger")"

# fold must surface fork_cmd as column 10, leaving 1..9 untouched.
seedf=$(mktemp)
cat > "$seedf" <<'EOF'
{"ts":1,"event":"open","socket_path":"/s/f","server_pid":5150,"window_id":"@7","session":"sess","window_name":"win","cwd":"/tmp/proj","agent":"work"}
{"ts":2,"event":"resume","socket_path":"/s/f","server_pid":5150,"window_id":"@7","label":"u1","resume_cmd":"claude --resume u1","fork_cmd":"claude --resume u1 --fork-session"}
EOF
_assert "fold: fork_cmd is column 10" "claude --resume u1 --fork-session" \
  "$(_sl_fold "$seedf" | cut -f10)"
_assert "fold: maxts stays column 9" "2" "$(_sl_fold "$seedf" | cut -f9)"
_assert "fold: resume_cmd stays column 8" "claude --resume u1" \
  "$(_sl_fold "$seedf" | cut -f8)"

# A pre-fork_cmd event (no field) folds to an empty column 10, not a crash.
seedo=$(mktemp)
cat > "$seedo" <<'EOF'
{"ts":1,"event":"open","socket_path":"/s/f","server_pid":5150,"window_id":"@7","session":"sess","window_name":"win","cwd":"/tmp/proj","agent":"work"}
{"ts":2,"event":"resume","socket_path":"/s/f","server_pid":5150,"window_id":"@7","label":"u1","resume_cmd":"claude --resume u1"}
EOF
_assert "fold: legacy event → empty fork_cmd" "" "$(_sl_fold "$seedo" | cut -f10)"

# --- marker keys on the FULL record signature, not the label -----------------
# The upgrade trap: a live tab whose marker already holds its label must still
# write a new event once the record gains a fork_cmd, else prefix-f no-ops forever.
: > "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/seen"
sl_resume "u2" "claude --resume u2"
_assert "marker: first record writes" "1" "$(grep -c '"event":"resume"' "$ledger")"
sl_resume "u2" "claude --resume u2"
_assert "marker: identical record dedups" "1" "$(grep -c '"event":"resume"' "$ledger")"
sl_resume "u2" "claude --resume u2" "claude --resume u2 --fork-session"
_assert "marker: same label + NEW fork_cmd writes (upgrade self-heal)" "2" \
  "$(grep -c '"event":"resume"' "$ledger")"
sl_resume "u2" "claude --resume u2" "claude --resume u2 --fork-session"
_assert "marker: repeat of the enriched record dedups" "2" \
  "$(grep -c '"event":"resume"' "$ledger")"
unset SESSION_LOG_CTX
rm -f "$seedf" "$seedo"

# --- forkcmd: one LIVE window's fork command, program-swapped ----------------
seedk=$(mktemp)
cat > "$seedk" <<'EOF'
{"ts":1,"event":"open","socket_path":"/s/k","server_pid":6001,"window_id":"@1","session":"proj","window_name":"work","cwd":"/tmp/proj","agent":"work"}
{"ts":2,"event":"resume","socket_path":"/s/k","server_pid":6001,"window_id":"@1","label":"uu1","resume_cmd":"claude --resume uu1","fork_cmd":"claude --resume uu1 --fork-session"}
{"ts":3,"event":"open","socket_path":"/s/k","server_pid":6001,"window_id":"@2","session":"proj","window_name":"pers","cwd":"/tmp/proj","agent":"personal"}
{"ts":4,"event":"resume","socket_path":"/s/k","server_pid":6001,"window_id":"@2","label":"uu2","resume_cmd":"claude --resume uu2","fork_cmd":"claude --resume uu2 --fork-session"}
{"ts":5,"event":"open","socket_path":"/s/k","server_pid":6001,"window_id":"@3","session":"proj","window_name":"shell","cwd":"/tmp/proj","agent":"shell"}
{"ts":6,"event":"open","socket_path":"/s/k","server_pid":6001,"window_id":"@4","session":"proj","window_name":"oc","cwd":"/tmp/proj","agent":"opencode"}
{"ts":7,"event":"resume","socket_path":"/s/k","server_pid":6001,"window_id":"@4","label":"uu4","resume_cmd":"opencode --resume uu4","fork_cmd":""}
{"ts":8,"event":"open","socket_path":"/s/k","server_pid":6001,"window_id":"@5","session":"proj","window_name":"fresh","cwd":"/tmp/proj","agent":"work"}
{"ts":9,"event":"open","socket_path":"/s/k","server_pid":6001,"window_id":"@6","session":"proj","window_name":"gm","cwd":"/tmp/proj","agent":"gemini"}
{"ts":10,"event":"resume","socket_path":"/s/k","server_pid":6001,"window_id":"@6","label":"uu6","resume_cmd":"gemini --resume uu6","fork_cmd":"gemini --resume uu6 --fork-session"}
{"ts":11,"event":"open","socket_path":"/s/k","server_pid":6001,"window_id":"@7","session":"proj","window_name":"nospace","cwd":"/tmp/proj","agent":"work"}
{"ts":12,"event":"resume","socket_path":"/s/k","server_pid":6001,"window_id":"@7","label":"uu7","resume_cmd":"claude --resume uu7","fork_cmd":"claude"}
EOF
cp "$seedk" "$(_sl_ledger)"
SESSION_LOG_RESUME_MAP="work${TAB}claude-work
personal${TAB}claude-personal"
export SESSION_LOG_RESUME_MAP

_fc() {  # <window_id> — run forkcmd with ctx pinned to that window
  SESSION_LOG_CTX="/s/k${TAB}6001${TAB}proj${TAB}$1${TAB}w${TAB}/tmp/proj" \
    sl_forkcmd
}
_assert "forkcmd: work tab → claude-work, program swapped" \
  "work${TAB}claude-work --resume uu1 --fork-session" "$(_fc @1)"
_assert "forkcmd: personal tab → claude-personal" \
  "personal${TAB}claude-personal --resume uu2 --fork-session" "$(_fc @2)"
_assert "forkcmd: shell agent → nothing" "" "$(_fc @3)"
_assert "forkcmd: agent with no fork_cmd → nothing" "" "$(_fc @4)"
_assert "forkcmd: tab with no resume record → nothing" "" "$(_fc @5)"
# swap_prog empty-program branch (p==""): the common case — an agent with no
# [[agents]] resume override (not in SESSION_LOG_RESUME_MAP at all) must pass
# its fork_cmd through UNCHANGED, not blanked or truncated.
_assert "forkcmd: agent outside resume map passes through unswapped" \
  "gemini${TAB}gemini --resume uu6 --fork-session" "$(_fc @6)"
# swap_prog no-space branch (return p): a single-token fork_cmd for an agent
# that IS in the map must collapse to just the swapped program.
_assert "forkcmd: single-token fork_cmd swaps to bare program" \
  "work${TAB}claude-work" "$(_fc @7)"
_assert "forkcmd: unknown window → nothing" "" "$(_fc @99)"
_assert "forkcmd: emits at most one line" "1" "$(_fc @1 | wc -l | tr -d ' ')"

# A DIFFERENT server with the same window_id must not bleed through: window ids
# are unique per server only, and under --frame the agent runs two tmux deep.
_assert "forkcmd: other server's @1 is not ours" "" \
  "$(SESSION_LOG_CTX="/s/other${TAB}6002${TAB}proj${TAB}@1${TAB}w${TAB}/tmp/proj" sl_forkcmd)"
unset SESSION_LOG_RESUME_MAP
rm -f "$seedk"

# --- resume FAST path: dedup keyed by tmux's exported env ($TMUX serverpid +
#     $TMUX_PANE), so a repeat label short-circuits WITHOUT spawning tmux. A
#     call-logging stub records every _sl_ctx invocation to a file (survives the
#     command-substitution subshell that a counter var would not). ---
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/seen"; mkdir -p "$AGENTMUX_STATE_DIR/seen"
_ctxlog="$AGENTMUX_STATE_DIR/ctxlog"; : > "$_ctxlog"
tmux() { echo x >> "$_ctxlog"; printf '/tmp/s\t7777\tsess\t@1\twin\t/w\n'; }
export TMUX="/tmp/s,7777,0" TMUX_PANE="%9"
printf 'lbl1|claude --resume lbl1|' > "$AGENTMUX_STATE_DIR/seen/7777-p9"   # pre-seed the env-keyed marker (full signature)
sl_resume "lbl1" "claude --resume lbl1"                      # repeat label → dedup
_assert "fast path dedups without spawning tmux" "0" "$(grep -c x "$_ctxlog")"
_assert "fast path dedup writes nothing"         "0" "$([ -f "$ledger" ] && grep -c . "$ledger" || echo 0)"
# distinct namespaces: a window "@9" marker must NOT be read as the pane "%9" one
printf 'other' > "$AGENTMUX_STATE_DIR/seen/7777-9"
sl_resume "lbl1" "claude --resume lbl1"
_assert "pane key disjoint from window key" "0" "$(grep -c x "$_ctxlog")"
# a NEW label falls through to _sl_ctx (tmux consulted) + a ledger write
SESSION_LOG_LIVE_WINDOWS="@1" sl_resume "lbl2" "claude --resume lbl2"
_assert "fast path new label writes one"       "1" "$(grep -c '"label":"lbl2"' "$ledger")"
_assert "fast path new label consulted tmux"   "yes" "$([ "$(grep -c x "$_ctxlog")" -ge 1 ] && echo yes || echo no)"
unset TMUX TMUX_PANE
# restore the canonical stub for the blocks that follow
tmux() {
  case "$1 $2" in
    "display-message -p")
      shift 2; [ "$1" = "-t" ] && shift 2
      printf '/tmp/tmux-501/default\t4242\tlocus\t@3\tclaude\t/tmp/work\n' ;;
    *) return 0 ;;
  esac
}
# fold must surface the LATEST resume cmd for that window
seedl="$AGENTMUX_STATE_DIR/seed.jsonl"
cat > "$seedl" <<'JSON'
{"ts":1,"event":"open","socket_path":"/s/a","server_pid":4242,"session":"locus","window_id":"@3","window_name":"claude","cwd":"/w/locus","agent":"claude"}
{"ts":2,"event":"resume","socket_path":"/s/a","server_pid":4242,"window_id":"@3","label":"old","resume_cmd":"claude --resume old"}
{"ts":3,"event":"resume","socket_path":"/s/a","server_pid":4242,"window_id":"@3","label":"new","resume_cmd":"claude --resume new"}
JSON
_assert "fold takes latest resume" "1" "$(_sl_fold "$seedl" | grep -c 'claude --resume new')"

# ============ prune: the keep set is the QUERY'S REACHABILITY ============
# sl_dropped collapses to ONE dead server per answer (its NR==1 "last crash only"
# stage), so every dead server behind the winner for a cwd is unreachable and
# prune drops it. These blocks pin that, and every drop is paired with a MUTATION
# that flips the same fixture the other way — a keep-everything prune would pass
# the "kept" half alone, so the pairs are what make them non-vacuous.

# <ts> <socket> <pid> <wid> <cwd> <label> → the two rows that make one EMITTABLE
# window (an agent open + a resume hint; either one missing and no query can
# reach it).
_pr_pair() {
  printf '{"ts":%s,"event":"open","socket_path":"%s","server_pid":%s,"session":"s","window_id":"%s","window_name":"claude","cwd":"%s","agent":"claude"}\n' \
    "$1" "$2" "$3" "$4" "$5"
  printf '{"ts":%s,"event":"resume","socket_path":"%s","server_pid":%s,"window_id":"%s","label":"%s","resume_cmd":"claude --resume %s"}\n' \
    "$(( $1 + 1 ))" "$2" "$3" "$4" "$6" "$6"
}
_pr_rows() { grep -c "\"server_pid\":$1," "$ledger"; }             # <pid>
_pr_ask()  { SESSION_LOG_LIVE_PIDS="${_pr_live:-}" SESSION_LOG_BOOT_EPOCH="${_pr_boot:-1}" \
             SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped "$@"; }
_pr_prune() { AGENTMUX_LOG_MAX_LINES=1 SESSION_LOG_LIVE_PIDS="${_pr_live:-}" \
              SESSION_LOG_BOOT_EPOCH="${_pr_boot:-1}" sl_prune; }

# --- the per-cwd winner survives, the runners-up do not ---------------------
# All rows emittable, no sidecars anywhere (so every window counts):
#   301  /w/a ts100                       → /w/a runner-up  → DROPPED
#   302  /w/a ts200 (loses) + /w/b ts250  → /w/b winner     → KEPT (the union)
#   303  /w/a ts300                       → /w/a winner     → KEPT
#   304  /w/b ts150                       → /w/b runner-up  → DROPPED
#   999  /w/a ts50 + /w/a ts60, LIVE      → loses every cwd → KEPT (live)
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live" "$AGENTMUX_STATE_DIR/seen"
rm -f "$AGENTMUX_STATE_DIR/notified"
_pr_reach() {
  { _pr_pair 100 /s/301 301 @1 /w/a r301
    _pr_pair 200 /s/302 302 @1 /w/a r302a
    _pr_pair 250 /s/302 302 @2 /w/b r302b
    _pr_pair 300 /s/303 303 @1 /w/a r303
    _pr_pair 150 /s/304 304 @1 /w/b r304
    _pr_pair 50  /s/999 999 @1 /w/a r999a
    _pr_pair 60  /s/999 999 @2 /w/a r999b
  } > "$ledger"
}
_pr_live="999"; _pr_boot=1
_pr_reach
_pr_a=$(_pr_ask /w/a); _pr_b=$(_pr_ask /w/b); _pr_g=$(_pr_ask --global)
_pr_prune
_assert "prune drops /w/a's runner-up (301)"                 "0" "$(_pr_rows 301)"
_assert "prune drops /w/b's runner-up (304)"                 "0" "$(_pr_rows 304)"
_assert "prune keeps /w/a's newest dead server (303)"        "2" "$(_pr_rows 303)"
_assert "prune keeps a server that wins /w/b, loses /w/a"    "4" "$(_pr_rows 302)"
_assert "prune keeps a LIVE server that loses every cwd"     "4" "$(_pr_rows 999)"
# The whole point: the pruned ledger answers every query byte-identically.
_assert "prune lossless: dropped /w/a"    "$_pr_a" "$(_pr_ask /w/a)"
_assert "prune lossless: dropped /w/b"    "$_pr_b" "$(_pr_ask /w/b)"
_assert "prune lossless: dropped --global" "$_pr_g" "$(_pr_ask --global)"

# MUTATION 1 — 301 is dropped for being second, not for being 301: make it /w/a's
# NEWEST and the verdict inverts.
_pr_reach
sed 's/"ts":100,/"ts":400,/; s/"ts":101,/"ts":401,/' "$ledger" > "$ledger.m" && mv "$ledger.m" "$ledger"
_pr_prune
_assert "MUTATION: 301 newest for /w/a → kept"               "2" "$(_pr_rows 301)"
_assert "MUTATION: 303 now second for /w/a → dropped"        "0" "$(_pr_rows 303)"

# MUTATION 2 — 302 survives because of its /w/b win, not its /w/a rows: strip the
# /w/b pair and the same server, with the same losing /w/a rows, is dropped.
_pr_reach
grep -v '/w/b' "$ledger" > "$ledger.m" && mv "$ledger.m" "$ledger"
_pr_prune
_assert "MUTATION: 302 without its /w/b win → dropped"       "0" "$(_pr_rows 302)"

# MUTATION 3 — 999 survives on LIVENESS, not on its rows: with nothing live it is
# just the oldest loser in two cwds.
_pr_reach
_pr_live=""; _pr_prune; _pr_live="999"
_assert "MUTATION: 999 no longer live → dropped"             "0" "$(_pr_rows 999)"

# --- deadness is LIVENESS *AND* THE BOOT EPOCH, exactly as the query reads it --
# A live server whose newest record predates boot is a reused pid: sl_dropped
# treats it as dead and OFFERS it. Prune must not use a narrower notion of live
# than that — a server it wrongly calls dead joins the argmax, wins the cwd, and
# evicts the server the query would really have answered with.
#   888 live-per-hook, /w/d ts100 · 889 dead, /w/d ts50
rm -f "$ledger"
_pr_boot_fixture() {
  { _pr_pair 100 /s/888 888 @1 /w/d r888
    _pr_pair 50  /s/889 889 @1 /w/d r889
  } > "$ledger"
}
_pr_boot_fixture; _pr_live="888"; _pr_boot=1
_pr_d=$(_pr_ask /w/d)
_assert "boot: a genuinely live server offers nothing"       "1" \
  "$(printf '%s\n' "$_pr_d" | grep -c 'r889')"
_pr_prune
_assert "boot: live 888 kept whole"                          "2" "$(_pr_rows 888)"
_assert "boot: dead 889 is /w/d's answer → kept"             "2" "$(_pr_rows 889)"
_assert "boot: lossless"                                     "$_pr_d" "$(_pr_ask /w/d)"

# MUTATION — same fixture, boot moved PAST 888's newest record. The query now
# reads 888 as dead and it outranks 889, so 889 becomes unreachable.
_pr_boot_fixture; _pr_boot=200
_pr_d=$(_pr_ask /w/d)
_assert "MUTATION: pre-boot 'live' server is offered"        "1" \
  "$(printf '%s\n' "$_pr_d" | grep -c 'r888')"
_pr_prune
_assert "MUTATION: pre-boot 888 kept (it is the answer)"     "2" "$(_pr_rows 888)"
_assert "MUTATION: 889 now behind it → dropped"              "0" "$(_pr_rows 889)"
_assert "MUTATION: still lossless"                           "$_pr_d" "$(_pr_ask /w/d)"
_pr_boot=1

# --- the offer gate reaches PAST the winner, so the keep set must too ---------
# --new/--pending skip servers the `notified` marker has already burned for that
# cwd, so the reachable server there is the newest NOT-yet-offered one — a second
# argmax, and dropping it would silently stop ghosting a real crash.
#   501 /w/e ts300, already notified · 502 /w/e ts200, not notified
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"
_pr_gate_fixture() {
  { _pr_pair 300 /s/501 501 @1 /w/e r501
    _pr_pair 200 /s/502 502 @1 /w/e r502
  } > "$ledger"
  printf '%s\n' '/s/501|501|/w/e' '' > "$AGENTMUX_STATE_DIR/notified"
}
_pr_gate_fixture
_pr_e=$(_pr_ask /w/e); _pr_p=$(AMUX_PENDING_NO_FAST=1 _pr_ask --pending /w/e)
_assert "gate: ungated /w/e answers with the newest (501)"   "1" \
  "$(printf '%s\n' "$_pr_e" | grep -c 'r501')"
_assert "gate: --pending skips it and answers with 502"      "1" \
  "$(printf '%s\n' "$_pr_p" | grep -c 'r502')"
_pr_prune
_assert "gate: ungated winner 501 kept"                      "2" "$(_pr_rows 501)"
_assert "gate: offer-gated winner 502 kept"                  "2" "$(_pr_rows 502)"
_assert "gate: lossless (ungated)"                           "$_pr_e" "$(_pr_ask /w/e)"
_assert "gate: lossless (--pending)"  "$_pr_p" "$(AMUX_PENDING_NO_FAST=1 _pr_ask --pending /w/e)"
_assert "gate: notified keeps its live key"                  "1" \
  "$(grep -c '^/s/501|501|/w/e$' "$AGENTMUX_STATE_DIR/notified")"
_assert "gate: notified drops blank lines"                   "0" \
  "$(grep -cx '' "$AGENTMUX_STATE_DIR/notified")"

# MUTATION — 502 survives only because the gate can reach it: clear the marker and
# 501 wins both argmaxes, leaving 502 unreachable.
_pr_gate_fixture
: > "$AGENTMUX_STATE_DIR/notified"
_pr_prune
_assert "MUTATION: nothing notified → 502 unreachable, dropped" "0" "$(_pr_rows 502)"
_assert "MUTATION: 501 still kept"                             "2" "$(_pr_rows 501)"

# --- sidecars are swept on the SAME keep set as the ledger --------------------
# Two failure shapes this pins. A sidecar deleted from under a server the ledger
# still names flips it to the "no sidecar → every window was open at death"
# reading and re-offers closed tabs. A sidecar outliving its pruned server lets
# _sl_pending_fast answer "pending" from a candidate the ledger can no longer see
# — and matching on PID ALONE causes exactly that, because a same-pid sidecar on a
# DIFFERENT socket looks kept. Hence 601 twice, on two sockets:
#   /s/k 601 /w/f ts300 → /w/f winner  → KEPT
#   /s/d 602 /w/f ts100 → runner-up    → DROPPED
#   /s/e 601 /w/g ts50  → runner-up    → DROPPED, though pid 601 is still in the ledger
#   /s/g 603 /w/g ts400 → /w/g winner  → KEPT
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"; mkdir -p "$AGENTMUX_STATE_DIR/live"
{ _pr_pair 300 /s/k 601 @1 /w/f rk
  _pr_pair 100 /s/d 602 @1 /w/f rd
  _pr_pair 50  /s/e 601 @1 /w/g re
  _pr_pair 400 /s/g 603 @1 /w/g rg
} > "$ledger"
for _pr_s in "/s/k 601" "/s/d 602" "/s/e 601" "/s/g 603"; do
  # shellcheck disable=SC2086  # deliberate: split the "socket pid" pair
  set -- $_pr_s
  printf '@1\t/w/x\tclaude\t1\n' > "$(_sl_live_file "$1" "$2")"
  printf '%s\n' "$1" > "$(_sl_live_file "$1" "$2").sock"
done
printf '%s\n' '/s/k|601|/w/f' '/s/d|602|/w/f' > "$AGENTMUX_STATE_DIR/notified"
_pr_prune
_assert "sweep: kept server keeps its sidecar"     "1" "$([ -f "$(_sl_live_file /s/k 601)" ] && echo 1 || echo 0)"
_assert "sweep: kept server keeps its .sock"       "1" "$([ -f "$(_sl_live_file /s/k 601).sock" ] && echo 1 || echo 0)"
_assert "sweep: pruned server loses its sidecar"   "0" "$([ -f "$(_sl_live_file /s/d 602)" ] && echo 1 || echo 0)"
_assert "sweep: pruned server loses its .sock"     "0" "$([ -f "$(_sl_live_file /s/d 602).sock" ] && echo 1 || echo 0)"
_assert "sweep: same-pid sidecar on a pruned socket goes too" "0" \
  "$([ -f "$(_sl_live_file /s/e 601)" ] && echo 1 || echo 0)"
_assert "sweep: /w/g's winner keeps its sidecar"   "1" "$([ -f "$(_sl_live_file /s/g 603)" ] && echo 1 || echo 0)"
_assert "sweep: notified drops the pruned server's key" "0" \
  "$(grep -c '^/s/d|602|/w/f$' "$AGENTMUX_STATE_DIR/notified")"
_assert "sweep: notified keeps the kept server's key"   "1" \
  "$(grep -c '^/s/k|601|/w/f$' "$AGENTMUX_STATE_DIR/notified")"
# The invariant behind all of the above: NO server may survive in the ledger
# having lost the sidecar it had. Checked over the whole pruned dir, not per case.
_pr_orphans=0
for _pr_s in "/s/k 601" "/s/g 603"; do
  # shellcheck disable=SC2086
  set -- $_pr_s
  grep -q "\"socket_path\":\"$1\",\"server_pid\":$2," "$ledger" || continue
  [ -f "$(_sl_live_file "$1" "$2")" ] || _pr_orphans=$((_pr_orphans + 1))
done
_assert "sweep: no ledger server left without its sidecar" "0" "$_pr_orphans"

# --- a kept dead server is trimmed to the windows in its own sidecar ----------
# The sidecar of a DEAD server is frozen, and it is exactly the set sl_dropped
# intersects rows against — so a row for a window outside it is already invisible
# to every query. This, not the server count, is what bounds the ledger: a
# long-lived project shard logs a row per launch forever, but only the windows
# open AT DEATH are ever restorable.
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"; mkdir -p "$AGENTMUX_STATE_DIR/live"
_pr_win_fixture() {  # [sidecar window set]
  { _pr_pair 300 /s/w 701 @1 /w/h rw1
    _pr_pair 100 /s/w 701 @2 /w/h rw2
  } > "$ledger"
  printf '%s' "${1:-@1}" | tr ' ' '\n' | sed 's/$/\t\/w\/h\tclaude\t1/' > "$(_sl_live_file /s/w 701)"
  printf '/s/w\n' > "$(_sl_live_file /s/w 701).sock"
}
_pr_win_fixture
_pr_h=$(_pr_ask /w/h)
_pr_prune
_assert "windows: row for the open-at-death window kept"  "2" "$(grep -c '"window_id":"@1"' "$ledger")"
_assert "windows: row for the closed window dropped"      "0" "$(grep -c '"window_id":"@2"' "$ledger")"
_assert "windows: lossless"                               "$_pr_h" "$(_pr_ask /w/h)"

# MUTATION 1 — @2 is dropped for being outside the sidecar, not for being second:
# put it in the set and it stays.
_pr_win_fixture "@1 @2"
_pr_prune
_assert "MUTATION: @2 in the sidecar → its rows kept"     "2" "$(grep -c '"window_id":"@2"' "$ledger")"

# MUTATION 2 — a sidecar with no .sock companion cannot be placed on a server, so
# prune ABSTAINS: it keeps that server whole rather than trimming on a guess (and
# withholds it from the argmax, which is why nothing else can be evicted by it).
_pr_win_fixture
rm -f "$(_sl_live_file /s/w 701).sock"
_pr_prune
_assert "MUTATION: unplaceable sidecar → server kept whole" "2" "$(grep -c '"window_id":"@2"' "$ledger")"
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live" "$AGENTMUX_STATE_DIR/notified"
unset _pr_live _pr_boot

# --- fold tolerates a torn/corrupt line (kill-server mid-append) → roster survives ---
rm -f "$ledger"
printf '%s\n' \
  '{"ts":1,"event":"open","socket_path":"/s/a","server_pid":111,"session":"x","window_id":"@1","window_name":"claude","cwd":"/w/keep1","agent":"claude"}' \
  '{"ts":2,"event":"open","socket_path":"/s/b","server_pid":222,"session":"y","windo' \
  '{"ts":3,"event":"open","socket_path":"/s/c","server_pid":333,"session":"z","window_id":"@1","window_name":"claude","cwd":"/w/keep2","agent":"claude"}' \
  > "$ledger"
_assert "fold survives torn line (keep1)" "1" "$(_sl_fold "$ledger" | grep -c '/w/keep1')"
_assert "fold survives torn line (keep2)" "1" "$(_sl_fold "$ledger" | grep -c '/w/keep2')"

# --- prune is WIRED into sl_open: a launch trims a dead+old server over the cap ---
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/seen"
_veryold=$(( $(date +%s) - 60*86400 ))
cat > "$ledger" <<JSON
{"ts":$_veryold,"event":"open","socket_path":"/s/gone","server_pid":777,"session":"g","window_id":"@1","window_name":"claude","cwd":"/w/gone","agent":"claude"}
JSON
AGENTMUX_LOG_MAX_LINES=1 SESSION_LOG_LIVE_PIDS="4242" sl_open claude   # stub → live pid 4242
_assert "sl_open triggers prune (drops dead+old)" "0" "$(grep -c '"server_pid":777' "$ledger")"
_assert "sl_open logged its own open"             "1" "$(grep -c '"server_pid":4242' "$ledger")"

# --- _sl_ctx uses $TMUX_PANE for the no-target (resume) path, not a context-less
#     query (which tmux resolves to the ACTIVE window → resume misattribution).
#     NOTE: redefines the tmux stub to capture args — keep this block LAST. ---
_captured=""
tmux() { _captured="$*"; printf '/s/x\t1\tsess\t@9\twin\t/w\n'; }
TMUX_PANE='%7' _sl_ctx >/dev/null
case "$_captured" in *"-t %7"*) _got=yes ;; *) _got=no ;; esac
_assert "no-target ctx uses \$TMUX_PANE" "yes" "$_got"
TMUX_PANE='%7' _sl_ctx '=s:0' >/dev/null
case "$_captured" in *"-t =s:0"*) _got=yes ;; *) _got=no ;; esac
_assert "explicit target overrides \$TMUX_PANE" "yes" "$_got"

# ============ live-set sidecar: confident dead-server recovery ============

# --- _sl_snapshot writes the current live window set to a (socket,pid) sidecar ---
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"
SESSION_LOG_LIVE_WINDOWS="@1 @2 @5" _sl_snapshot "/s/a" 4242
_lf_4242=$(_sl_live_file "/s/a" 4242)
_assert "snapshot writes sidecar file" "1" "$([ -f "$_lf_4242" ] && echo 1 || echo 0)"
_assert "snapshot records the window set" "@1 @2 @5" "$(tr '\n' ' ' < "$_lf_4242" | sed 's/ *$//')"

# --- socket+pid keying: same pid on TWO sockets → DISTINCT sidecars (regression).
#     A pid-only key let a reused pid on a new socket overwrite a dead server's
#     sidecar, silently hiding its recoverable rows. Fold the socket in → no clash.
rm -rf "$AGENTMUX_STATE_DIR/live"
SESSION_LOG_LIVE_WINDOWS="@5 @6" _sl_snapshot "/s/a" 100
SESSION_LOG_LIVE_WINDOWS="@1"    _sl_snapshot "/s/b" 100
_assert "same pid, distinct sockets → distinct paths" "no" \
  "$([ "$(_sl_live_file "/s/a" 100)" = "$(_sl_live_file "/s/b" 100)" ] && echo yes || echo no)"
_assert "socket A sidecar intact after B snapshot" "@5 @6" \
  "$(tr '\n' ' ' < "$(_sl_live_file "/s/a" 100)" | sed 's/ *$//')"
_assert "socket B sidecar keeps its own set"       "@1" \
  "$(tr '\n' ' ' < "$(_sl_live_file "/s/b" 100)" | sed 's/ *$//')"
rm -rf "$AGENTMUX_STATE_DIR/live"

# --- Finding 1 regression: a REAL multi-line 4-field sidecar (window_id, cwd,
#     agent, resumable — the on-disk shape since 35b4303) must offer ALL its
#     windows on restore, not just the first. Written directly to disk, NOT
#     via SESSION_LOG_LIVE_WINDOWS (that hook only ever emits bare ids, which
#     is exactly why this regression stayed green: tr '\n' ' ' on a sidecar
#     whose lines carry tabs collapses newlines but preserves the tabs, so
#     field 4 of the flattened "S" record holds only the FIRST window id —
#     the rest spill into $5, $6, … and never reach lw[], so every other
#     window's ledger row is silently skipped). Self-contained: own ledger
#     content + own live/ sidecar, cleaned up before the next block. ---
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"; mkdir -p "$AGENTMUX_STATE_DIR/live"
cat > "$ledger" <<JSON
{"ts":100,"event":"open","socket_path":"/s/mw","server_pid":5555,"session":"multi","window_id":"@1","window_name":"claude","cwd":"/w/multi","agent":"work"}
{"ts":101,"event":"resume","socket_path":"/s/mw","server_pid":5555,"window_id":"@1","label":"mw1","resume_cmd":"claude --resume mw1"}
{"ts":102,"event":"open","socket_path":"/s/mw","server_pid":5555,"session":"multi","window_id":"@2","window_name":"claude","cwd":"/w/multi","agent":"work"}
{"ts":103,"event":"resume","socket_path":"/s/mw","server_pid":5555,"window_id":"@2","label":"mw2","resume_cmd":"claude --resume mw2"}
JSON
printf '@1\t/w/multi\twork\t0\n@2\t/w/multi\twork\t0\n' > "$(_sl_live_file "/s/mw" 5555)"
mw=$(SESSION_LOG_LIVE_PIDS="" SESSION_LOG_BOOT_EPOCH=1 sl_dropped "/w/multi")
_assert "4-field sidecar: both windows offered" "2" "$(printf '%s\n' "$mw" | grep -c .)"
_assert "4-field sidecar: window 1 offered"     "1" "$(printf '%s\n' "$mw" | grep -c 'mw1')"
_assert "4-field sidecar: window 2 offered"     "1" "$(printf '%s\n' "$mw" | grep -c 'mw2')"
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"

# --- prune removes sidecars for dropped servers ---
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"; mkdir -p "$AGENTMUX_STATE_DIR/live"
now=$(date +%s); old=$(( now - 30*86400 ))
cat > "$ledger" <<JSON
{"ts":$old,"event":"open","socket_path":"/s/dead","server_pid":111,"session":"a","window_id":"@1","window_name":"claude","cwd":"/w/a","agent":"claude"}
{"ts":$now,"event":"open","socket_path":"/s/live","server_pid":222,"session":"b","window_id":"@1","window_name":"claude","cwd":"/w/b","agent":"claude"}
JSON
_lf_dead=$(_sl_live_file "/s/dead" 111); _lf_live=$(_sl_live_file "/s/live" 222)
printf '@1\n' > "$_lf_dead"   # dead+old → sweep
printf '@1\n' > "$_lf_live"   # live → keep
# Finding 2: every sidecar has a `.sock` companion; the sweep must take it with
# the `.windows` file it belongs to, or every snapshot ever taken leaks one
# permanent file into live/ forever.
printf '%s\n' "/s/dead" > "$_lf_dead.sock"
printf '%s\n' "/s/live" > "$_lf_live.sock"
AGENTMUX_LOG_MAX_LINES=1 SESSION_LOG_LIVE_PIDS="222" sl_prune
_assert "prune removes dead sidecar"      "0" "$([ -f "$_lf_dead" ] && echo 1 || echo 0)"
_assert "prune keeps live sidecar"        "1" "$([ -f "$_lf_live" ] && echo 1 || echo 0)"
_assert "prune removes dead sidecar's .sock companion" "0" \
  "$([ -f "$_lf_dead.sock" ] && echo 1 || echo 0)"
_assert "prune keeps live sidecar's .sock companion"   "1" \
  "$([ -f "$_lf_live.sock" ] && echo 1 || echo 0)"

# --- snapshot subcommand re-records the live window set (the window-unlinked hook
#     path — this is how CLOSES are caught: re-query the whole set, closed window
#     already absent; no loop, no heartbeat) ---
rm -rf "$AGENTMUX_STATE_DIR/live"
SESSION_LOG_LIVE_WINDOWS="@3 @7" sl_snapshot "/s/a" 5150
_assert "snapshot subcommand writes sidecar" "@3 @7" "$(tr '\n' ' ' < "$(_sl_live_file "/s/a" 5150)" | sed 's/ *$//')"

# --- discard subcommand marks a server's windows as DELIBERATELY closed (the
#     amux --kill path — killing a per-project shard's only session tears down the
#     whole server before window-unlinked can snapshot, so an empty sidecar is
#     written explicitly instead). It writes an EMPTY sidecar (file present, no
#     window ids): at read time sl_dropped intersects each row against the empty
#     set → nothing offered. Distinct from an ABSENT sidecar (pre-feature dead
#     server → offer ALL windows), which is why discard writes rather than deletes.
rm -rf "$AGENTMUX_STATE_DIR/live"; mkdir -p "$AGENTMUX_STATE_DIR/live"
printf '@1\n@2\n' > "$(_sl_live_file "/s/d" 6060)"   # populated: two windows open
sl_discard "/s/d" 6060
_assert "discard writes an empty sidecar (file present)" "1" \
  "$([ -f "$(_sl_live_file "/s/d" 6060)" ] && echo 1 || echo 0)"
_assert "discard sidecar has no window ids" "0" \
  "$(grep -c . "$(_sl_live_file "/s/d" 6060)")"

# End-to-end: a dead server whose sidecar was discarded offers NOTHING for restore
# (the deliberate-kill case), whereas the same dead server with its windows still
# in the sidecar WOULD be offered (the crash case) — this is the exact regression
# the amux --kill fix relies on.
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/live"; mkdir -p "$AGENTMUX_STATE_DIR/live"
cat > "$ledger" <<JSON
{"ts":500,"event":"open","socket_path":"/s/d","server_pid":6060,"session":"proj","window_id":"@1","window_name":"claude","cwd":"/w/killed","agent":"work"}
{"ts":501,"event":"resume","socket_path":"/s/d","server_pid":6060,"window_id":"@1","label":"kk1","resume_cmd":"claude --resume kk1"}
JSON
printf '@1\n' > "$(_sl_live_file "/s/d" 6060)"        # crash case: @1 was open at death
crash=$(SESSION_LOG_LIVE_PIDS="" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --global)
_assert "crash case: dead server WITH open window is offered" "1" "$(printf '%s\n' "$crash" | grep -c 'kk1')"
sl_discard "/s/d" 6060                                # deliberate kill → empty the sidecar
kild=$(SESSION_LOG_LIVE_PIDS="" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --global)
_assert "kill case: discarded server offers nothing" "0" "$(printf '%s\n' "$kild" | grep -c 'kk1')"

# ============ last-window close: an EMPTY window set must reach the sidecar ============
# tmux cannot report an empty window set: on the server whose LAST window just
# closed, `list-windows -a` FAILS ("no current target") instead of printing
# nothing. _sl_snapshot's failure branch keeps the previous (populated) sidecar,
# so the graceful teardown was indistinguishable from a crash and sl_dropped
# re-offered the tab you had just closed. The discriminator is server liveness:
# reachable + unqueryable = zero windows (write empty); unreachable = a set we
# genuinely cannot observe (keep what we have).
# These tests need the REAL _sl_live_windows path, so drop the SESSION_LOG_LIVE_WINDOWS
# hook first. It is still set: a `VAR=v cmd` prefix persists after the call when `cmd`
# is a SHELL FUNCTION (POSIX), so the last such assignment above is still in scope.
unset SESSION_LOG_LIVE_WINDOWS
# ...and stub tmux so list-windows FAILS the way a real windowless server does
# (the capture stub in effect here answers every call successfully). Left in place:
# the real-tmux block below drops all stubs with `unset -f tmux`.
tmux() { case " $* " in *" list-windows "*) return 1 ;; esac; return 0; }

# alive but windowless → EMPTY sidecar (the last-window close).
rm -rf "$AGENTMUX_STATE_DIR/live"; mkdir -p "$AGENTMUX_STATE_DIR/live"
printf '@1\n' > "$(_sl_live_file "/s/lw" 7070)"
SESSION_LOG_LIVE_PIDS="7070" _sl_snapshot "/s/lw" 7070
_assert "last-window close: sidecar still present" "1" \
  "$([ -f "$(_sl_live_file "/s/lw" 7070)" ] && echo 1 || echo 0)"
_assert "last-window close: sidecar emptied (no window ids)" "0" \
  "$(grep -c . "$(_sl_live_file "/s/lw" 7070)")"

# unreachable server → KEEP the recorded set (a crash we cannot observe; emptying
# here would silently destroy the recovery data this whole feature exists for).
printf '@1\n@2\n' > "$(_sl_live_file "/s/lw" 8080)"
SESSION_LOG_LIVE_PIDS="" _sl_snapshot "/s/lw" 8080
_assert "unreachable server: sidecar left intact" "@1 @2" \
  "$(tr '\n' ' ' < "$(_sl_live_file "/s/lw" 8080)" | sed 's/ *$//')"

# ============ Finding 1: unreachable server during snapshot leaves NO orphan
#     .sock. _sl_snapshot writes the .sock companion BEFORE the liveness
#     query; when the query fails (server genuinely gone, not merely
#     windowless), no .windows sidecar lands — but the .sock is already on
#     disk. sl_prune only ever iterates live/*.windows, so a .sock with no
#     .windows sibling can never match and survives forever. Fresh
#     (socket,pid) pair, no prior sidecar of either kind, so this is
#     non-vacuous: a revert that puts the .sock write back before the
#     liveness query (undoing the success-branch move) leaves the .sock on
#     disk and this fails. ============
rm -rf "$AGENTMUX_STATE_DIR/live"; mkdir -p "$AGENTMUX_STATE_DIR/live"
_lf_orphan=$(_sl_live_file "/s/gone" 9090)
SESSION_LOG_LIVE_PIDS="" _sl_snapshot "/s/gone" 9090
_assert "Finding 1: failed snapshot writes no .windows" "0" \
  "$([ -f "$_lf_orphan" ] && echo 1 || echo 0)"
_assert "Finding 1: failed snapshot leaves no orphan .sock" "0" \
  "$([ -f "$_lf_orphan.sock" ] && echo 1 || echo 0)"

# ============ Task 5 regression: sl_open's [socket] param must reach the REAL
#     tmux server, not silently fall back to the default socket (this is the
#     one test in the file that drives an actual tmux server instead of the
#     stubbed tmux() shell function above — that's what makes it a genuine
#     end-to-end guard). Non-vacuous: if the [socket] threading in sl_open/
#     _sl_ctx were reverted, `sktest` doesn't exist on the (empty) default
#     socket a bare `tmux -t sktest` would fall back to, display-message finds
#     nothing, _pid comes back empty, and sl_open writes NOTHING — the "writes
#     one line" assertion catches that; the socket_path assertion catches a
#     narrower revert that still resolves but against the wrong socket. Needs
#     a real tmux; skip cleanly if absent. Short TMUX_TMPDIR for the AF_UNIX
#     104-char socket-path limit, matching bin/amux's real-tmux selftest
#     blocks. Keep this block LAST — it drops the canned tmux() stub. ============
unset -f tmux 2>/dev/null   # drop the canned stub — this block must hit the real binary
if command -v tmux >/dev/null 2>&1; then
  _sk_dir="/tmp/slsktest-$$"; export TMUX_TMPDIR="$_sk_dir"; mkdir -p "$_sk_dir"
  _sk_sock="agentmux-agent-777"
  # -f /dev/null: a test server must be hermetic. Without it tmux loads the
  # USER's ~/.tmux.conf, which source-files agentmux.conf — pulling the live
  # window-unlinked/after-new-window hooks and the whole tpm plugin set into a
  # server this test is about to kill. Nothing here wants the live config.
  tmux -L "$_sk_sock" -f /dev/null new-session -d -s sktest -c /tmp 2>/dev/null
  _sk_realsock=$(tmux -L "$_sk_sock" display-message -p '#{socket_path}' 2>/dev/null)
  _sk_pid=$(tmux -L "$_sk_sock" display-message -p '#{pid}' 2>/dev/null)
  _sk_wid=$(tmux -L "$_sk_sock" display-message -p -t sktest '#{window_id}' 2>/dev/null)
  rm -f "$ledger"
  sl_open claude sktest "$_sk_sock"
  _assert "sharded socket open: writes one line" "1" \
    "$([ -f "$ledger" ] && wc -l < "$ledger" | tr -d ' ' || echo 0)"
  _assert "sharded socket open: records that socket" "$_sk_realsock" \
    "$(jq -r '.socket_path' "$ledger" 2>/dev/null)"
  _assert "sharded socket open: not the default socket" "0" \
    "$(jq -r '.socket_path' "$ledger" 2>/dev/null | grep -c '/default$')"
  _assert "sharded socket open: records correct pid" "$_sk_pid" \
    "$(jq -r '.server_pid' "$ledger" 2>/dev/null)"
  _assert "sharded socket open: records correct window" "$_sk_wid" \
    "$(jq -r '.window_id' "$ledger" 2>/dev/null)"
  tmux -L "$_sk_sock" kill-server 2>/dev/null

  # --- END-TO-END last-window close (the false-crash regression). Drives a real
  #     server with the SAME `window-unlinked` hook agentmux.conf installs, so it
  #     exercises the whole chain: close a window → hook → snapshot subcommand →
  #     sidecar. Closing a NON-last window must leave the survivors; closing the
  #     LAST one tears the server down, and the sidecar must end up EMPTY (=
  #     "nothing was open at death") rather than keeping the window just closed.
  #     Stubs can't cover this: the bug IS real tmux's inability to report an
  #     empty window set, which no stub would reproduce on its own. ---
  #     The hook's child inherits the tmux SERVER's environment, which is this
  #     shell's — so every SESSION_LOG_* test hook must be cleared first or the
  #     child answers from canned values instead of the real server. They ARE
  #     still set: a `VAR=v cmd` prefix persists when `cmd` is a shell function
  #     (POSIX), and a leaked SESSION_LOG_LIVE_PIDS="" in particular makes the
  #     child read every server as dead — silently defeating this test.
  unset SESSION_LOG_LIVE_PIDS SESSION_LOG_LIVE_WINDOWS SESSION_LOG_BOOT_EPOCH
  unset SESSION_LOG_RESUME_MAP SESSION_LOG_CTX
  _lw_sock="agentmux-agent-778"
  _lw_script=$(cd "$(dirname "$0")" 2>/dev/null && pwd)/$(basename "$0")
  if [ -f "$_lw_script" ]; then
    tmux -L "$_lw_sock" -f /dev/null new-session -d -s lwtest -c /tmp 2>/dev/null
    # Hermetic server (-f /dev/null above), so this installs the hook explicitly
    # rather than inheriting agentmux.conf's — same hook, under test control.
    # The child runs the DISPATCHER, not this selftest, because the marker was
    # unset at the top of the selftest; don't re-guard it here.
    tmux -L "$_lw_sock" set-hook -g window-unlinked \
      "run-shell \"sh '$_lw_script' snapshot #{socket_path} #{pid}\"" 2>/dev/null
    tmux -L "$_lw_sock" new-window -t lwtest -c /tmp 2>/dev/null
    _lw_rs=$(tmux -L "$_lw_sock" display-message -p '#{socket_path}' 2>/dev/null)
    _lw_pid=$(tmux -L "$_lw_sock" display-message -p '#{pid}' 2>/dev/null)
    _lw_file=$(_sl_live_file "$_lw_rs" "$_lw_pid")
    rm -rf "$AGENTMUX_STATE_DIR/live"
    _sl_snapshot "$_lw_rs" "$_lw_pid"          # seed: both windows open
    _assert "e2e: seeded sidecar has both windows" "2" "$(grep -c . "$_lw_file" 2>/dev/null)"

    # Condition-based waits (no fixed sleeps): the hook's run-shell is async.
    # `grep -c .` EXITS 1 on a zero count, so it must not gate the comparison —
    # a `|| echo x` fallback would corrupt the very count (0) we wait for.
    _lw_count() { grep -c . "$_lw_file" 2>/dev/null; :; }
    _lw_wait() {  # <expected-line-count>
      _i=0
      while [ "$_i" -lt 60 ]; do
        [ "$(_lw_count)" = "$1" ] && return 0
        _i=$((_i+1)); sleep 0.05
      done
      return 1
    }
    tmux -L "$_lw_sock" kill-window -t lwtest:1 2>/dev/null   # non-last close
    _lw_wait 1
    _assert "e2e: non-last close leaves the survivor" "1" "$(grep -c . "$_lw_file" 2>/dev/null)"

    tmux -L "$_lw_sock" kill-window -t lwtest:0 2>/dev/null   # LAST close → server dies
    _lw_wait 0
    _assert "e2e: last-window close leaves the sidecar present" "1" \
      "$([ -f "$_lw_file" ] && echo 1 || echo 0)"
    _assert "e2e: last-window close EMPTIES the sidecar (no false crash)" "0" \
      "$(grep -c . "$_lw_file" 2>/dev/null)"
    tmux -L "$_lw_sock" kill-server 2>/dev/null
  else
    echo "SKIP: last-window-close end-to-end test (cannot resolve \$0)"
  fi

  rm -rf "$_sk_dir"; unset TMUX_TMPDIR
else
  echo "SKIP: sharded-socket open recording test (tmux not found)"
fi

# ============ Task 3: the sidecar carries cwd/agent/resumable, plus the socket
#     companion file. Placed AFTER `unset -f tmux` above, so every bare `tmux`
#     call below — both this block's own and the one INSIDE _sl_live_windows —
#     hits the real binary, not the canned stub. That's what makes this
#     non-vacuous: reverting the -F format string in _sl_live_windows back to
#     '#{window_id}' makes the real tmux server emit a bare id with no tabs,
#     so "sidecar has 4 fields" drops to 1 and fails. Defensive unsets: a
#     prefix assignment persists past a shell-function call in this repo's sh
#     (see the comments on SESSION_LOG_CTX above), so clear the hooks this
#     block must NOT be driven by. Short literal /tmp dir (not `mktemp -d`),
#     matching the sharded-socket block above: a macOS mktemp path can exceed
#     the 104-char AF_UNIX socket-path limit. ============
unset SESSION_LOG_LIVE_WINDOWS SESSION_LOG_LIVE_PIDS SESSION_LOG_CTX 2>/dev/null
_t3_dir="/tmp/slt3-$$"; mkdir -p "$_t3_dir"
_t3_sock="agentmux-t3-$$"
if command -v tmux >/dev/null 2>&1; then
  TMUX_TMPDIR="$_t3_dir" command tmux -L "$_t3_sock" -f /dev/null new-session -d -s t3 -c /tmp 2>/dev/null
  _t3_wid=$(TMUX_TMPDIR="$_t3_dir" command tmux -L "$_t3_sock" display-message -p -t t3 '#{window_id}' 2>/dev/null)
  TMUX_TMPDIR="$_t3_dir" command tmux -L "$_t3_sock" set-option -w -t "$_t3_wid" @amux_cwd   /w/three 2>/dev/null
  TMUX_TMPDIR="$_t3_dir" command tmux -L "$_t3_sock" set-option -w -t "$_t3_wid" @amux_agent work     2>/dev/null
  TMUX_TMPDIR="$_t3_dir" command tmux -L "$_t3_sock" set-option -w -t "$_t3_wid" @amux_resumable 1    2>/dev/null
  _t3_real=$(TMUX_TMPDIR="$_t3_dir" command tmux -L "$_t3_sock" display-message -p '#{socket_path}' 2>/dev/null)
  _t3_pid=$(TMUX_TMPDIR="$_t3_dir" command tmux -L "$_t3_sock" display-message -p '#{pid}' 2>/dev/null)
  _ignore=$(_sl_snapshot "$_t3_real" "$_t3_pid")
  _t3_line=$(cat "$(_sl_live_file "$_t3_real" "$_t3_pid")" 2>/dev/null)
  _assert "t3: sidecar has 4 fields" "4" "$(printf '%s' "$_t3_line" | awk -F"$TAB" '{print NF}')"
  _assert "t3: sidecar carries cwd"  "/w/three" "$(printf '%s' "$_t3_line" | cut -f2)"
  _assert "t3: sidecar carries agent" "work"    "$(printf '%s' "$_t3_line" | cut -f3)"
  _assert "t3: sidecar carries resumable" "1"   "$(printf '%s' "$_t3_line" | cut -f4)"
  _assert "t3: writes the socket companion" "$_t3_real" \
    "$(cat "$(_sl_live_file "$_t3_real" "$_t3_pid").sock" 2>/dev/null)"
  TMUX_TMPDIR="$_t3_dir" command tmux -L "$_t3_sock" kill-server 2>/dev/null
else
  echo "SKIP: t3 (tmux not found)"
fi
rm -rf "$_t3_dir"

# ============ Task 4: --pending is answered from the live/ sidecars, not the
#     ledger. This is warden's hot path (one poll per session-less tab, every
#     few seconds), so the answer must cost a directory scan, not a jq fold.
#
#     The exit code carries THREE states: 0 = yes, 1 = no, 2 = CANNOT ANSWER.
#     2 must never collapse to 1 — answering "no" on missing information
#     silently stops ghosting recoverable sessions, the exact loss this whole
#     subsystem exists to prevent — so every no-information fixture below pins
#     2, and every genuine-negative fixture pins 1. Conflating the two is the
#     one bug in here that fails silently, which is why they are tested apart.
#
#     Placed AFTER the `unset -f tmux` above so _sl_server_live runs the REAL
#     tmux probe: a socket path that does not exist reads DEAD, which is what
#     every fixture here needs. Under the canned stub these would read dead
#     too — but for the wrong reason (it answers every call successfully), and
#     a test that passes without the liveness call having happened is exactly
#     the kind that hides a broken wiring. ============
_t4_dir=$(mktemp -d) || exit 1
_t4_put() {  # <socket> <pid> <sidecar line>  → sidecar + its .sock companion
  _t4_f="$_t4_dir/live/$(printf '%s' "$1" | cksum | cut -d' ' -f1)-$2.windows"
  printf '%s\n' "$3" > "$_t4_f"; printf '%s\n' "$1" > "$_t4_f.sock"
}
_t4_rm() {  # <socket> <pid>
  _t4_f="$_t4_dir/live/$(printf '%s' "$1" | cksum | cut -d' ' -f1)-$2.windows"
  rm -f "$_t4_f" "$_t4_f.sock"
}
# Run in $() so the AGENTMUX_STATE_DIR prefix stays in the subshell: a prefix
# assignment on a SHELL FUNCTION call persists in POSIX sh (see the
# SESSION_LOG_CTX comments above), and leaking it here would redirect the rest
# of the suite — and the EXIT trap's rm -rf — at this fixture.
_t4_fast() {  # <cwd> → prints the exit code
  _ignore=$(AGENTMUX_STATE_DIR="$_t4_dir" _sl_pending_fast "$1"); printf '%s' "$?"
}

# NO INFORMATION: a missing or empty live/ dir is not "no drops", it is "I cannot see".
_assert "t4: no live dir cannot answer"    "2" "$(_t4_fast /w/four)"
mkdir -p "$_t4_dir/live"
_assert "t4: empty live dir cannot answer" "2" "$(_t4_fast /w/four)"

# pid 999999+ is above the default pid_max, so no real tmux server can own it.
_t4_put /s/four 999999 "@1${TAB}/w/four${TAB}work${TAB}1"
_assert "t4: finds the restorable drop"    "0" "$(_t4_fast /w/four)"
_assert "t4: other cwd is not a hit"       "1" "$(_t4_fast /w/other)"

# The two rows that must never ghost: the shell agent has nothing to resume, and
# an agent window that never emitted a resume hint has no command to restore it.
_t4_put /s/sh   999998 "@1${TAB}/w/sh${TAB}shell${TAB}1"
_assert "t4: shell agent never ghosts"     "1" "$(_t4_fast /w/sh)"
_t4_put /s/norc 999997 "@1${TAB}/w/norc${TAB}work${TAB}"
_assert "t4: no resume hint is not a hit"  "1" "$(_t4_fast /w/norc)"

# An EMPTY sidecar is a REAL answer — nothing was open when that server died (a
# clean teardown, i.e. you closed the last window). It yields no drop, and must
# not be mistaken for the no-information case above.
: > "$_t4_dir/live/$(printf '%s' /s/empty | cksum | cut -d' ' -f1)-999994.windows"
_assert "t4: empty sidecar is a teardown, not a ghost" "1" "$(_t4_fast /w/empty)"

# The once-per-(server,cwd) offer gate, applied READ-ONLY. The ledger path skips a
# server already offered for this cwd; the fast path must skip the same ones on the
# same key, or the ghost that amux has already cleared lights up again.
printf '%s\n' "/s/four|999999|/w/four" > "$_t4_dir/notified"
_assert "t4: honours the notified gate"    "1" "$(_t4_fast /w/four)"
printf '%s\n' "/s/four|999999|/w/elsewhere" > "$_t4_dir/notified"
_assert "t4: gate is per-cwd, not per-server" "0" "$(_t4_fast /w/four)"
rm -f "$_t4_dir/notified"

# The remaining no-information shapes, both SCOPED to the queried cwd (t6 owns the
# scoping pairs; these two pin the shapes themselves against this fixture, which
# has no ledger at all). A legacy (single-field) sidecar predates the enriched
# format, so its window's cwd is unknown — but with no ledger row tying that server
# to /w/four, nothing it could hide is anything the ledger path could have offered,
# so it must not suppress the answer. A .windows with no .sock companion (what
# _sl_discard writes) leaves no way to run the liveness probe, and this one DOES
# name /w/four, so it is 2 — defer to the ledger — never a guessed 1.
_t4_put /s/legacy 999996 "@1"
_assert "t4: unplaceable legacy sidecar does not suppress" "0" "$(_t4_fast /w/four)"
_t4_rm  /s/legacy 999996
_t4_put /s/nosock 999995 "@1${TAB}/w/four${TAB}work${TAB}1"
rm -f "$_t4_dir/live/$(printf '%s' /s/nosock | cksum | cut -d' ' -f1)-999995.windows.sock"
_assert "t4: missing .sock defers to ledger"  "2" "$(_t4_fast /w/four)"
_t4_rm  /s/nosock 999995
_assert "t4: recovers once the unanswerable sidecars are gone" "0" "$(_t4_fast /w/four)"
rm -rf "$_t4_dir"

# ============ Task 4b: the fast and the ledger path must AGREE. Two code paths
#     answering one question is exactly the shadow that rots, so pin both against
#     ONE fixture. Driven through sl_dropped rather than _sl_pending_fast, because
#     a helper tested only in isolation hides call-site bugs (argument order, the
#     escape hatch, the boolean the caller actually reads). ============
_t4b_dir=$(mktemp -d) || exit 1
mkdir -p "$_t4b_dir/live"
cat > "$_t4b_dir/sessions.jsonl" <<JSON
{"ts":100,"event":"open","socket_path":"/s/here","server_pid":111,"session":"h","window_id":"@1","window_name":"claude","cwd":"/w/here","agent":"work"}
{"ts":101,"event":"resume","socket_path":"/s/here","server_pid":111,"window_id":"@1","label":"drophere","resume_cmd":"claude --resume drophere"}
JSON
_t4b_f="$_t4b_dir/live/$(printf '%s' /s/here | cksum | cut -d' ' -f1)-111.windows"
printf '@1\t/w/here\twork\t1\n' > "$_t4b_f"; printf '/s/here\n' > "$_t4b_f.sock"
_t4b_run() {  # <cwd> [extra env assignments applied by the caller]
  AGENTMUX_STATE_DIR="$_t4b_dir" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" \
    sl_dropped --pending "$1"
}
_assert "t4b: fast path sees the drop"  "1" "$(_t4b_run /w/here | grep -c .)"
_assert "t4b: fast path misses nothing" "0" "$(_t4b_run /w/nowhere | grep -c .)"
# The discriminator that makes the pair above non-vacuous: --pending's fast answer
# is a synthetic boolean row, so the ledger's program-swapped resume text is ABSENT
# from it. Without this the two assertions pass identically whether the fast path
# ran or fell through, and the agreement guard would prove nothing.
_assert "t4b: fast answer is synthetic, not a ledger row" "0" \
  "$(_t4b_run /w/here | grep -c 'claude-work --resume drophere')"
# Same question, ledger path. AMUX_PENDING_NO_FAST is the escape hatch that makes
# the two independently observable; without it there is no way to prove agreement.
_t4b_slow=$(AMUX_PENDING_NO_FAST=1 AGENTMUX_STATE_DIR="$_t4b_dir" SESSION_LOG_BOOT_EPOCH=1 \
  SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending "/w/here")
_t4b_slowmiss=$(AMUX_PENDING_NO_FAST=1 AGENTMUX_STATE_DIR="$_t4b_dir" SESSION_LOG_BOOT_EPOCH=1 \
  SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending "/w/nowhere")
_assert "t4b: ledger path agrees (drop)"    "1" "$(printf '%s\n' "$_t4b_slow" | grep -c .)"
_assert "t4b: ledger path agrees (no drop)" "0" "$(printf '%s' "$_t4b_slowmiss" | grep -c .)"
# The ledger fallback keeps emitting the full program-swapped row — --pending's
# consumer only tests emptiness, but the fallback shares its emitter with --new,
# and that emitter is what keeps the restore picker honest.
_assert "t4b: ledger fallback still swaps the resume program" "1" \
  "$(printf '%s\n' "$_t4b_slow" | grep -c 'claude-work --resume drophere')"
rm -rf "$_t4b_dir"

# ============ Task 4c: the LIVE-server gate. `dropped` means one thing — a
#     restorable drop exists only on a DEAD server — and in the fast path the
#     whole of that semantic is the single `_sl_server_live … && continue`. Every
#     other fixture in this file points at an unreachable socket, so all of them
#     pass whether that call runs or not (verified: mutating it to `:` left all
#     153 assertions green). Then a project whose agent is RUNNING shows a
#     permanent restorable ghost dot.
#
#     So this fixture is a REAL, LIVE tmux server: the sidecar's .sock companion
#     holds its actual #{socket_path} and the filename its actual #{pid}, which is
#     what makes _sl_server_live read it LIVE. Stubbing any of that would prove
#     nothing — hence the real binary (this block sits below `unset -f tmux`, and
#     uses `command tmux` for its own calls regardless) and the isolated
#     TMUX_TMPDIR + `-f /dev/null` hermetic server, killed before the block ends.
#
#     Non-vacuous in BOTH directions: mutate the gate away and "live server yields
#     no drop" fails; and the SAME fixture, once the server is killed, must start
#     reporting the drop — which is what proves the 1 came from liveness and not
#     from some unrelated defect in the fixture. ============
unset SESSION_LOG_LIVE_PIDS SESSION_LOG_LIVE_WINDOWS 2>/dev/null
if command -v tmux >/dev/null 2>&1; then
  _t4c_dir=$(mktemp -d) || exit 1
  # Short literal dir (not the mktemp one): a macOS temp path can exceed the
  # 104-char AF_UNIX socket-path limit, same as the t3/sharded-socket blocks.
  _t4c_tm="/tmp/slt4c-$$"; mkdir -p "$_t4c_tm" "$_t4c_dir/live"
  _t4c_sock="agentmux-t4c-$$"
  TMUX_TMPDIR="$_t4c_tm" command tmux -L "$_t4c_sock" -f /dev/null new-session -d -s t4c -c /tmp 2>/dev/null
  _t4c_real=$(TMUX_TMPDIR="$_t4c_tm" command tmux -L "$_t4c_sock" display-message -p '#{socket_path}' 2>/dev/null)
  _t4c_pid=$(TMUX_TMPDIR="$_t4c_tm" command tmux -L "$_t4c_sock" display-message -p '#{pid}' 2>/dev/null)
  _t4c_wid=$(TMUX_TMPDIR="$_t4c_tm" command tmux -L "$_t4c_sock" display-message -p -t t4c '#{window_id}' 2>/dev/null)
  if [ -n "$_t4c_real" ] && [ -n "$_t4c_pid" ]; then
    _t4c_f="$_t4c_dir/live/$(printf '%s' "$_t4c_real" | cksum | cut -d' ' -f1)-$_t4c_pid.windows"
    printf '%s\t/w/live\twork\t1\n' "$_t4c_wid" > "$_t4c_f"
    printf '%s\n' "$_t4c_real" > "$_t4c_f.sock"
    # A ledger naming the same server, so the ledger path has the same row to judge
    # and the two can be compared. Real timestamps: the ledger path also gates on
    # maxts >= boot epoch, and SESSION_LOG_BOOT_EPOCH=1 keeps that side out of the way.
    _t4c_now=$(date +%s)
    cat > "$_t4c_dir/sessions.jsonl" <<JSON
{"ts":$_t4c_now,"event":"open","socket_path":"$_t4c_real","server_pid":$_t4c_pid,"session":"t4c","window_id":"$_t4c_wid","window_name":"claude","cwd":"/w/live","agent":"work"}
{"ts":$_t4c_now,"event":"resume","socket_path":"$_t4c_real","server_pid":$_t4c_pid,"window_id":"$_t4c_wid","label":"droplive","resume_cmd":"claude --resume droplive"}
JSON
    _t4c_fast() {  # <cwd> → prints the exit code (see _t4_fast on the $() wrapper)
      _ignore=$(AGENTMUX_STATE_DIR="$_t4c_dir" _sl_pending_fast "$1"); printf '%s' "$?"
    }
    _assert "t4c: LIVE server yields no restorable drop" "1" "$(_t4c_fast /w/live)"
    _t4c_p=$(AGENTMUX_STATE_DIR="$_t4c_dir" SESSION_LOG_BOOT_EPOCH=1 \
      SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending /w/live)
    _assert "t4c: --pending emits nothing for a live server" "0" "$(printf '%s' "$_t4c_p" | grep -c .)"
    _t4c_s=$(AMUX_PENDING_NO_FAST=1 AGENTMUX_STATE_DIR="$_t4c_dir" SESSION_LOG_BOOT_EPOCH=1 \
      SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending /w/live)
    _assert "t4c: ledger path agrees (live server, no drop)" "0" "$(printf '%s' "$_t4c_s" | grep -c .)"

    # Kill it and re-ask. Same sidecar, same ledger, same cwd — only liveness changed.
    TMUX_TMPDIR="$_t4c_tm" command tmux -L "$_t4c_sock" kill-server 2>/dev/null
    _t4c_i=0
    while [ "$_t4c_i" -lt 60 ] && command tmux -S "$_t4c_real" display-message -p '#{pid}' >/dev/null 2>&1; do
      _t4c_i=$((_t4c_i + 1)); sleep 0.05
    done
    _assert "t4c: the same fixture DOES ghost once that server is dead" "0" "$(_t4c_fast /w/live)"
  else
    echo "SKIP: t4c (could not start a test tmux server)"
  fi
  TMUX_TMPDIR="$_t4c_tm" command tmux -L "$_t4c_sock" kill-server 2>/dev/null
  rm -rf "$_t4c_dir" "$_t4c_tm"
else
  echo "SKIP: t4c live-server gate (tmux not found)"
fi

# ============ Task 4d: a DEAD server the ledger names but that has NO sidecar is
#     the one state the sidecar scan used to answer WRONG rather than defer. The
#     ledger path reads it as "all its windows were open at death" (sl_dropped's
#     '*' branch) and offers the drops; live/ cannot see such a server at all, so
#     a scan of live/ alone concluded "no drop". It triggers exactly on a crash at
#     launch — sl_open appends the ledger row, then _sl_snapshot's liveness query
#     fails because the server has already gone — i.e. the scenario recovery is
#     for. Fixture is that state precisely: a normal enriched sidecar for an
#     unrelated server (so the scan is not short-circuited by "no sidecars" or by
#     a legacy shape) plus a ledger naming a second, sidecar-less one. Non-vacuous:
#     without the ledger join in _sl_pending_fast this asserts 1, not 2. ============
_t4d_dir=$(mktemp -d) || exit 1
mkdir -p "$_t4d_dir/live"
_t4d_f="$_t4d_dir/live/$(printf '%s' /s/other | cksum | cut -d' ' -f1)-999993.windows"
printf '@1\t/w/other\twork\t1\n' > "$_t4d_f"; printf '/s/other\n' > "$_t4d_f.sock"
cat > "$_t4d_dir/sessions.jsonl" <<JSON
{"ts":100,"event":"open","socket_path":"/s/crash","server_pid":999992,"session":"c","window_id":"@1","window_name":"claude","cwd":"/w/crash","agent":"work"}
{"ts":101,"event":"resume","socket_path":"/s/crash","server_pid":999992,"window_id":"@1","label":"dropcrash","resume_cmd":"claude --resume dropcrash"}
JSON
_t4d_fast() {  # <cwd> → prints the exit code
  _ignore=$(AGENTMUX_STATE_DIR="$_t4d_dir" _sl_pending_fast "$1"); printf '%s' "$?"
}
_assert "t4d: ledger server with no sidecar defers to the ledger" "2" "$(_t4d_fast /w/crash)"
# ...and the deferral is worth making: the ledger path really does find that drop,
# so the old 1 was a silently-lost ghost, not a harmless one.
_t4d_out=$(AGENTMUX_STATE_DIR="$_t4d_dir" SESSION_LOG_BOOT_EPOCH=1 \
  SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending /w/crash)
_assert "t4d: the deferred-to ledger path DOES report that drop" "1" \
  "$(printf '%s\n' "$_t4d_out" | grep -c .)"
# The join is scoped to the QUERIED cwd — a sidecar-less server in some other
# project must not turn every poll on the machine into a ledger fold.
_assert "t4d: an unaffected cwd still answers from the sidecars" "0" "$(_t4d_fast /w/other)"
# A server the ledger names WITH a sidecar is not a deferral, only a missing one is.
_assert "t4d: no deferral for a cwd the ledger never names" "1" "$(_t4d_fast /w/absent)"
rm -rf "$_t4d_dir"

# ============ Task 4e: an UNSTAMPED window is a legacy line wearing the current
#     shape. `_sl_live_windows` formats every window with the full four-field -F
#     string, so a window whose @amux_* options were never stamped still snapshots
#     as `@N<TAB><TAB><TAB>` — four fields, cwd EMPTY. A field-count-only classifier
#     reads that as current, the `$2 == c` test then fails, and the query resolves
#     to "definitely not this cwd": a silent 1 where the ledger offers a restore,
#     and the dot never lights. Not a corner — the three stamps are best-effort
#     (`2>/dev/null || true`) and any window open before they shipped re-snapshots
#     this way (three such lines were on the real machine when this was found).
#
#     Asserted as the same PAIR t6 uses, because that is what makes each half
#     non-vacuous: the line must NOT suppress a cwd the ledger places elsewhere,
#     and MUST defer for the cwd the ledger places it in. Mutation-proof in the
#     direction that matters — restore the bare `NF < 4` and the second assert
#     drops to 1, the exact data loss. ============
_t4e_dir=$(mktemp -d) || exit 1
mkdir -p "$_t4e_dir/live"
_t4e_f="$_t4e_dir/live/$(printf '%s' /s/unst | cksum | cut -d' ' -f1)-999991.windows"
# The live shape, verbatim: id present, cwd/agent empty, the resumable stamp landed.
printf '@2\t\t\t1\n' > "$_t4e_f"; printf '/s/unst\n' > "$_t4e_f.sock"
_t4e_seed() {  # <cwd the ledger places @2 in>
  cat > "$_t4e_dir/sessions.jsonl" <<JSON
{"ts":100,"event":"open","socket_path":"/s/unst","server_pid":999991,"session":"u","window_id":"@2","window_name":"claude","cwd":"$1","agent":"work"}
{"ts":101,"event":"resume","socket_path":"/s/unst","server_pid":999991,"window_id":"@2","label":"dropunst","resume_cmd":"claude --resume dropunst"}
{"ts":102,"event":"open","socket_path":"/s/ok","server_pid":999990,"session":"o","window_id":"@1","window_name":"claude","cwd":"/w/ok","agent":"work"}
{"ts":103,"event":"resume","socket_path":"/s/ok","server_pid":999990,"window_id":"@1","label":"dropok","resume_cmd":"claude --resume dropok"}
JSON
}
# A second, fully-stamped dead server, so the queried cwd has a real answer to lose.
_t4e_ok="$_t4e_dir/live/$(printf '%s' /s/ok | cksum | cut -d' ' -f1)-999990.windows"
printf '@1\t/w/ok\twork\t1\n' > "$_t4e_ok"; printf '/s/ok\n' > "$_t4e_ok.sock"
_t4e_fast() {  # <cwd> → prints the exit code (see _t4_fast on the $() wrapper)
  _ignore=$(AGENTMUX_STATE_DIR="$_t4e_dir" _sl_pending_fast "$1"); printf '%s' "$?"
}
_t4e_seed /w/away
_assert "t4e: unstamped line the ledger puts in ANOTHER cwd does not suppress" \
  "0" "$(_t4e_fast /w/ok)"
# Same fixture, one field changed: the ledger now places that window in /w/lost,
# where NOTHING else can answer. The unstamped line is the only information about
# that cwd, and it hides its own — so this must defer, never resolve. THIS is the
# assertion that pins the data loss: read as current, its empty cwd fails `$2 == c`,
# no other row is a candidate, and the query returns a confident 1.
_t4e_seed /w/lost
_assert "t4e: unstamped line the ledger puts in THIS cwd defers" "2" "$(_t4e_fast /w/lost)"
# ...and the deferral is worth making: the ledger path really does report a drop
# there, so the old 1 was a silently-lost ghost and the dot never lit.
_t4e_out=$(AGENTMUX_STATE_DIR="$_t4e_dir" SESSION_LOG_BOOT_EPOCH=1 \
  SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending /w/lost)
_assert "t4e: the deferred-to ledger path DOES report that drop" "1" \
  "$(printf '%s\n' "$_t4e_out" | grep -c .)"
# The scoping still holds: a fully-stamped cwd is answered from the sidecars, not
# dragged into the deferral by the unresolvable line beside it.
_assert "t4e: an unaffected cwd still answers from the sidecars" "0" "$(_t4e_fast /w/ok)"
rm -rf "$_t4e_dir"

# ============ Task 4f: the BOOT-EPOCH half of the deadness test. `_sl_server_live`
#     alone cannot see a reboot: a new tmux server handed the same pid on the same
#     socket answers the probe as if it were the dead one. The ledger path pairs
#     liveness with `smax >= boot`; the fast path pairs it with the sidecar's mtime,
#     which records the same fact (the sidecar is rewritten on every open and every
#     window-unlinked close). Older than boot → defer, never `continue` — the
#     omission read such a server as live and skipped it, a collapse to 1 in the
#     unsafe direction.
#
#     SESSION_LOG_LIVE_PIDS makes the server read LIVE without a real one; the
#     sidecar's mtime is set with a REAL `touch -t`, so `_sl_mtime`'s own
#     GNU-vs-BSD flavour detection is under test rather than stubbed. Non-vacuous
#     as a pair: with the boot epoch BELOW the sidecar's mtime nothing is stale and
#     both paths say "no drop"; above it, both say "drop". ============
_t4f_dir=$(mktemp -d) || exit 1
mkdir -p "$_t4f_dir/live"
_t4f_f="$_t4f_dir/live/$(printf '%s' /s/reb | cksum | cut -d' ' -f1)-999899.windows"
printf '@1\t/w/reb\twork\t1\n' > "$_t4f_f"; printf '/s/reb\n' > "$_t4f_f.sock"
cat > "$_t4f_dir/sessions.jsonl" <<JSON
{"ts":100,"event":"open","socket_path":"/s/reb","server_pid":999899,"session":"r","window_id":"@1","window_name":"claude","cwd":"/w/reb","agent":"work"}
{"ts":101,"event":"resume","socket_path":"/s/reb","server_pid":999899,"window_id":"@1","label":"dropreb","resume_cmd":"claude --resume dropreb"}
JSON
touch -t 200001010000 "$_t4f_f"      # mtime 2000-01-01 ≈ 946684800
_t4f_fast() {  # <boot epoch> → prints the exit code (see _t4_fast on the $() wrapper)
  _ignore=$(AGENTMUX_STATE_DIR="$_t4f_dir" SESSION_LOG_LIVE_PIDS="999899" \
    SESSION_LOG_BOOT_EPOCH="$1" _sl_pending_fast /w/reb); printf '%s' "$?"
}
_t4f_pend() {  # <boot epoch> → the --pending row count, fast path in play
  AGENTMUX_STATE_DIR="$_t4f_dir" SESSION_LOG_LIVE_PIDS="999899" \
    SESSION_LOG_BOOT_EPOCH="$1" SESSION_LOG_RESUME_MAP="$RMAP" \
    sl_dropped --pending /w/reb | grep -c .
}
_t4f_slow() {  # <boot epoch> → the row count with the fast path forced off
  AMUX_PENDING_NO_FAST=1 AGENTMUX_STATE_DIR="$_t4f_dir" SESSION_LOG_LIVE_PIDS="999899" \
    SESSION_LOG_BOOT_EPOCH="$1" SESSION_LOG_RESUME_MAP="$RMAP" \
    sl_dropped --pending /w/reb | grep -c .
}
# Boot BEFORE the sidecar was written: the live server really is ours, no drop.
_assert "t4f: live server, sidecar newer than boot → no drop" "1" "$(_t4f_fast 1)"
_assert "t4f: ...and the ledger path agrees"                  "0" "$(_t4f_slow 1)"
_assert "t4f: ...and --pending emits nothing"                 "0" "$(_t4f_pend 1)"
# Boot AFTER it: the recorded set predates this boot, so the live pid is a reuse.
_assert "t4f: live server, sidecar older than boot → defer"   "2" "$(_t4f_fast 1000000000)"
_assert "t4f: the deferred-to ledger path reports the drop"   "1" "$(_t4f_slow 1000000000)"
_assert "t4f: --pending therefore ghosts it"                  "1" "$(_t4f_pend 1000000000)"
rm -rf "$_t4f_dir"

# ============ Task 6: every unanswerable shape is SCOPED TO THE QUERIED cwd.
#     A state dir is the residue of every project on the machine, so an
#     unresolvable sidecar is guaranteed, not rare — and a bail-on-sight makes the
#     fast path answer for NO cwd at all. Measured on the real dir: 11 legacy lines
#     across 6 sidecars, every one of them a window on some other project's
#     long-dead server, deferred all 47 cwds; scoped, 23 of them answer.
#
#     Each shape is asserted as a PAIR — the unrelated state must NOT suppress an
#     answerable cwd, and the SAME state made to concern that cwd MUST still
#     return 2. The pairs are what make each other non-vacuous: delete the scoping
#     and every first half fails; over-scope it into "absence means irrelevance"
#     and every second half fails, which is the direction that loses data. ============
_t6_dir=$(mktemp -d) || exit 1
mkdir -p "$_t6_dir/live"
_t6_f() {  # <socket> <pid> → the sidecar path
  printf '%s/live/%s-%s.windows' "$_t6_dir" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)" "$2"
}
_t6_put() {  # <socket> <pid> <line…>  → sidecar (lines separated by the literal \n printf expands) + .sock
  _t6_p=$(_t6_f "$1" "$2"); printf "$3\n" > "$_t6_p"; printf '%s\n' "$1" > "$_t6_p.sock"
}
_t6_fast() {  # <cwd> → prints the exit code (see _t4_fast on the $() wrapper)
  _ignore=$(AGENTMUX_STATE_DIR="$_t6_dir" _sl_pending_fast "$1"); printf '%s' "$?"
}
# The answerable baseline every assertion below is measured against: one dead
# server (pid 999889 is above the default pid_max) with a restorable /w/six drop.
# Rewritten by _t6_base so each case starts from the same known-good state.
_t6_base() {  # [extra ledger lines on stdin]
  rm -rf "$_t6_dir/live" "$_t6_dir/dead"; mkdir -p "$_t6_dir/live"
  _t6_put /s/six 999889 "@1${TAB}/w/six${TAB}work${TAB}1"
  cat > "$_t6_dir/sessions.jsonl" <<JSON
{"ts":100,"event":"open","socket_path":"/s/six","server_pid":999889,"session":"s","window_id":"@1","window_name":"claude","cwd":"/w/six","agent":"work"}
{"ts":101,"event":"resume","socket_path":"/s/six","server_pid":999889,"window_id":"@1","label":"dropsix","resume_cmd":"claude --resume dropsix"}
JSON
  cat >> "$_t6_dir/sessions.jsonl"
}
_t6_base </dev/null
_assert "t6: baseline answers from the sidecars" "0" "$(_t6_fast /w/six)"

# --- shape 1: a LEGACY line (bare window id, cwd unknown). The sidecar cannot say
# whose it is; the ledger can, keyed on (socket_path, server_pid, window_id).
_t6_base <<JSON
{"ts":102,"event":"open","socket_path":"/s/leg","server_pid":999888,"session":"l","window_id":"@9","window_name":"claude","cwd":"/w/away","agent":"work"}
JSON
_t6_put /s/leg 999888 "@9"
_assert "t6: legacy line the ledger puts in ANOTHER cwd does not suppress" "0" "$(_t6_fast /w/six)"
# Same fixture, one field changed: the ledger now puts that window in /w/six, so
# its unknown agent/resume could be a drop. This is the half that must never
# collapse to 1.
_t6_base <<JSON
{"ts":102,"event":"open","socket_path":"/s/leg","server_pid":999888,"session":"l","window_id":"@9","window_name":"claude","cwd":"/w/six","agent":"work"}
JSON
_t6_put /s/leg 999888 "@9"
_assert "t6: legacy line the ledger puts in THIS cwd still defers" "2" "$(_t6_fast /w/six)"
# The ambiguous window: a reused window id opened in two cwds. The ledger fold
# keeps only the LAST open, so a purely mechanical read would place @9 in /w/away
# and ignore it — but "which open is last" is a jq fold this raw scan does not do,
# so a window seen in this cwd AT ALL reads as this cwd. This is the one fixture
# where that precedence is load-bearing: /s/other is not tied to /w/six by any
# other row, so nothing else here would catch @9.
_t6_base <<JSON
{"ts":102,"event":"open","socket_path":"/s/other","server_pid":999883,"session":"o","window_id":"@9","window_name":"claude","cwd":"/w/six","agent":"work"}
{"ts":103,"event":"open","socket_path":"/s/other","server_pid":999883,"session":"o","window_id":"@9","window_name":"claude","cwd":"/w/away","agent":"work"}
JSON
_t6_put /s/other 999883 "@9"
_assert "t6: a legacy window seen in this cwd at all defers" "2" "$(_t6_fast /w/six)"
# A legacy window the ledger holds NO ROW FOR is INERT, on any server. A sidecar
# line only GATES ledger rows (it is the was-open-at-death set the fold intersects
# with) and never contributes one, so a window with no row is a set member nothing
# can be emitted for — its unknown cwd cannot change the answer even on a server
# the ledger DOES tie to /w/six. Both halves must answer 0; the pair is here
# because a bail keyed on the server rather than the window fails the second.
_t6_base </dev/null
_t6_put /s/leg 999888 "@9"
_assert "t6: unnamed legacy window on an unrelated server does not suppress" "0" "$(_t6_fast /w/six)"
_t6_base <<JSON
{"ts":102,"event":"open","socket_path":"/s/leg","server_pid":999888,"session":"l","window_id":"@8","window_name":"sh","cwd":"/w/six","agent":"shell"}
JSON
_t6_put /s/leg 999888 "@8${TAB}/w/six${TAB}shell${TAB}\n@9"
_assert "t6: unnamed legacy window on a THIS-cwd server is inert" "0" "$(_t6_fast /w/six)"
# ...and its pair, which is what keeps the inertness test honest: the SAME fixture
# plus one `resume` row for @9. The ledger now holds a row for that window while
# naming no cwd for it (only an `open` row carries one), so it is genuinely unknown
# on a server tied to /w/six — the shape that must still defer. Drop the `in lany`
# guard and the assertion above passes vacuously; screen `resume` rows out of the
# index and this one collapses to 1's neighbour, 0.
_t6_base <<JSON
{"ts":102,"event":"open","socket_path":"/s/leg","server_pid":999888,"session":"l","window_id":"@8","window_name":"sh","cwd":"/w/six","agent":"shell"}
{"ts":103,"event":"resume","socket_path":"/s/leg","server_pid":999888,"window_id":"@9","label":"legnine","resume_cmd":"claude --resume legnine"}
JSON
_t6_put /s/leg 999888 "@8${TAB}/w/six${TAB}shell${TAB}\n@9"
_assert "t6: legacy window with a cwd-less ledger row on a THIS-cwd server defers" "2" "$(_t6_fast /w/six)"

# --- shape 2: a .windows with no .sock companion. The companion is the only join
# back to the socket path, so without it neither the liveness probe nor the
# per-window ledger join can run.
_t6_base </dev/null
_t6_put /s/nosock 999887 "@1${TAB}/w/away${TAB}work${TAB}1"
rm -f "$(_t6_f /s/nosock 999887).sock"
_assert "t6: .sock-less sidecar for another cwd does not suppress" "0" "$(_t6_fast /w/six)"
_t6_base </dev/null
_t6_put /s/nosock 999887 "@1${TAB}/w/six${TAB}work${TAB}1"
rm -f "$(_t6_f /s/nosock 999887).sock"
_assert "t6: .sock-less sidecar naming THIS cwd still defers" "2" "$(_t6_fast /w/six)"
# A .sock-less LEGACY sidecar is both shapes at once: no socket path AND no cwd,
# so the join degrades to the pid — which can only rule the sidecar out. An
# unrelated pid is ignorable; a pid the ledger ties to this cwd is not.
_t6_base </dev/null
_t6_put /s/legns 999886 "@9"
rm -f "$(_t6_f /s/legns 999886).sock"
_assert "t6: .sock-less legacy sidecar on an unrelated pid does not suppress" "0" "$(_t6_fast /w/six)"
# Its pair needs TWO sidecars sharing that pid — one properly joined (so the
# sidecar-less-server check passes and cannot be what produces the 2) and the
# .sock-less legacy one beside it. That is the only shape in which the pid-only
# fallback is the deciding test rather than a second guard. Inertness applies here
# too, and on the coarser key the missing socket forces: a @9 the ledger holds no
# row for under this PID is inert whichever server the sidecar turns out to be.
_t6_base <<JSON
{"ts":102,"event":"open","socket_path":"/s/legok","server_pid":999886,"session":"l","window_id":"@8","window_name":"sh","cwd":"/w/six","agent":"shell"}
JSON
_t6_put /s/legok 999886 "@8${TAB}/w/six${TAB}shell${TAB}"
_t6_put /s/legns 999886 "@9"
rm -f "$(_t6_f /s/legns 999886).sock"
_assert "t6: .sock-less legacy sidecar, window with no ledger row, is inert" "0" "$(_t6_fast /w/six)"
# Same fixture, one `resume` row added for @9 under that pid: now the ledger holds
# a row for the window but places it nowhere, and the pid-only join cannot rule the
# sidecar out — so this half must still defer.
_t6_base <<JSON
{"ts":102,"event":"open","socket_path":"/s/legok","server_pid":999886,"session":"l","window_id":"@8","window_name":"sh","cwd":"/w/six","agent":"shell"}
{"ts":103,"event":"resume","socket_path":"/s/legns","server_pid":999886,"window_id":"@9","label":"nsnine","resume_cmd":"claude --resume nsnine"}
JSON
_t6_put /s/legok 999886 "@8${TAB}/w/six${TAB}shell${TAB}"
_t6_put /s/legns 999886 "@9"
rm -f "$(_t6_f /s/legns 999886).sock"
_assert "t6: .sock-less legacy sidecar, window WITH a ledger row, defers" "2" "$(_t6_fast /w/six)"

# --- shape 3: a ledger server with NO sidecar. The ledger path reads it as "every
# window was open at death" and offers them, so it is unanswerable here — but the
# ledger also says exactly which cwds it had, so only those need defer.
_t6_base <<JSON
{"ts":102,"event":"open","socket_path":"/s/gone","server_pid":999885,"session":"g","window_id":"@1","window_name":"claude","cwd":"/w/away","agent":"work"}
{"ts":103,"event":"resume","socket_path":"/s/gone","server_pid":999885,"window_id":"@1","label":"dropgone","resume_cmd":"claude --resume dropgone"}
JSON
_assert "t6: sidecar-less ledger server for another cwd does not suppress" "0" "$(_t6_fast /w/six)"
_t6_base <<JSON
{"ts":102,"event":"open","socket_path":"/s/gone","server_pid":999885,"session":"g","window_id":"@1","window_name":"claude","cwd":"/w/six","agent":"work"}
{"ts":103,"event":"resume","socket_path":"/s/gone","server_pid":999885,"window_id":"@1","label":"dropgone","resume_cmd":"claude --resume dropgone"}
JSON
_assert "t6: sidecar-less ledger server for THIS cwd still defers" "2" "$(_t6_fast /w/six)"

# All three unrelated shapes at once — the real state dir has all of them, and the
# scoping only pays off if they compose rather than each costing the whole query.
_t6_base <<JSON
{"ts":102,"event":"open","socket_path":"/s/leg","server_pid":999888,"session":"l","window_id":"@9","window_name":"claude","cwd":"/w/away","agent":"work"}
{"ts":104,"event":"open","socket_path":"/s/gone","server_pid":999885,"session":"g","window_id":"@1","window_name":"claude","cwd":"/w/away","agent":"work"}
{"ts":105,"event":"resume","socket_path":"/s/gone","server_pid":999885,"window_id":"@1","label":"dropgone","resume_cmd":"claude --resume dropgone"}
JSON
_t6_put /s/leg 999888 "@9"
_t6_put /s/nosock 999887 "@1${TAB}/w/away${TAB}work${TAB}1"
rm -f "$(_t6_f /s/nosock 999887).sock"
_assert "t6: all three unrelated shapes together still answer" "0" "$(_t6_fast /w/six)"
# ...and the same pile answers a genuine NO, not a deferral: scoping must not turn
# "no drop here" into "cannot tell" either, or the fast path never returns 1.
_assert "t6: ...and still answers a genuine no for an unnamed cwd" "1" "$(_t6_fast /w/nothing)"
# The blank line: it names no window, so it hides nothing. Treating it as legacy
# would be an unresolvable bail with no window id to resolve — the global bail
# this whole block exists to remove.
_t6_base </dev/null
_t6_put /s/blank 999884 "@1${TAB}/w/away${TAB}work${TAB}1\n"
_assert "t6: a blank sidecar line is not a legacy line" "0" "$(_t6_fast /w/six)"

# Agreement against the ledger path, on the fixture that exercises the scoping:
# an answer the ledger path contradicts is the failure mode all of the above is
# guarding, and only sl_dropped can observe both (AMUX_PENDING_NO_FAST).
_t6_base <<JSON
{"ts":102,"event":"open","socket_path":"/s/leg","server_pid":999888,"session":"l","window_id":"@9","window_name":"claude","cwd":"/w/away","agent":"work"}
JSON
_t6_put /s/leg 999888 "@9"
_t6_cmp() {  # <cwd> → "<fast rows>|<ledger rows>"
  _t6_a=$(AGENTMUX_STATE_DIR="$_t6_dir" SESSION_LOG_BOOT_EPOCH=1 SESSION_LOG_RESUME_MAP="$RMAP" \
    sl_dropped --pending "$1" | grep -c .)
  _t6_b=$(AMUX_PENDING_NO_FAST=1 AGENTMUX_STATE_DIR="$_t6_dir" SESSION_LOG_BOOT_EPOCH=1 \
    SESSION_LOG_RESUME_MAP="$RMAP" sl_dropped --pending "$1" | grep -c .)
  printf '%s|%s' "$_t6_a" "$_t6_b"
}
_assert "t6: fast and ledger agree (drop, scoped past a legacy sidecar)" "1|1" "$(_t6_cmp /w/six)"
_assert "t6: fast and ledger agree (no drop)" "0|0" "$(_t6_cmp /w/nothing)"
rm -rf "$_t6_dir"

# ============ Task 5: `migrate` — the one-shot backfill of sidecars already on
#     disk. It is the piece that makes the fast path's speedup real: every sidecar
#     written before the enrichment change is a legacy bare-id file, and every one
#     written before the `.sock` companion existed has no socket path, and EITHER
#     shortfall alone sends every poll back to the ledger fold.
#
#     Fixture covers each shape at once, in ONE state dir, so the single pass has to
#     get them all right together:
#       A (/s/mig,  4001) legacy 2 lines, no .sock   → enriched + companion written
#       B (/s/mig2, 4002) EMPTY, no .sock            → stays empty, companion written
#       C (/s/mig3, 4003) legacy, one line the ledger knows and one it does not
#                                                    → per-LINE: @1 enriched, @9 left legacy
#       D (/s/mig4, 4004) already 4-field, has .sock → byte-identical afterwards
#       E (/s/mig5, 4005) named by the ledger, NO sidecar → none is created
#     B is the dangerous one: an empty sidecar records "nothing was open when this
#     server died", so enriching it into anything non-empty would resurrect tabs the
#     user deliberately closed. E is the other: a sidecar-less server is what MAKES
#     the fast path defer, and inventing one would turn that deferral into a silent
#     "no drop".
#
#     Non-vacuity is asserted explicitly rather than assumed: the pre-state checks
#     below prove A/C really are legacy and A/B/C really have no companion before the
#     run, and the reported counters prove the run did the work rather than no-op'd.
#     ============
_mig_dir=$(mktemp -d) || exit 1
mkdir -p "$_mig_dir/live"
_mig_f() { printf '%s/live/%s-%s.windows' "$_mig_dir" "$(printf '%s' "$1" | cksum | cut -d' ' -f1)" "$2"; }
_mig_a=$(_mig_f /s/mig 4001); _mig_b=$(_mig_f /s/mig2 4002)
_mig_c=$(_mig_f /s/mig3 4003); _mig_d=$(_mig_f /s/mig4 4004)
_mig_e=$(_mig_f /s/mig6 4006)
printf '@1\n@2\n' > "$_mig_a"        # legacy, no .sock
: > "$_mig_b"                        # EMPTY (clean teardown), no .sock
printf '@1\n@9\n' > "$_mig_c"        # legacy; @9 has no ledger row
printf '@1\t/w/d\twork\t1\n' > "$_mig_d"; printf '/s/mig4\n' > "$_mig_d.sock"
# F: an UNSTAMPED window — four fields, cwd EMPTY, the shape `_sl_live_windows`
# writes for a window whose @amux_* options never landed. `NF >= 4` called this
# already-current and short-circuited it, so migrate could never repair the very
# lines that make the fast path misread a cwd. Companion present, so it exercises
# enrichment alone.
printf '@1\t\t\t\n' > "$_mig_e"; printf '/s/mig6\n' > "$_mig_e.sock"
cat > "$_mig_dir/sessions.jsonl" <<JSON
{"ts":100,"event":"open","socket_path":"/s/mig","server_pid":4001,"session":"m","window_id":"@1","window_name":"claude","cwd":"/w/mig","agent":"work"}
{"ts":101,"event":"resume","socket_path":"/s/mig","server_pid":4001,"window_id":"@1","label":"mig1","resume_cmd":"claude --resume mig1"}
{"ts":102,"event":"open","socket_path":"/s/mig","server_pid":4001,"session":"m","window_id":"@2","window_name":"claude","cwd":"/w/mig","agent":"work"}
{"ts":103,"event":"open","socket_path":"/s/mig2","server_pid":4002,"session":"m2","window_id":"@1","window_name":"claude","cwd":"/w/mig2","agent":"work"}
{"ts":104,"event":"open","socket_path":"/s/mig3","server_pid":4003,"session":"m3","window_id":"@1","window_name":"claude","cwd":"/w/mig3","agent":"work"}
{"ts":105,"event":"open","socket_path":"/s/mig5","server_pid":4005,"session":"m5","window_id":"@1","window_name":"claude","cwd":"/w/mig5","agent":"work"}
{"ts":106,"event":"open","socket_path":"/s/mig6","server_pid":4006,"session":"m6","window_id":"@1","window_name":"claude","cwd":"/w/mig6","agent":"work"}
{"ts":107,"event":"resume","socket_path":"/s/mig6","server_pid":4006,"window_id":"@1","label":"mig6","resume_cmd":"claude --resume mig6"}
JSON
# Pre-state: prove the fixture really is in the shape the migration is supposed to
# fix, so a green run below cannot be green because there was nothing to do.
_assert "t5 pre: A/C carry legacy (<4-field) lines" "4" \
  "$(awk -F"$TAB" 'NF<4{n++} END{print n+0}' "$_mig_a" "$_mig_c")"
# F is the shape a field count CANNOT catch: four fields, cwd empty. Pinning both
# halves is what proves the enrichment below came from the cwd test, not the count.
_assert "t5 pre: F is 4-field with an EMPTY cwd" "1" \
  "$(awk -F"$TAB" 'NF>=4 && $2==""{n++} END{print n+0}' "$_mig_e")"
_mig_count() { _mn=0; for _mp in "$@"; do [ -e "$_mp" ] && _mn=$((_mn + 1)); done; printf '%s' "$_mn"; }
_assert "t5 pre: A/B/C have no .sock companion" "0" \
  "$(_mig_count "$_mig_a.sock" "$_mig_b.sock" "$_mig_c.sock")"
_mig_manifest() { for _mf in "$_mig_dir"/live/*; do printf '%s:%s ' "${_mf##*/}" "$(cksum < "$_mf" | cut -d' ' -f1)"; done; }
_mig_ids() { awk -F"$TAB" '{print FILENAME "|" $1}' "$_mig_dir"/live/*.windows; }
_mig_before_ids=$(_mig_ids)
_mig_d_before=$(cksum < "$_mig_d")

_mig_out=$(AGENTMUX_STATE_DIR="$_mig_dir" sl_migrate)
_assert "t5: migrate reports the work it did" "migrate: enriched=3 sock=3 legacy_left=1" "$_mig_out"

# A: legacy lines enriched from the ledger — cwd/agent off the `open` row, and
# `resumable` set only where a resume hint was recorded (mirroring exactly what the
# ledger path gates on, rcmd != "").
_assert "t5: legacy sidecar enriched, resumable window" "@1${TAB}/w/mig${TAB}work${TAB}1" "$(sed -n 1p "$_mig_a")"
_assert "t5: legacy sidecar enriched, non-resumable window" "@2${TAB}/w/mig${TAB}work${TAB}" "$(sed -n 2p "$_mig_a")"
_assert "t5: .sock-less sidecar gains its companion" "/s/mig" "$(cat "$_mig_a.sock")"

# B: THE dangerous case. An empty sidecar means "nothing was open at this server's
# death"; it must stay byte-for-byte empty, while still gaining the companion (which
# carries no membership).
_assert "t5: EMPTY sidecar stays empty" "0" "$(wc -c < "$_mig_b" | tr -d ' ')"
_assert "t5: empty sidecar still gains its .sock" "/s/mig2" "$(cat "$_mig_b.sock")"

# C: per-LINE, not per-file — a line the ledger cannot explain is left legacy so the
# fast path keeps DEFERRING for it (2), rather than being handed a guessed row.
_assert "t5: line with a ledger row is enriched" "@1${TAB}/w/mig3${TAB}work${TAB}" "$(sed -n 1p "$_mig_c")"
_assert "t5: line with NO ledger row left legacy" "@9" "$(sed -n 2p "$_mig_c")"

# D: an already-current sidecar is not rewritten at all.
_assert "t5: already-current sidecar untouched" "$_mig_d_before" "$(cksum < "$_mig_d")"

# F: the unstamped line is repaired in place — fields filled from the ledger, the
# window id untouched, and still exactly one line (membership byte-identical).
_assert "t5: unstamped 4-field line enriched" "@1${TAB}/w/mig6${TAB}work${TAB}1" "$(cat "$_mig_e")"
_assert "t5: unstamped sidecar keeps its one line" "1" "$(grep -c . "$_mig_e")"

# E: the ledger names /s/mig5 4005, which has no sidecar. Creating one would convert
# the fast path's deliberate deferral into a silent "no drop".
_assert "t5: no sidecar invented for a sidecar-less ledger server" "0" \
  "$(_mig_count "$(_mig_f /s/mig5 4005)")"
_assert "t5: sidecar count unchanged" "5" "$(_mig_count "$_mig_dir"/live/*.windows)"

# Membership is the invariant: fields may be added, window ids may not move.
_assert "t5: window-id membership unchanged" "$_mig_before_ids" "$(_mig_ids)"

# Idempotent: a second run finds every line 4-field and every companion present, so
# it stages nothing and the directory is bit-identical.
_mig_after=$(_mig_manifest)
_mig_out2=$(AGENTMUX_STATE_DIR="$_mig_dir" sl_migrate)
_assert "t5: second run is a no-op" "migrate: enriched=0 sock=0 legacy_left=1" "$_mig_out2"
_assert "t5: second run changes no bytes" "$_mig_after" "$(_mig_manifest)"
rm -rf "$_mig_dir"

echo "----"; echo "session_log selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
