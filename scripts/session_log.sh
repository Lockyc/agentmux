#!/bin/sh
# session_log.sh — durable roster of the agent windows amux opens, for recovery
# after a tmux server dies (kill-server / reboot). POSIX sh; deps: tmux, jq, toml2json.
# Invoked as a subprocess (never sourced).
#
# Subcommands:
#   open  <agent> [target] [socket]   append an open record (target defaults to current
#                            pane; socket is only needed when invoked OUTSIDE the tmux
#                            server the session lives on — see _sl_ctx)
#   resume <label> <cmd> [fork_cmd]   append/refresh a generic resume hint (+ optional
#                            fork hint) for the current window. fork_cmd is owned by the
#                            agent adapter, never composed here — this core stays agnostic.
#   forkcmd [target]         emit `agent<TAB>fork_cmd` for one LIVE window (or nothing)
#   dropped <cwd>|--global|--new <cwd>|--pending <cwd>
#                                        restorable dropped tabs (dead server, open-at-death)
#   prune                    trim the ledger (dead, old server instances)
#   snapshot <socket> <pid>  re-record a live server's window set (window-unlinked hook)
#   discard  <socket> <pid>  mark a server's windows deliberately closed (empty
#                            sidecar) — the amux --kill path, so a torn-down shard
#                            isn't recovered as a crash
#
# We reconcile against the set of windows that were open. For a LIVE server that
# set is queried directly (tmux list-windows). A DEAD server can't be queried, so
# while alive each server keeps a per-(socket,pid) "live-set" sidecar at
# <state>/live/<sockethash>-<pid>.windows, overwritten in place — no growth. Each
# line is FOUR tab-separated fields: window_id, cwd, agent, resumable (the same
# facts sl_dropped needs to render a restore row without re-querying tmux); a
# bare single-field line (just window_id, no tabs) is the legacy pre-migration
# shape and is still accepted everywhere the sidecar is read (`cut -f1` on such a
# line returns the whole line unchanged). UNENFORCED, deliberately: `cwd` is user
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
_sl_ledger() { printf '%s/sessions.jsonl' "$(_sl_state_dir)"; }
# Confirmed-dead (socket,pid) memo — one "socket|pid" per line.
#
# Server death is MONOTONIC: a (socket,pid) that failed a liveness probe can never
# answer again, because the only way that pair returns is tmux reusing the pid on the
# same socket — and that path logs a fresh `open`, which drops the memo entry (see
# sl_open). Without this, every presence poll re-probed every dead server recorded for
# the cwd: warden polls `dropped --pending` per session-less tab, each _sl_server_live
# forks a tmux, and the dead-server count only ever grows (the ledger keeps 14 days).
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

# Fold ledger → TSV, one row per opened window (latest open + latest resume per
# (socket,pid,window_id) tuple). Columns: socket pid window_id session
# window_name cwd agent resume_cmd maxts fork_cmd. `maxts` (the newest event ts
# for the window) drives sl_dropped's most-recent-first ordering. fork_cmd is
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

