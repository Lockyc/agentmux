#!/usr/bin/env bash
# relaunch.sh — re-launches the agent after a prefix-x pane respawn.
# Arg: <pane_id> — the respawned pane, passed explicitly by the prefix-x binding.
#
# Targeting MUST be explicit. An un-targeted `tmux display-message`/`send-keys`
# resolves against the most recently active CLIENT, so when several agent
# sessions share the default socket the relaunch command was typed into whichever
# agent was last focused — not the pane being respawned. Everything is derived
# from the passed pane with -t queries (mirrors launch_agent.sh).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/amux.toml}"
source "$SCRIPT_DIR/agentmux-config.sh"
source "$SCRIPT_DIR/agent_window_style.sh"

PANE="${1:-}"
[ -n "$PANE" ] || { echo "relaunch.sh: pane_id argument required" >&2; exit 1; }

SESSION=$(tmux display-message -t "$PANE" -p "#S")
WIN=$(tmux display-message -t "$PANE" -p "#{window_id}")

AGENT=$(tmux show-options -v -t "$SESSION" "@agent-mode" 2>/dev/null)
[ -z "$AGENT" ] && AGENT=$(agentmux_first_agent)

idx=$(agentmux_find_by_name "$AGENT")
[ "$idx" = "-1" ] && idx=0

CMD=$(agentmux_build_cmd "$idx")

agentmux_set_window_style "$AGENT" "$WIN"
tmux send-keys -t "$PANE" "$CMD" Enter
