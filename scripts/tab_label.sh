#!/usr/bin/env bash
# tab_label.sh — returns the tmux tab label for the current window's agent.
# Reads @window-agent, resolves optional `label` field from config (falls back to name).
# Usage: tab_label.sh [base_label]
#   base_label: prefix to use (default: "agent"; tmux-status.sh passes the
#               adapter's AGENTMUX_AGENT_NAME)
#   Output:     "base_label·<label>" if @window-agent is set, else "base_label"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/amux.toml}"
source "$SCRIPT_DIR/agentmux-config.sh"

base="${1:-agent}"
agent=$(tmux show-options -wv -t "$TMUX_PANE" "@window-agent" 2>/dev/null)
[ -z "$agent" ] && printf '%s\n' "$base" && exit 0

idx=$(agentmux_find_by_name "$agent")
if [ "$idx" != "-1" ]; then
  lbl=$(agentmux_agent_field "$idx" label)
  [ -z "$lbl" ] && lbl="$agent"
else
  lbl="$agent"
fi

printf '%s·%s\n' "$base" "$lbl"
