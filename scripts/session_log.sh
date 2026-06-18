#!/bin/sh
# session_log.sh — durable roster of the agent windows amux opens, for recovery
# after a tmux server dies (kill-server / reboot). POSIX sh; deps: tmux, jq, toml2json.
# Invoked as a subprocess (never sourced).
#
# Subcommands:
#   open  <agent> [target]   append an open record (target defaults to current pane)
#   resume <label> <cmd>     append/refresh a generic resume hint for the current window
#   list                     print the roster, partitioned live vs lost (dead server)
#   prune                    trim the ledger (dead, old server instances)
#
# There is deliberately NO close event: tmux's pane-exit hooks cannot reliably
# identify the exited pane (they fire with the ACTIVE pane's context once the
# pane is gone), so a close hook would misattribute and hide live windows. We
# reconcile instead at read time — a live server's rows are intersected with its
# currently-open windows (see _sl_live_windows / sl_list).

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

# Window ids currently open on the live server at <socket>. Used to intersect a
# live server's ledger rows against reality (a window closed since its open was
# logged is gone from this list), replacing the unreliable close hook.
_sl_live_windows() {  # <socket>
  if [ -n "${SESSION_LOG_LIVE_WINDOWS+x}" ]; then
    printf '%s\n' "$SESSION_LOG_LIVE_WINDOWS"
    return 0
  fi
  tmux -S "$1" list-windows -a -F '#{window_id}' 2>/dev/null
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
# window_name cwd agent resume_cmd. Whether a window is still open is decided at
# read time by sl_list (live server → intersect with reality), not here.
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
            $o.window_name, $o.cwd, $o.agent, ($r.resume_cmd // "") ] | @tsv )
    | .[]
  ' "$1"
}

# Print the rows for one server. Columns: socket pid window_id session
# window_name cwd agent resume_cmd. For a LIVE server, <livewins> is the set of
# window ids actually still open there — rows whose window is gone are skipped.
# For a LOST (dead) server, <livewins> is empty and every recorded window shows
# (the recovery roster — we cannot intersect a server that no longer exists).
_sl_print_server() {  # <rowsfile> <socket> <pid> <state> <livewins>
  if [ "$4" = live ]; then printf '\n● live   server %s\n' "$3"
  else printf '\n✗ lost   server %s · died (kill-server or reboot)\n' "$3"; fi
  awk -F"$TAB" -v sp="$2" -v pid="$3" -v state="$4" -v live="$5" '
    BEGIN { n = split(live, a, /[ \n]+/); for (i = 1; i <= n; i++) if (a[i] != "") L[a[i]] = 1 }
    $1 == sp && $2 == pid {
      if (state == "live" && !($3 in L)) next
      loc = $4 ":" $7
      if ($8 == "") cmd = "cd " $6 "   (relaunch — no resume hint)"
      else          cmd = "cd " $6 "; " $8
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
      [ "$state" = "$want" ] || continue
      if [ "$state" = live ]; then
        _sl_print_server "$rows" "$socket" "$pid" live "$(_sl_live_windows "$socket")"
      else
        _sl_print_server "$rows" "$socket" "$pid" lost ""
      fi
    done
  done
  rm -f "$rows"
}

# One-time recovery nudge. Prints a single line iff a previous tmux server died
# with agent windows still open (crash/reboot) and hasn't been announced yet —
# marking those servers announced so it fires once per dead server, not every
# launch. A server is lost if its pid no longer answers on its socket, OR its
# newest record predates boot (a reboot that reused the pid). Silent otherwise.
sl_notice() {
  _sl_enabled || return 0
  _ledger=$(_sl_ledger); [ -s "$_ledger" ] || return 0
  _boot=$(_sl_boot_epoch)
  _dir=$(_sl_state_dir)
  _notmark="$_dir/notified"

  # Per server: socket, pid, newest ts, distinct-window count (from open events).
  _servers=$(jq -rRn '
    [ inputs | fromjson? | select(.event=="open") ]
    | group_by([.socket_path, .server_pid])
    | map([ .[0].socket_path, (.[0].server_pid|tostring),
            (map(.ts)|max|tostring), ([.[].window_id]|unique|length|tostring) ] | @tsv) | .[]
  ' "$_ledger")
  [ -n "$_servers" ] || return 0

  _total=0; _new=""; _reboot=0; _killed=0
  while IFS="$TAB" read -r _socket _pid _maxts _wcount; do
    [ -n "$_pid" ] || continue
    # Live iff the pid still answers AND the records aren't from before boot.
    if _sl_server_live "$_socket" "$_pid" && { [ -z "$_boot" ] || [ "$_maxts" -ge "$_boot" ] 2>/dev/null; }; then
      continue
    fi
    _key="$_socket|$_pid"
    if [ -f "$_notmark" ] && grep -qxF "$_key" "$_notmark" 2>/dev/null; then continue; fi
    _total=$((_total + _wcount))
    _new="$_new$_key
"
    if [ -n "$_boot" ] && [ "$_maxts" -lt "$_boot" ] 2>/dev/null; then _reboot=1; else _killed=1; fi
  done <<EOF
$_servers
EOF

  [ "$_total" -gt 0 ] || return 0
  mkdir -p "$_dir" 2>/dev/null && printf '%s' "$_new" >> "$_notmark" 2>/dev/null || true

  _cause="a previous tmux server"
  if [ "$_reboot" = 1 ] && [ "$_killed" = 0 ]; then _cause="a reboot"
  elif [ "$_killed" = 1 ] && [ "$_reboot" = 0 ]; then _cause="a server kill"; fi
  _s=s; [ "$_total" = 1 ] && _s=""
  printf '⚠ %d agent session%s lost to %s — recover with: amux --log\n' "$_total" "$_s" "$_cause"
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
    list)   sl_list   "$@" ;;
    notice) sl_notice "$@" ;;
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

# --- fold + list reconcile, with stubbed liveness + live-window intersection ---
rm -f "$ledger"; unset AGENTMUX_SESSION_LOG; AGENTMUX_SESSION_LOG=1
# server 4242 live (two windows: @1 still open, @5 since closed); 9981 dead (one window)
cat > "$ledger" <<'JSON'
{"ts":1,"event":"open","socket_path":"/s/a","server_pid":4242,"session":"locus","window_id":"@1","window_name":"claude","cwd":"/w/locus","agent":"claude"}
{"ts":2,"event":"open","socket_path":"/s/a","server_pid":4242,"session":"scratch","window_id":"@5","window_name":"claude","cwd":"/w/scratch","agent":"claude"}
{"ts":3,"event":"open","socket_path":"/s/b","server_pid":9981,"session":"red","window_id":"@1","window_name":"claude","cwd":"/w/red","agent":"claude"}
{"ts":4,"event":"resume","socket_path":"/s/b","server_pid":9981,"window_id":"@1","label":"a1b2","resume_cmd":"claude --resume a1b2"}
JSON

foldout=$(_sl_fold "$ledger")
_assert "fold lists every opened window" "3" "$(printf '%s\n' "$foldout" | grep -c .)"
_assert "fold spans 2 distinct servers"  "2" "$(printf '%s\n' "$foldout" | cut -f2 | sort -u | grep -c .)"

# live server 4242 intersects with its currently-open windows (@1 only → @5 dropped);
# dead server 9981 shows its full roster (no intersection possible)
out=$(SESSION_LOG_LIVE_PIDS="4242" SESSION_LOG_LIVE_WINDOWS="@1" sl_list)
_assert "list flags 9981 lost"          "1" "$(printf '%s\n' "$out" | grep -c 'lost   server 9981')"
_assert "list flags 4242 live"          "1" "$(printf '%s\n' "$out" | grep -c 'live   server 4242')"
_assert "live: shows still-open window" "1" "$(printf '%s\n' "$out" | grep -c '/w/locus')"
_assert "live: hides closed window"     "0" "$(printf '%s\n' "$out" | grep -c '/w/scratch')"
_assert "lost: full roster shown"       "1" "$(printf '%s\n' "$out" | grep -c '/w/red')"
_assert "lost: shows resume cmd"        "1" "$(printf '%s\n' "$out" | grep -c 'claude --resume a1b2')"

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

# --- notice: dead server fires a one-time recovery nudge; live ignored ---
rm -f "$ledger" "$AGENTMUX_STATE_DIR/notified"
_now=$(date +%s)
cat > "$ledger" <<JSON
{"ts":$_now,"event":"open","socket_path":"/s/dead","server_pid":555,"session":"a","window_id":"@1","window_name":"claude","cwd":"/w/a","agent":"claude"}
{"ts":$_now,"event":"open","socket_path":"/s/dead","server_pid":555,"session":"b","window_id":"@2","window_name":"claude","cwd":"/w/b","agent":"claude"}
{"ts":$_now,"event":"open","socket_path":"/s/live","server_pid":999,"session":"c","window_id":"@1","window_name":"claude","cwd":"/w/c","agent":"claude"}
JSON
n1=$(SESSION_LOG_LIVE_PIDS="999" SESSION_LOG_BOOT_EPOCH=$((_now - 3600)) sl_notice)
_assert "notice counts dead server's 2 windows" "1" "$(printf '%s\n' "$n1" | grep -c '2 agent sessions lost')"
_assert "notice ignores the live server"        "1" "$(printf '%s\n' "$n1" | grep -c 'a server kill')"
n2=$(SESSION_LOG_LIVE_PIDS="999" SESSION_LOG_BOOT_EPOCH=$((_now - 3600)) sl_notice)
_assert "notice is once-per-dead-server (then silent)" "" "$n2"

# --- notice: a pre-boot server is lost even if its pid was reused (reboot) ---
rm -f "$ledger" "$AGENTMUX_STATE_DIR/notified"
cat > "$ledger" <<JSON
{"ts":$((_now - 100000)),"event":"open","socket_path":"/s/old","server_pid":777,"session":"a","window_id":"@1","window_name":"claude","cwd":"/w/old","agent":"claude"}
JSON
n3=$(SESSION_LOG_LIVE_PIDS="777" SESSION_LOG_BOOT_EPOCH=$_now sl_notice)
_assert "notice catches pre-boot reboot (pid reused)" "1" "$(printf '%s\n' "$n3" | grep -c 'lost to a reboot')"

echo "----"; echo "session_log selftest: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
