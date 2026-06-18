#!/bin/sh
# session_log.sh — durable roster of the agent windows amux opens, for recovery
# after a tmux server dies (kill-server / reboot). POSIX sh; deps: tmux, jq, toml2json.
# Invoked as a subprocess (never sourced).
#
# Subcommands:
#   open  <agent> [target]   append an open record (target defaults to current pane)
#   resume <label> <cmd>     append/refresh a generic resume hint for the current window
#   close [target]           best-effort: append a close record
#   list                     print the roster, partitioned live vs lost (dead server)
#   prune                    trim the ledger (dead, old server instances)

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

# Fold ledger → TSV of currently-open tuples. Input is chronological (append order);
# a tuple is open iff its latest open/close event is an open.
# Read line-by-line with `fromjson?` so a single torn/blank line (e.g. a
# kill-server mid-append) is skipped, not fatal — the whole point is surviving
# a crash, and a slurp (`-s`) aborts the entire roster on one bad line.
_sl_fold() {  # <ledger>
  [ -s "$1" ] || return 0
  jq -rRn '
    [ inputs | fromjson? ]
    | group_by([.socket_path, .server_pid, .window_id])
    | map(
        . as $g
        | ($g | map(select(.event=="open" or .event=="close")) | last) as $oc
        | select($oc != null and $oc.event == "open")
        | ($g | map(select(.event=="open"))   | last) as $o
        | ($g | map(select(.event=="resume")) | last) as $r
        | [ $o.socket_path, ($o.server_pid|tostring), $o.session,
            $o.window_name, $o.cwd, $o.agent, ($r.resume_cmd // "") ] | @tsv )
    | .[]
  ' "$1"
}

# Print the rows for one server (already known live/lost).
_sl_print_server() {  # <rowsfile> <socket> <pid> <state>
  if [ "$4" = live ]; then printf '\n● live   server %s\n' "$3"
  else printf '\n✗ lost   server %s · died (kill-server or reboot)\n' "$3"; fi
  awk -F"$TAB" -v sp="$2" -v pid="$3" '
    $1==sp && $2==pid {
      loc=$3":"$6
      if ($7=="") cmd="cd " $5 "   (relaunch — no resume hint)"
      else        cmd="cd " $5 "; " $7
      printf "   %-22s %s\n", loc, cmd
    }' "$1"
}

sl_list() {
  _sl_enabled || { echo "amux: session logging disabled ([log] sessions = false)"; return 0; }
  rows=$(mktemp) || return 1
  _sl_fold "$(_sl_ledger)" > "$rows"
  if [ ! -s "$rows" ]; then echo "amux: no logged sessions"; rm -f "$rows"; return 0; fi

  servers=$(cut -f1,2 "$rows" | sort -u)
  # Lost first (the recovery roster), then live.
  for want in lost live; do
    printf '%s\n' "$servers" | while IFS="$TAB" read -r socket pid; do
      [ -n "$pid" ] || continue
      if _sl_server_live "$socket" "$pid"; then state=live; else state=lost; fi
      [ "$state" = "$want" ] && _sl_print_server "$rows" "$socket" "$pid" "$state"
    done
  done
  rm -f "$rows"
}

# Generic resume-hint enrichment. Runs inside the agent's own pane.
# Marker check is FIRST so steady-state calls are cheap (no toml read, no append).
sl_resume() {  # <label> <resume_cmd>
  _label="$1"; _rcmd="$2"
  IFS="$TAB" read -r _socket _pid _ _wid _ _ <<EOF
$(_sl_ctx)
EOF
  [ -n "$_pid" ] && [ -n "$_label" ] || return 0
  _dir=$(_sl_state_dir)
  _marker="$_dir/seen/${_pid}-$(printf '%s' "$_wid" | tr -d '@')"
  if [ -f "$_marker" ] && [ "$(cat "$_marker" 2>/dev/null)" = "$_label" ]; then
    return 0
  fi
  _sl_enabled || return 0
  mkdir -p "$_dir/seen" 2>/dev/null || return 0
  printf '%s' "$_label" > "$_marker" 2>/dev/null || true
  _line=$(jq -cn \
    --argjson ts "$(date +%s)" --arg sp "$_socket" --argjson pid "$_pid" \
    --arg wid "$_wid" --arg label "$_label" --arg rc "$_rcmd" \
    '{ts:$ts,event:"resume",socket_path:$sp,server_pid:$pid,window_id:$wid,label:$label,resume_cmd:$rc}')
  _sl_append "$_line"
}

sl_close() {  # [target]
  _sl_enabled || return 0
  IFS="$TAB" read -r _socket _pid _ _wid _ _ <<EOF
$(_sl_ctx "${1:-}")
EOF
  [ -n "$_pid" ] || return 0
  _line=$(jq -cn --argjson ts "$(date +%s)" \
    --arg sp "$_socket" --argjson pid "$_pid" --arg wid "$_wid" \
    '{ts:$ts,event:"close",socket_path:$sp,server_pid:$pid,window_id:$wid}')
  _sl_append "$_line"
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

  # Best-effort marker sweep: drop seen/<pid>-* for pids no longer in the ledger.
  if [ -d "$(_sl_state_dir)/seen" ]; then
    _livepids=$(jq -rRn '[ inputs | fromjson? | .server_pid ] | unique | .[]' "$_ledger" 2>/dev/null)
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
}

# ---- dispatch ----
if [ "${SESSION_LOG_SELFTEST:-}" != "1" ]; then
  cmd="${1:-}"; [ $# -gt 0 ] && shift
  case "$cmd" in
    open)   sl_open   "$@" ;;
    resume) sl_resume "$@" ;;
    close)  sl_close  "$@" ;;
    list)   sl_list   "$@" ;;
    prune)  sl_prune  "$@" ;;
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

