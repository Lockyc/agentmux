#!/usr/bin/env bash
# cycle_mode.sh — called by prefix-m to cycle @agent-mode for a session.
# Usage: cycle_mode.sh <session_id>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/agents.toml}"
source "$SCRIPT_DIR/agentmux-config.sh"
source "$SCRIPT_DIR/agent_window_style.sh"

SESSION_ID="$1"
[ -z "$SESSION_ID" ] && { echo "usage: cycle_mode.sh <session_id>" >&2; exit 1; }

CURRENT=$(tmux show-options -v -t "$SESSION_ID" "@agent-mode" 2>/dev/null)
[ -z "$CURRENT" ] && CURRENT=$(agentmux_first_agent)

NEXT=$(agentmux_next_agent "$CURRENT")

tmux set-option -t "$SESSION_ID" "@agent-mode" "$NEXT"
# By design, repaints only the current window's status-bar style: each window
# stays locked to whatever agent it was launched with (set by launch_agent.sh /
# amux on creation). @agent-mode is the session-wide setting that controls
# which agent the *next* prefix-c window will spawn.
agentmux_set_window_style "$NEXT"
tmux refresh-client -S
