#!/bin/sh
# session_log.sh — durable roster of the agent windows amux opens, for recovery
# after a tmux server dies (kill-server / reboot). POSIX sh; deps: tmux, jq, toml2json.
# Invoked as a subprocess (never sourced).
#
# Subcommands:
#   open  <agent> [target]   append an open record (target defaults to current pane)
#   resume <label> <cmd> [fork_cmd]   append/refresh a generic resume hint (+ optional
#                            fork hint) for the current window. fork_cmd is owned by the
#                            agent adapter, never composed here — this core stays agnostic.
#   forkcmd [target]         emit `agent<TAB>fork_cmd` for one LIVE window (or nothing)
#   dropped <cwd>|--global|--new <cwd>   restorable dropped tabs (dead server, open-at-death)
#   prune                    trim the ledger (dead, old server instances)
#   snapshot <socket> <pid>  re-record a live server's window set (window-unlinked hook)
#
# We reconcile against the set of windows that were open. For a LIVE server that
# set is queried directly (tmux list-windows). A DEAD server can't be queried, so
# while alive each server keeps a per-pid "live-set" sidecar at
# <state>/live/<pid>.windows (one window id per line), overwritten in place — no
# growth. It is refreshed PURELY event-driven — no background loop:
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
_sl_ctx() {
  # SESSION_LOG_CTX overrides the tmux query for tests (mirrors the
  # SESSION_LOG_LIVE_* / SESSION_LOG_RESUME_MAP hooks), bypassing tmux entirely.
  if [ -n "${SESSION_LOG_CTX+x}" ]; then
    printf '%s\n' "$SESSION_LOG_CTX"
    return 0
  fi
  fmt="#{socket_path}${TAB}#{pid}${TAB}#{session_name}${TAB}#{window_id}${TAB}#{window_name}${TAB}#{pane_current_path}"
  _t="${1:-${TMUX_PANE:-}}"
  if [ -n "$_t" ]; then
    tmux display-message -p -t "$_t" "$fmt" 2>/dev/null
  else
    tmux display-message -p "$fmt" 2>/dev/null
  fi
}

sl_open() {  # <agent> [target]
  _sl_enabled || return 0
  _agent="$1"; _target="${2:-}"
  IFS="$TAB" read -r _socket _pid _session _wid _wname _cwd <<EOF
$(_sl_ctx "$_target")
EOF
  [ -n "$_pid" ] || return 0
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
_sl_server_live() {  # <socket> <pid>
  if [ -n "${SESSION_LOG_LIVE_PIDS+x}" ]; then
    case " $SESSION_LOG_LIVE_PIDS " in *" $2 "*) return 0 ;; *) return 1 ;; esac
  fi
  got=$(tmux -S "$1" display-message -p '#{pid}' 2>/dev/null) || return 1
  [ "$got" = "$2" ]
}