# --- fold + list reconcile, with stubbed liveness ---
rm -f "$ledger"; unset AGENTMUX_SESSION_LOG; AGENTMUX_SESSION_LOG=1
# server 4242 live (one window), server 9981 dead (two windows; one later closed)
cat > "$ledger" <<'JSON'
{"ts":1,"event":"open","socket_path":"/s/a","server_pid":4242,"session":"locus","window_id":"@1","window_name":"claude","cwd":"/w/locus","agent":"claude"}
{"ts":2,"event":"open","socket_path":"/s/b","server_pid":9981,"session":"red","window_id":"@1","window_name":"claude","cwd":"/w/red","agent":"claude"}
{"ts":3,"event":"resume","socket_path":"/s/b","server_pid":9981,"window_id":"@1","label":"a1b2","resume_cmd":"claude --resume a1b2"}
{"ts":4,"event":"open","socket_path":"/s/b","server_pid":9981,"session":"scr","window_id":"@2","window_name":"claude","cwd":"/w/scr","agent":"claude"}
{"ts":5,"event":"close","socket_path":"/s/b","server_pid":9981,"window_id":"@2"}
JSON

foldout=$(_sl_fold "$ledger")
_assert "fold drops closed @2"   "0" "$(printf '%s\n' "$foldout" | grep -c '/w/scr')"
_assert "fold keeps live @1"     "1" "$(printf '%s\n' "$foldout" | grep -c '/w/locus')"
_assert "fold keeps dead open"   "1" "$(printf '%s\n' "$foldout" | grep -c '/w/red')"

out=$(SESSION_LOG_LIVE_PIDS="4242" sl_list)
_assert "list flags 9981 lost"   "1" "$(printf '%s\n' "$out" | grep -c 'lost   server 9981')"
_assert "list flags 4242 live"   "1" "$(printf '%s\n' "$out" | grep -c 'live   server 4242')"
_assert "list shows resume cmd"  "1" "$(printf '%s\n' "$out" | grep -c 'claude --resume a1b2')"

# window-id reuse across servers stays distinct (both @1, different pids → both kept)
_assert "win-id reuse → 2 distinct servers"  "2" "$(printf '%s\n' "$foldout" | cut -f2 | sort -u | grep -c .)"

# --- resume enrichment + dedup (uses the stubbed tmux: pid 4242, @3) ---
rm -f "$ledger"; rm -rf "$AGENTMUX_STATE_DIR/seen"
sl_resume "9f3c" "claude --resume 9f3c"
_assert "resume writes one" "1" "$(grep -c '"event":"resume"' "$ledger")"
sl_resume "9f3c" "claude --resume 9f3c"
_assert "resume dedups same label" "1" "$(grep -c '"event":"resume"' "$ledger")"
sl_resume "abcd" "claude --resume abcd"
_assert "resume writes on new label" "2" "$(grep -c '"event":"resume"' "$ledger")"
# fold must surface the LATEST resume cmd for that window
seedl="$AGENTMUX_STATE_DIR/seed.jsonl"
cat > "$seedl" <<'JSON'
{"ts":1,"event":"open","socket_path":"/s/a","server_pid":4242,"session":"locus","window_id":"@3","window_name":"claude","cwd":"/w/locus","agent":"claude"}
{"ts":2,"event":"resume","socket_path":"/s/a","server_pid":4242,"window_id":"@3","label":"old","resume_cmd":"claude --resume old"}
{"ts":3,"event":"resume","socket_path":"/s/a","server_pid":4242,"window_id":"@3","label":"new","resume_cmd":"claude --resume new"}
JSON
_assert "fold takes latest resume" "1" "$(_sl_fold "$seedl" | grep -c 'claude --resume new')"

# --- close ---
rm -f "$ledger"
sl_open claude            # stub → pid 4242, @3
sl_close
_assert "close appends record" "1" "$(grep -c '"event":"close"' "$ledger")"
_assert "fold hides closed win" "0" "$(_sl_fold "$ledger" | grep -c '/tmp/work')"

# --- prune: dead+old server dropped, live kept, recent-dead kept ---
now=$(date +%s); old=$(( now - 30*86400 ))
cat > "$ledger" <<JSON
{"ts":$old,"event":"open","socket_path":"/s/dead","server_pid":111,"session":"a","window_id":"@1","window_name":"claude","cwd":"/w/a","agent":"claude"}
{"ts":$now,"event":"open","socket_path":"/s/live","server_pid":222,"session":"b","window_id":"@1","window_name":"claude","cwd":"/w/b","agent":"claude"}
{"ts":$now,"event":"open","socket_path":"/s/recent","server_pid":333,"session":"c","window_id":"@1","window_name":"claude","cwd":"/w/c","agent":"claude"}
JSON
AGENTMUX_LOG_MAX_LINES=1 SESSION_LOG_LIVE_PIDS="222" sl_prune
_assert "prune drops dead+old 111" "0" "$(grep -c '"server_pid":111' "$ledger")"
_assert "prune keeps live 222"     "1" "$(grep -c '"server_pid":222' "$ledger")"
_assert "prune keeps recent 333"   "1" "$(grep -c '"server_pid":333' "$ledger")"

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

echo "----"; echo "session_log selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
