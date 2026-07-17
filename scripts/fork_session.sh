#!/usr/bin/env bash
# fork_session.sh — called by prefix-f to fork the current tab's agent session
# into a new tab. Usage: fork_session.sh <window_id>
#
# The fork COMMAND is not composed here: session_log.sh forkcmd returns whatever
# the agent's adapter recorded (program already swapped per [[agents]] resume).
# That keeps agent syntax out of the core, and means an agent that cannot fork —
# no fork_cmd recorded — no-ops instead of being handed a flag it lacks.
#
# Passing the fork command as the new window's START COMMAND is load-bearing:
# launch_agent.sh's after-new-window hook skips windows opened with an explicit
# pane_start_command, which is what stops it racing a second agent into this pane.
# Same mechanic as _amux_restore_into in bin/amux.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/amux.toml}"

if [ "${FORK_SESSION_SELFTEST:-}" != "1" ]; then
  source "$SCRIPT_DIR/agentmux-config.sh"
  source "$SCRIPT_DIR/agent_window_style.sh"

  WIN="${1:-}"
  [ -n "$WIN" ] || { echo "usage: fork_session.sh <window_id>" >&2; exit 1; }

  FS_TAB=$(printf '\t')
  IFS="$FS_TAB" read -r AGENT FORK_CMD <<EOF
$("$SCRIPT_DIR/session_log.sh" forkcmd "$WIN" 2>/dev/null)
EOF

  if [ -z "${FORK_CMD:-}" ]; then
    tmux display-message -t "$WIN" \
      "amux: nothing to fork — this tab has no forkable agent session"
    exit 0
  fi

  CWD=$(tmux display-message -p -t "$WIN" '#{pane_current_path}' 2>/dev/null)
  [ -n "$CWD" ] || CWD="$HOME"

  if ! NEW=$(tmux new-window -a -t "$WIN" -c "$CWD" -P -F '#{window_id}' "$FORK_CMD"); then
    tmux display-message -t "$WIN" "amux: fork failed — could not create the new window"
    exit 1
  fi
  tmux rename-window -t "$NEW" "$AGENT"
  agentmux_set_window_style "$AGENT" "$NEW"
  # The fork is an ordinary agent tab: log it so it is itself crash-restorable
  # (and itself forkable, once it records its own session).
  "$SCRIPT_DIR/session_log.sh" open "$AGENT" "$NEW" 2>/dev/null || true
  exit 0
fi

# ============================ selftest ============================
# FORK_SESSION_SELFTEST=1 bash scripts/fork_session.sh
#
# Needs NO tmux: a shim `tmux` on PATH records every call and answers the queries
# made both by this script and by session_log.sh's own _sl_ctx. session_log.sh
# runs for real against a seeded ledger.
#
# Deliberately does NOT use SESSION_LOG_CTX to stub the context: that hook is
# target-blind (it returns one canned line whatever -t asks for), so the `open`
# of the NEW window would be recorded against the SOURCE window's id and the
# "logs the fork window" assertion could never pass. Answering _sl_ctx's query
# from the shim, keyed on the -t target, is both the fix and the more faithful
# double — the real _sl_ctx honours its target.
if [ "${FORK_SESSION_SELFTEST:-}" = "1" ]; then
  set -u
  SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fork_session.sh"
  TMPD=$(mktemp -d) || exit 1
  trap 'rm -rf "$TMPD"' EXIT
  pass=0; fail=0
  _assert() {  # <desc> <expected> <actual>
    if [ "$3" = "$2" ]; then pass=$((pass+1)); echo "PASS: $1"
    else fail=$((fail+1)); echo "FAIL: $1 — expected '$2' got '$3'"; fi
  }

  # --- tmux shim: log argv (one call per line), answer the script's queries ---
  mkdir -p "$TMPD/bin"
  cat > "$TMPD/bin/tmux" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TMUX_SHIM_LOG"
# The -t target drives the context answer below, so each caller is answered for
# the window it actually asked about.
_t=""; _prev=""
for _a in "$@"; do [ "$_prev" = "-t" ] && _t="$_a"; _prev="$_a"; done
case "$1" in
  display-message)
    case "$*" in
      *socket_path*)
        # session_log.sh's _sl_ctx context query, answered FOR THE TARGET: that
        # is what lets `open @42` record @42 rather than the source window.
        printf '/s/k\t6001\tproj\t%s\tw\t/tmp/proj\n' "$_t" ;;
      *pane_current_path*)
        # fork_session.sh's own cwd query: -p -t <win> '#{pane_current_path}'
        echo "/tmp/proj" ;;
    esac
    ;;
  new-window) echo "@42" ;;   # -P -F '#{window_id}'
