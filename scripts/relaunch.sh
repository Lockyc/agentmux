#!/usr/bin/env bash
# relaunch.sh — re-launches the agent after a prefix-x pane respawn.
# Arg: <pane_id> — the respawned pane, passed explicitly by the prefix-x binding.
#
# Targeting MUST be explicit. An un-targeted `tmux display-message`/`send-keys`
# resolves against the most recently active CLIENT, so when a project's agent tmux
# server hosts several windows/clients the relaunch command was typed into whichever
# agent was last focused — not the pane being respawned. Everything is derived
# from the passed pane with -t queries (mirrors launch_agent.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/amux.toml}"
source "$SCRIPT_DIR/agentmux-config.sh"
source "$SCRIPT_DIR/agent_window_style.sh"

# ============================ selftest ============================
# RELAUNCH_SELFTEST=1 bash scripts/relaunch.sh
# Drives a REAL tmux server: the bug is tmux's own respawn-pane semantics
# (no shell-command → re-run the pane's original start command), which a stub
# would not reproduce. Own short TMUX_TMPDIR (AF_UNIX 104-char limit) with an
# EXIT trap, mirroring session_log.sh's real-tmux block.
if [ "${RELAUNCH_SELFTEST:-}" = "1" ]; then
  # Clear the marker before anything spawns a child — test.sh passes it as an
  # EXPORTED var, so the real tmux server started below would otherwise inherit
  # it and any later re-entry of this script from that server would run the
  # selftest instead of the relaunch. Same invariant as session_log.sh's.
  unset RELAUNCH_SELFTEST
  command -v tmux >/dev/null 2>&1 || { echo "SKIP: relaunch selftest (tmux not found)"; exit 0; }
  command -v toml2json >/dev/null 2>&1 || { echo "SKIP: relaunch selftest (toml2json not found)"; exit 0; }
  _rl_dir="/tmp/rltest-$$"; mkdir -p "$_rl_dir" || exit 1
  export TMUX_TMPDIR="$_rl_dir"
  trap 'tmux -L rlselftest kill-server 2>/dev/null; rm -rf "$_rl_dir"' EXIT
  pass=0; fail=0
  _assert() { if [ "$3" = "$2" ]; then pass=$((pass+1)); echo "PASS: $1"
              else fail=$((fail+1)); echo "FAIL: $1 — expected '$2' got '$3'"; fi; }

  _rl_resumed="$_rl_dir/resumed"; _rl_fresh="$_rl_dir/fresh"
  export AGENTMUX_CONFIG="$_rl_dir/amux.toml"
  cat > "$AGENTMUX_CONFIG" <<TOML
[[agents]]
name = "work"
cmd  = "touch $_rl_fresh"
TOML

  # A tab created WITH a start command — exactly how _amux_restore_into and
  # fork_session.sh create restored/forked tabs (the resume line as the pane's
  # start command, which is what suppresses launch_agent.sh's auto-launch).
  # -f /dev/null: hermetic. Without it the server loads the user's ~/.tmux.conf
  # → agentmux.conf, whose after-new-window hook would fire launch_agent.sh and
  # actually start an agent inside this test's throwaway server.
  tmux -L rlselftest -f /dev/null new-session -d -s rl -c /tmp \
    "sh -c 'touch $_rl_resumed; sleep 30'" 2>/dev/null
  tmux -L rlselftest set-option -t rl "@autoagent" 1 2>/dev/null
  tmux -L rlselftest set-option -t rl "@agent-mode" work 2>/dev/null
  _rl_pane=$(tmux -L rlselftest display-message -p -t rl '#{pane_id}' 2>/dev/null)
  _rl_i=0; while [ ! -f "$_rl_resumed" ] && [ "$_rl_i" -lt 40 ]; do _rl_i=$((_rl_i+1)); sleep 0.05; done
  _assert "setup: the start command ran once" "1" "$([ -f "$_rl_resumed" ] && echo 1 || echo 0)"

  # Clear both markers, then relaunch: the OLD start command must NOT run again
  # (the regression), and the configured agent command MUST.
  #
  # Invoke it the way the prefix-x binding does — `run-shell` INSIDE the server —
  # not as a bare subprocess. relaunch.sh uses bare `tmux`, which resolves via the
  # $TMUX that run-shell inherits from the server; run from outside, that same
  # `tmux` talks to a different (or newly started) server, and the test passes or
  # fails on a pane that isn't the one under test.
  rm -f "$_rl_resumed" "$_rl_fresh"
  tmux -L rlselftest run-shell \
    "RELAUNCH_SELFTEST= bash '$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")' $_rl_pane" 2>/dev/null
  _rl_i=0; while [ ! -f "$_rl_fresh" ] && [ "$_rl_i" -lt 60 ]; do _rl_i=$((_rl_i+1)); sleep 0.05; done

  _assert "relaunch does NOT re-run the tab's resume start command" "0" \
    "$([ -f "$_rl_resumed" ] && echo 1 || echo 0)"
  _assert "relaunch DOES launch the configured agent command" "1" \
    "$([ -f "$_rl_fresh" ] && echo 1 || echo 0)"

  tmux -L rlselftest kill-server 2>/dev/null
  echo "----"; echo "relaunch selftest: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  exit $?
fi

PANE="${1:-}"
[ -n "$PANE" ] || { echo "relaunch.sh: pane_id argument required" >&2; exit 1; }

SESSION=$(tmux display-message -t "$PANE" -p "#S")
WIN=$(tmux display-message -t "$PANE" -p "#{window_id}")

# THE RESPAWN LIVES HERE, and must always name an explicit command.
# `respawn-pane` with no shell-command re-runs the pane's ORIGINAL start command,
# and a RESTORED or FORKED tab's start command is the agent's resume line
# (`claude --resume <id>` — that is how those tabs suppress launch_agent.sh's
# auto-launch). So a bare `respawn-pane -k` brought back the very session you just
# closed, instead of the fresh agent the send-keys below launches — and only on
# tabs that came from a crash restore or a `prefix f` fork, which is why an
# ordinary tab relaunches correctly and looks like proof the path is fine.
# Respawn into a fresh shell instead, so every tab rebuilds identically.
# Mirror tmux's own default-pane semantics: default-command when set, else the
# default-shell as a LOGIN shell (bare `<shell>` would skip .zprofile-style files
# that a user's PATH may depend on).
RESPAWN_CMD=$(tmux show -gv default-command 2>/dev/null)
if [ -z "$RESPAWN_CMD" ]; then
  RESPAWN_SHELL=$(tmux show -gv default-shell 2>/dev/null)
  RESPAWN_CMD="${RESPAWN_SHELL:-/bin/sh} -l"
fi
tmux respawn-pane -k -t "$PANE" "$RESPAWN_CMD"

AGENT=$(tmux show-options -v -t "$SESSION" "@agent-mode" 2>/dev/null)
[ -z "$AGENT" ] && AGENT=$(agentmux_first_agent)

idx=$(agentmux_find_by_name "$AGENT")
[ "$idx" = "-1" ] && idx=0

CMD=$(agentmux_build_cmd "$idx")

agentmux_set_window_style "$AGENT" "$WIN"
tmux send-keys -t "$PANE" "$CMD" Enter