# sl_dropped <cwd> | --global | --new <cwd>
# Emit restorable DROPPED tabs from the SINGLE most recent crash — an agent tab
# (agent != shell, resume_cmd non-empty) on a DEAD server (pid no longer answers on its
# socket, or its records predate boot), that was OPEN AT DEATH (in the live-set sidecar;
# a dead server with no sidecar counts all its windows). One TSV row per tab:
# agent<TAB>cwd<TAB>resume_cmd<TAB>maxts, newest first. The resume program is swapped in
# from [[agents]] `resume` (work→claude-work) so the command targets the right profile.
# LAST-CRASH SCOPING: the ledger accumulates every dead server over its retention window;
# a reboot-heavy machine would otherwise dump a 2-week backlog. So we keep only the rows
# of the most-recently-active dead server (the crash you're recovering from), and DEDUP by
# resume session id (the same session resumed across several server lifetimes, or in two
# windows of one server, surfaces once). `<cwd>` filters to that dir; `--global` = no
# filter; `--new <cwd>` additionally emits ONLY servers not yet offered for that cwd and
# marks them offered (the once-per-server-per-project launch gate); `--pending <cwd>` applies
# that same gate READ-ONLY (no marking) — warden's presence probe polls it to decide whether a
# plain `amux` launch here would offer a restore, and a marking read would burn the gate.
sl_dropped() {
  _sl_enabled || return 0
  _sl_load_dead   # one read; turns the per-server liveness sweep fork-free for known-dead servers
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
        # Carry the server key + ts so the next stage can isolate ONE crash.
        print socket "|" pid, ts, agent, cwd, rcmd
      }
    ' \
  | sort -t"$TAB" -k2,2nr \
  | awk -F"$TAB" -v OFS="$TAB" '
      # LAST CRASH ONLY: rows are ts-desc, so the first row names the single
      # most-recently-active dead server (the crash we recover from); every other
      # dead server in the ledger is history, not a recovery target. Then DEDUP by
      # the resume session id (last token of the resume command) so a session that
      # lived in >1 window of that server surfaces once. First-seen wins = newest
      # (input already ts-desc), and the output stays ts-desc.
      NR==1 { best=$1 }
      $1 != best { next }
      { m=split($5, g, " "); uuid=g[m]
        if (uuid in seen) next
        seen[uuid]=1
        print $3, $4, $5, $2 }
    '

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

