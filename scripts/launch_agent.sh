#!/usr/bin/env bash
# launch_agent.sh — tmux after-new-window hook.
# Auto-launches the configured agent in new windows of @autoagent=1 sessions.
# Window 0 is handled by tmc directly (after-new-window doesn't fire for new-session).
# Args: <window_id> <pane_id> (format strings expanded by tmux before shell runs)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/agents.toml}"
source "$SCRIPT_DIR/agentmux-config.sh"
source "$SCRIPT_DIR/agent_window_style.sh"

HOOK_WIN="${1:-}"
HOOK_PANE="${2:-}"
tw=(); [ -n "$HOOK_WIN" ]  && tw=(-t "$HOOK_WIN")
tp=(); [ -n "$HOOK_PANE" ] && tp=(-t "$HOOK_PANE")

SESSION=$(tmux display-message -p "${tw[@]}" "#S" 2>/dev/null)

[ "$(tmux show-options -v -t "$SESSION" "@autoagent" 2>/dev/null)" = "1" ] || exit 0

# Skip windows opened with an explicit command (self-managed apps).
# pane_start_command is race-free (fixed at creation); pane_current_command is not.
# pane_start_command is double-quoted when it contains spaces; strip one surrounding pair.
START_CMD=$(tmux display-message -p "${tp[@]}" "#{pane_start_command}")
START_CMD="${START_CMD#\"}"; START_CMD="${START_CMD%\"}"
[ -z "$START_CMD" ] || [ "$START_CMD" = "$(tmux show -gv default-command)" ] || exit 0

AGENT=$(tmux show-options -v -t "$SESSION" "@agent-mode" 2>/dev/null)
# Default to first agent if @agent-mode unset
[ -z "$AGENT" ] && AGENT=$(agentmux_first_agent)

idx=$(agentmux_find_by_name "$AGENT")
if [ "$idx" = "-1" ]; then
  AGENT=$(agentmux_first_agent)
  idx=0
fi

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

tmux rename-window "${tw[@]}" "$AGENT"
agentmux_set_window_style "$AGENT" "$HOOK_WIN"
tmux send-keys "${tp[@]}" "$CMD" Enter
