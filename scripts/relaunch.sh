#!/usr/bin/env bash
# relaunch.sh — re-launches the correct agent after a prefix-x pane respawn.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/agents.toml}"
source "$SCRIPT_DIR/agentmux-config.sh"
source "$SCRIPT_DIR/agent_window_style.sh"

SESSION=$(tmux display-message -p "#S")
WIN=$(tmux display-message -p "#{window_id}")
AGENT=$(tmux show-options -v -t "$SESSION" "@agent-mode" 2>/dev/null)
[ -z "$AGENT" ] && AGENT=$(agentmux_first_agent)

idx=$(agentmux_find_by_name "$AGENT")
[ "$idx" = "-1" ] && idx=0

CMD=$(agentmux_build_cmd "$idx")

agentmux_set_window_style "$AGENT" "$WIN"
tmux send-keys "$CMD" Enter
