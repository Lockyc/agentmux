#!/bin/bash
# es-watch.sh — always-on Endpoint Security watch over the processes that hold agentmux
# sessions: how every tmux server, pane shell, agent and the hosting terminal app exits,
# and every signal sent to or by any of them, with the sending process named. It answers
# "what ended this tmux server?" — amux's own teardowns are already in teardown.log; this
# catches everything else (a signal, a crash, a server that ran out of sessions).
#
#   es-watch.sh install     install + start (asks for sudo once)
#   es-watch.sh uninstall   stop + remove everything install created
#   es-watch.sh status      daemons, reader, and the last lines of the log
#   es-watch.sh reader      the reader loop (run by its LaunchAgent, not by hand)
#
# Shape: two root LaunchDaemons whose program is /usr/bin/eslogger itself (so Full Disk
# Access is granted to eslogger alone, never to a shell), each appending raw JSON to a
# user-owned file; a user LaunchAgent tails both, keeps only the lines that matter as one
# TSV line each in $LOG, and truncates a raw file once it has been read past RAW_CAP.
# Raw files are pre-created by the user so the reader can truncate them; eslogger opens
# them O_APPEND, so it keeps writing at the new end.
#
# Needs: macOS 13+ (eslogger), Full Disk Access for /usr/bin/eslogger, /usr/bin/jq.
set -u

STATE="${AGENTMUX_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/agentmux}"
DIR="$STATE/es-watch"
LOG="$STATE/es-watch.log"
RAW_EXIT="$DIR/raw-exit.ndjson"
RAW_SIGNAL="$DIR/raw-signal.ndjson"
RAW_CAP=$((50 * 1024 * 1024))
LABEL=agentmux.es-watch
DAEMON_DIR=/Library/LaunchDaemons
AGENT_PLIST="$HOME/Library/LaunchAgents/$LABEL.reader.plist"
SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