# Window ids currently open on the live server at <socket>. Used to intersect a
# live server's ledger rows against reality (a window closed since its open was
# logged is gone from this list), replacing the unreliable close hook.
_sl_live_windows() {  # <socket>
  if [ -n "${SESSION_LOG_LIVE_WINDOWS+x}" ]; then
    # Unquoted on purpose: emit one window id per line, mirroring tmux's output
    # (so tests exercise the real newline-separated shape).
    # shellcheck disable=SC2086
    printf '%s\n' $SESSION_LOG_LIVE_WINDOWS
    return 0
  fi
  tmux -S "$1" list-windows -a -F '#{window_id}' 2>/dev/null
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

# Overwrite <pid>'s sidecar with the server's current window set. Reuses
# _sl_live_windows so the SESSION_LOG_LIVE_WINDOWS test hook drives it too. Atomic
# (temp + mv) so a reader never sees a half-written set; fails soft.
_sl_snapshot() {  # <socket> <pid>
  _lf=$(_sl_live_file "$1" "$2"); _dir=${_lf%/*}
  mkdir -p "$_dir" 2>/dev/null || return 0
  _tmp="$_dir/.$2.$$.tmp"
  if _sl_live_windows "$1" > "$_tmp" 2>/dev/null; then
    mv "$_tmp" "$_lf" 2>/dev/null || rm -f "$_tmp"
  else
    rm -f "$_tmp"
  fi
}

# Read a dead server's recorded live-set (empty if the file is absent).
_sl_snapshot_windows() { cat "$(_sl_live_file "$1" "$2")" 2>/dev/null; }  # <socket> <pid>

# Public snapshot subcommand: re-record a live server's window set. Invoked by the
# `window-unlinked` tmux hook on CLOSE (re-queries the whole set, so the closed
# window is naturally absent) — event-driven, no loop, no background process.
# sl_open/sl_resume call _sl_snapshot directly on OPEN.
sl_snapshot() {  # <socket> <pid>
  _sl_enabled || return 0
  _sl_snapshot "$1" "$2"
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
# marks them offered (the once-per-server-per-project launch gate).
sl_dropped() {
  _sl_enabled || return 0
  _mark_new=0; _scope=""
  case "$1" in
    --new)    _mark_new=1; _scope="${2:-}" ;;
    --global) _scope="--global" ;;
    *)        _scope="${1:-}" ;;
  esac
  _ledger=$(_sl_ledger); [ -s "$_ledger" ] || return 0
  _boot=$(_sl_boot_epoch)
  _notmark="$(_sl_state_dir)/notified"
  rows=$(mktemp) || return 1
  _sl_fold "$_ledger" > "$rows"
  if [ ! -s "$rows" ]; then rm -f "$rows"; return 0; fi

  # Per (socket,pid): decide dead vs live, and capture the recorded live-set (or '*'
  # for a dead server with no sidecar → all windows count). Live servers emit nothing.
  state=$(mktemp) || { rm -f "$rows"; return 1; }
  cut -f1,2 "$rows" | sort -u | while IFS="$TAB" read -r socket pid; do
    [ -n "$pid" ] || continue
    smax=$(awk -F"$TAB" -v s="$socket" -v p="$pid" '$1==s&&$2==p{if($9+0>m)m=$9}END{print m+0}' "$rows")
    if _sl_server_live "$socket" "$pid" && { [ -z "$_boot" ] || [ "$smax" -ge "$_boot" ] 2>/dev/null; }; then
      continue
    fi
    if [ "$_mark_new" = 1 ]; then
      _gk="$socket|$pid|$_scope"
      if [ -f "$_notmark" ] && grep -qxF "$_gk" "$_notmark" 2>/dev/null; then
        continue                                   # already offered for this cwd
      fi
      mkdir -p "$(_sl_state_dir)" 2>/dev/null && printf '%s\n' "$_gk" >> "$_notmark" 2>/dev/null || true
    fi
    if [ -f "$(_sl_live_file "$socket" "$pid")" ]; then
      _sw=$(_sl_snapshot_windows "$socket" "$pid" | tr '\n' ' ')
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
"*) : ;; *) rm -f "$m" ;; esac
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
    *) echo "session_log.sh: unknown subcommand '$cmd'" >&2; exit 2 ;;
  esac
  exit 0
fi

# ============================ selftest ============================
# SESSION_LOG_SELFTEST=1 sh scripts/session_log.sh
AGENTMUX_STATE_DIR=$(mktemp -d) || exit 1
AGENTMUX_SESSION_LOG=1
export AGENTMUX_STATE_DIR AGENTMUX_SESSION_LOG
trap 'rm -rf "$AGENTMUX_STATE_DIR"' EXIT

pass=0; fail=0
_assert() {  # <desc> <expected> <actual>
  if [ "$3" = "$2" ]; then pass=$((pass+1)); echo "PASS: $1"
  else fail=$((fail+1)); echo "FAIL: $1 — expected '$2' got '$3'"; fi
}

# Stub tmux: canned display-message context, no real server needed.
tmux() {
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
AGENTMUX_LOG_MAX_LINES=1 SESSION_LOG_LIVE_PIDS="222" sl_prune
_assert "prune removes dead sidecar"      "0" "$([ -f "$_lf_dead" ] && echo 1 || echo 0)"
_assert "prune keeps live sidecar"        "1" "$([ -f "$_lf_live" ] && echo 1 || echo 0)"

# --- snapshot subcommand re-records the live window set (the window-unlinked hook
#     path — this is how CLOSES are caught: re-query the whole set, closed window
#     already absent; no loop, no heartbeat) ---
rm -rf "$AGENTMUX_STATE_DIR/live"
SESSION_LOG_LIVE_WINDOWS="@3 @7" sl_snapshot "/s/a" 5150
_assert "snapshot subcommand writes sidecar" "@3 @7" "$(tr '\n' ' ' < "$(_sl_live_file "/s/a" 5150)" | sed 's/ *$//')"

echo "----"; echo "session_log selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
