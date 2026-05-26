#!/usr/bin/env bash
# relaunch.sh — re-launches the correct agent after a prefix-x pane respawn.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/agents.toml}"
source "$SCRIPT_DIR/agentmux-config.sh"

SESSION=$(tmux display-message -p "#S")
AGENT=$(tmux show-options -v -t "$SESSION" "@agent-mode" 2>/dev/null)
[ -z "$AGENT" ] && AGENT=$(agentmux_first_agent)

idx=$(agentmux_find_by_name "$AGENT")
[ "$idx" = "-1" ] && idx=0

CMD=$(agentmux_agent_field "$idx" cmd)
KEEP_ALIVE=$(agentmux_agent_field "$idx" keep_alive)
REATTACH=$(agentmux_agent_field "$idx" reattach)

if [ "$KEEP_ALIVE" = "true" ]; then
  if [ "$REATTACH" = "true" ]; then
    CMD="$CMD; exec reattach-to-user-namespace -l \$SHELL"
  else
    CMD="$CMD; exec \$SHELL"
  fi
fi

tmux send-keys "$CMD" Enter