sl_resume() {  # <label> <resume_cmd> [fork_cmd]
  _label="$1"; _rcmd="$2"; _fcmd="${3:-}"
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
  _epid=""
  case "$TMUX" in *,*,*) _epid=${TMUX#*,}; _epid=${_epid%%,*} ;; esac
  _emark=""
  if [ -n "$_epid" ] && [ -n "${TMUX_PANE:-}" ]; then
    _emark="$_dir/seen/${_epid}-p$(printf '%s' "$TMUX_PANE" | tr -d '%')"
    [ -f "$_emark" ] && [ "$(cat "$_emark" 2>/dev/null)" = "$_sig" ] && return 0
  fi

  _sl_enabled || return 0

  # Miss (new label) or no usable env: fetch full context once for the record.
  IFS="$TAB" read -r _socket _pid _ _wid _ _ <<EOF
$(_sl_ctx)
EOF
  [ -n "$_pid" ] || return 0
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

sl_prune() {
  _sl_enabled || return 0
  _sl_load_dead
  _ledger=$(_sl_ledger); [ -s "$_ledger" ] || return 0
  _max=${AGENTMUX_LOG_MAX_LINES:-2000}
  _lines=$(wc -l < "$_ledger" 2>/dev/null | tr -d ' ')
  [ "${_lines:-0}" -gt "$_max" ] 2>/dev/null || return 0
  _cutoff=$(( $(date +%s) - ${AGENTMUX_LOG_RETAIN_DAYS:-14} * 86400 ))

  # Per-server max ts, then build the KEEP set: live OR recent (maxts >= cutoff).
  _servers=$(jq -rRn '
    [ inputs | fromjson? ]
    | group_by([.socket_path,.server_pid])
    | map([ .[0].socket_path, (.[0].server_pid|tostring), (map(.ts)|max|tostring) ] | @tsv) | .[]
  ' "$_ledger")
  _keep=$(printf '%s\n' "$_servers" | while IFS="$TAB" read -r socket pid maxts; do
    [ -n "$pid" ] || continue
    if _sl_server_live "$socket" "$pid" || [ "$maxts" -ge "$_cutoff" ] 2>/dev/null; then
      printf '%s|%s\n' "$socket" "$pid"
    fi
  done | jq -R -s 'split("\n") | map(select(length>0))')

  _tmp=$(mktemp) || return 0
  jq -cRn --argjson keep "$_keep" '
    inputs | fromjson?
    | ((.socket_path + "|" + (.server_pid|tostring)) as $k | select($keep | index($k)))
  ' "$_ledger" > "$_tmp" 2>/dev/null && mv "$_tmp" "$_ledger" || rm -f "$_tmp"

  # Trim the `notified` marker the same way as the ledger: it grows one
  # "socket|pid|cwd" line per (server,cwd) offered (sl_dropped --new appends,
  # never prunes), so keep only lines whose "socket|pid" PREFIX is still in the
  # live-or-recent KEEP set. Drops stale keys (and blank lines) so it self-cleans
  # instead of growing unbounded.
  _notmark="$(_sl_state_dir)/notified"
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
  _livepids=$(jq -rRn '[ inputs | fromjson? | .server_pid ] | unique | .[]' "$_ledger" 2>/dev/null)
  if [ -d "$(_sl_state_dir)/seen" ]; then
    for m in "$(_sl_state_dir)"/seen/*; do
      [ -e "$m" ] || continue
      mp=$(basename "$m"); mp=${mp%%-*}
      case "
$_livepids
" in *"
$mp
"*) : ;; *) rm -f "$m" ;; esac
    done
  fi

  # Same for the live-set sidecars (<sockethash>-<pid>.windows): drop those whose
  # server pid is no longer in the ledger. The pid is the trailing '-'-delimited
  # field (the socket hash precedes it); strip `.windows`, then take everything
  # after the last '-'.
  if [ -d "$(_sl_state_dir)/live" ]; then
    for m in "$(_sl_state_dir)"/live/*.windows; do
      [ -e "$m" ] || continue
      mp=$(basename "$m"); mp=${mp%.windows}; mp=${mp##*-}
      case "
$_livepids
" in *"
$mp
"*) : ;; *) rm -f "$m" "$m.sock" ;; esac
    done
  fi
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
_assert "pending: sees un-offered drop"  "1"  "$(printf '%s\n' "$outp" | grep -c 'claude-work --resume drop1')"

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

# --- prune: dead+old server dropped, live kept, recent-dead kept ---
now=$(date +%s); old=$(( now - 30*86400 ))
cat > "$ledger" <<JSON
{"ts":$old,"event":"open","socket_path":"/s/dead","server_pid":111,"session":"a","window_id":"@1","window_name":"claude","cwd":"/w/a","agent":"claude"}
{"ts":$now,"event":"open","socket_path":"/s/live","server_pid":222,"session":"b","window_id":"@1","window_name":"claude","cwd":"/w/b","agent":"claude"}
{"ts":$now,"event":"open","socket_path":"/s/recent","server_pid":333,"session":"c","window_id":"@1","window_name":"claude","cwd":"/w/c","agent":"claude"}
JSON
# seed the notified marker with all three servers, in the real 3-field
# socket|pid|cwd format sl_dropped --new writes (+ a blank line); prune must
# trim it to the live-or-recent keep set (matched on the socket|pid prefix,
# with the cwd suffix stripped), matching the ledger.
printf '%s\n' '/s/dead|111|/w/a' '/s/live|222|/w/b' '' '/s/recent|333|/w/c' > "$AGENTMUX_STATE_DIR/notified"
AGENTMUX_LOG_MAX_LINES=1 SESSION_LOG_LIVE_PIDS="222" sl_prune
_assert "prune drops dead+old 111" "0" "$(grep -c '"server_pid":111' "$ledger")"
_assert "prune keeps live 222"     "1" "$(grep -c '"server_pid":222' "$ledger")"
_assert "prune keeps recent 333"   "1" "$(grep -c '"server_pid":333' "$ledger")"
_assert "prune trims notified: drops dead"   "0" "$(grep -c '^/s/dead|111|/w/a$' "$AGENTMUX_STATE_DIR/notified")"
_assert "prune trims notified: keeps live"   "1" "$(grep -c '^/s/live|222|/w/b$' "$AGENTMUX_STATE_DIR/notified")"
_assert "prune trims notified: keeps recent" "1" "$(grep -c '^/s/recent|333|/w/c$' "$AGENTMUX_STATE_DIR/notified")"
_assert "prune trims notified: drops blanks" "0" "$(grep -cx '' "$AGENTMUX_STATE_DIR/notified")"

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

echo "----"; echo "session_log selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