# The program-path prefix eslogger --select matches for a binary on PATH: its resolved
# path up to the versioned directory, so an upgrade (Cellar/tmux/3.7c → 3.8) still matches.
_prefix() {  # <command>
  local p; p=$(command -v "$1" 2>/dev/null) || return 1
  p=$(readlink -f "$p") || return 1
  case "$p" in
    */Cellar/*)   printf '%s/\n' "${p%%/Cellar/*}/Cellar/$(printf '%s' "${p#*/Cellar/}" | cut -d/ -f1)" ;;
    */versions/*) printf '%s/\n' "${p%%/versions/*}/versions" ;;
    *)            printf '%s\n' "$p" ;;
  esac
}

# One TSV line per kept event: UTC time, kind, then who. An exit's wait status is decoded
# to "exit N" or "signal N". tmux clients (every probe's tmux call) exit constantly and are
# dropped; a tmux SERVER is the tmux process whose parent is launchd.
FILTER='
def who(p): "\(p.audit_token.pid) (ppid \(p.ppid)) \(p.executable.path)";
def dec(s): if s < 0 then "status ?" elif (s % 128) == 0 then "exit \(((s / 256) | floor) % 256)" else "SIGNAL \(s % 128)" end;
if .event.exit then
  select(((.process.executable.path | test("/tmux$")) | not) or .process.ppid == 1)
  | "\(.time)\tEXIT\t\(who(.process))\t\(dec(.event.exit.stat // -1))"
elif .event.signal then
  "\(.time)\tSIGNAL \(.event.signal.sig)\tfrom \(who(.process))\tto \(who(.event.signal.target))"
else empty end'

_daemon_plist() {  # <name> <raw file> <eslogger args...>
  local name=$1 raw=$2; shift 2
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0"><dict>\n<key>Label</key><string>%s.%s</string>\n' "$LABEL" "$name"
  printf '<key>ProgramArguments</key><array><string>/usr/bin/eslogger</string>'
  local a; for a in "$@"; do printf '<string>%s</string>' "$a"; done
  printf '</array>\n<key>StandardOutPath</key><string>%s</string>\n' "$raw"
  printf '<key>StandardErrorPath</key><string>%s</string>\n' "${raw%.ndjson}.err"
  printf '<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><true/>\n<key>ThrottleInterval</key><integer>30</integer>\n'
  printf '</dict></plist>\n'
}

_agent_plist() {
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0"><dict>\n<key>Label</key><string>%s.reader</string>\n' "$LABEL"
  printf '<key>ProgramArguments</key><array><string>/bin/bash</string><string>%s</string><string>reader</string></array>\n' "$SELF"
  printf '<key>StandardErrorPath</key><string>%s/reader.err</string>\n' "$DIR"
  printf '<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><true/>\n</dict></plist>\n'
}

cmd_install() {
  [ -x /usr/bin/eslogger ] || { echo "es-watch: /usr/bin/eslogger not found (needs macOS 13+)" >&2; return 1; }
  [ -x /usr/bin/jq ] || { echo "es-watch: /usr/bin/jq not found" >&2; return 1; }
  local sel=() c p
  for c in tmux fish claude; do
    p=$(_prefix "$c") && sel+=(--select "$p")
  done
  local app
  for app in /Applications/warden.app; do [ -d "$app" ] && sel+=(--select "$app/"); done
  [ "${#sel[@]}" -gt 0 ] || { echo "es-watch: none of tmux/fish/claude found on PATH" >&2; return 1; }

  mkdir -p "$DIR" "$(dirname "$AGENT_PLIST")"
  : >> "$RAW_EXIT"; : >> "$RAW_SIGNAL"; : >> "$LOG"
  _agent_plist > "$AGENT_PLIST"
  launchctl bootout "gui/$(id -u)/$LABEL.reader" 2>/dev/null
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" || return 1

  local tmp; tmp=$(mktemp -d)
  _daemon_plist exit "$RAW_EXIT" "${sel[@]}" exit > "$tmp/$LABEL.exit.plist"
  _daemon_plist signal "$RAW_SIGNAL" signal > "$tmp/$LABEL.signal.plist"
  echo "es-watch: installing two root daemons (sudo):"
  echo "  exit   → eslogger ${sel[*]} exit"
  echo "  signal → eslogger signal"
  local n
  for n in exit signal; do
    sudo install -m 644 -o root -g wheel "$tmp/$LABEL.$n.plist" "$DAEMON_DIR/$LABEL.$n.plist" || return 1
    sudo launchctl bootout "system/$LABEL.$n" 2>/dev/null
    sudo launchctl bootstrap system "$DAEMON_DIR/$LABEL.$n.plist" || return 1
  done
  rm -rf "$tmp"
  sleep 3
  cmd_status
}

cmd_uninstall() {
  local n
  for n in exit signal; do
    sudo launchctl bootout "system/$LABEL.$n" 2>/dev/null
    sudo rm -f "$DAEMON_DIR/$LABEL.$n.plist"
  done
  launchctl bootout "gui/$(id -u)/$LABEL.reader" 2>/dev/null
  rm -f "$AGENT_PLIST"
  echo "es-watch: removed (log kept at $LOG)"
}

cmd_status() {
  local n err
  for n in exit signal; do
    if pgrep -f "^/usr/bin/eslogger (.* )?$n\$" >/dev/null 2>&1; then
      echo "daemon $n: running"
    else
      echo "daemon $n: NOT running"
    fi
    err="$DIR/raw-$n.err"
    [ -s "$err" ] && echo "  last error: $(tail -1 "$err")"
  done
  if launchctl print "gui/$(id -u)/$LABEL.reader" >/dev/null 2>&1; then echo "reader: loaded"; else echo "reader: NOT loaded"; fi
  echo "raw: $(du -h "$RAW_EXIT" "$RAW_SIGNAL" 2>/dev/null | awk '{printf "%s %s  ", $2, $1}')"
  echo "log: $LOG"
  tail -15 "$LOG" 2>/dev/null
}

cmd_reader() {
  mkdir -p "$DIR"
  : >> "$RAW_EXIT"; : >> "$RAW_SIGNAL"
  tail -n0 -F "$RAW_EXIT" 2>/dev/null \
    | /usr/bin/jq --unbuffered -r "$FILTER" 2>>"$DIR/reader.err" >> "$LOG" &
  tail -n0 -F "$RAW_SIGNAL" 2>/dev/null \
    | /usr/bin/grep --line-buffered -E 'tmux|/fish|/claude/|warden' \
    | /usr/bin/jq --unbuffered -r "$FILTER" 2>>"$DIR/reader.err" >> "$LOG" &
  # Keep the raw files bounded. tail -F re-reads a truncated file from its start, and
  # eslogger appends (O_APPEND), so truncation loses at most the lines written in the
  # instant between tail's last read and the truncate.
  local f sz
  while :; do
    sleep 60
    for f in "$RAW_EXIT" "$RAW_SIGNAL"; do
      sz=$(stat -f %z "$f" 2>/dev/null || echo 0)
      [ "$sz" -gt "$RAW_CAP" ] && : > "$f"
    done
    # a pipeline that died takes the agent down so launchd restarts it whole
    [ "$(jobs -rp | wc -l)" -ge 2 ] || exit 1
  done
}

case "${1:-status}" in
  install)   cmd_install ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  reader)    cmd_reader ;;
  *) sed -n '2,12p' "$0"; exit 2 ;;
esac