esac
exit 0
SHIM
  chmod +x "$TMPD/bin/tmux"
  PATH="$TMPD/bin:$PATH"; export PATH

  # --- config: agent `work` resumes via claude-work -------------------------
  cat > "$TMPD/amux.toml" <<'CFG'
[[agents]]
name = "work"
cmd = "claude"
resume = "claude-work"
colour = "teal"
CFG
  AGENTMUX_CONFIG="$TMPD/amux.toml"; export AGENTMUX_CONFIG
  AGENTMUX_STATE_DIR="$TMPD/state"; export AGENTMUX_STATE_DIR
  AGENTMUX_SESSION_LOG=1; export AGENTMUX_SESSION_LOG
  mkdir -p "$AGENTMUX_STATE_DIR"

  cat > "$AGENTMUX_STATE_DIR/sessions.jsonl" <<'LEDGER'
{"ts":1,"event":"open","socket_path":"/s/k","server_pid":6001,"window_id":"@1","session":"proj","window_name":"work","cwd":"/tmp/proj","agent":"work"}
{"ts":2,"event":"resume","socket_path":"/s/k","server_pid":6001,"window_id":"@1","label":"uu1","resume_cmd":"claude --resume uu1","fork_cmd":"claude --resume uu1 --fork-session"}
{"ts":3,"event":"open","socket_path":"/s/k","server_pid":6001,"window_id":"@5","session":"proj","window_name":"fresh","cwd":"/tmp/proj","agent":"work"}
LEDGER

  _run() {  # <window_id> — fork from that window; the shim answers per-target
    TMUX_SHIM_LOG="$TMPD/shim.log"; export TMUX_SHIM_LOG
    : > "$TMUX_SHIM_LOG"
    # FORK_SESSION_SELFTEST= is LOAD-BEARING, not tidiness. test.sh runs this
    # selftest as `env FORK_SESSION_SELFTEST=1 …`, which EXPORTS the var — so
    # without clearing it for the child, the child re-enters this selftest and
    # forks another child: an infinite fork bomb that exhausts the per-user
    # process table (see CLAUDE.md; summary_rows.sh was fixed for exactly this).
    # Clearing it makes the child take the real body, which is the point.
    FORK_SESSION_SELFTEST='' bash "$SELF" "$1" >/dev/null 2>&1
  }

  # --- forkable tab: creates the window with fork_cmd as its START COMMAND ---
  _run @1
  _assert "creates the fork window adjacent, with the swapped fork command" "1" \
    "$(grep -c -- "new-window -a -t @1 -c /tmp/proj -P -F #{window_id} claude-work --resume uu1 --fork-session" "$TMPD/shim.log")"
  _assert "names the fork window after the agent" "1" \
    "$(grep -c -- "rename-window -t @42 work" "$TMPD/shim.log")"
  # agentmux_set_window_style issues several set-window-option calls; match the
  # one that carries the agent name, so this asserts a single unambiguous line.
  _assert "styles the fork window as that agent" "1" \
    "$(grep -c -- "set-window-option -t @42 @window-agent work" "$TMPD/shim.log")"
  _assert "does not report a no-op on a forkable tab" "0" \
    "$(grep -c -- "nothing to fork" "$TMPD/shim.log")"
  _assert "logs the fork window as an open agent tab" "1" \
    "$(grep -c '"window_id":"@42"' "$AGENTMUX_STATE_DIR/sessions.jsonl")"

  # --- unforkable tab: reports, creates nothing -----------------------------
  _run @5
  _assert "no session recorded → reports a no-op" "1" \
    "$(grep -c -- "nothing to fork" "$TMPD/shim.log")"
  _assert "no session recorded → creates no window" "0" \
    "$(grep -c -- "new-window" "$TMPD/shim.log")"

  echo "----"; echo "pass=$pass fail=$fail"
  [ "$fail" -eq 0 ]
  exit $?
fi
