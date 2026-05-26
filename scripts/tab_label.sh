#!/bin/sh
# tab_label.sh — returns the tmux tab label for the current window's agent.
# Reads @window-agent from the current pane's window.
# Usage: tab_label.sh [base_label]
#   base_label: prefix to use (default: "claude")
#   Output:     "base_label·<agent>" if @window-agent is set, else "base_label"
#
# Call from Claude Code hooks to get an agentmux-aware tab label.

base="${1:-claude}"
agent=$(tmux show-options -wv -t "$TMUX_PANE" "@window-agent" 2>/dev/null)
[ -n "$agent" ] && printf '%s·%s\n' "$base" "$agent" || printf '%s\n' "$base"
