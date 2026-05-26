#!/usr/bin/env bash
# agentmux.sh — shell functions for agentmux.
# Source from ~/.zshrc or ~/.bashrc:
#   source ~/.agentmux/shell/agentmux.sh
#
# Required env: AGENTMUX_CONFIG (default: ~/.agentmux/agents.toml)
#               AGENTMUX_SCRIPTS (default: ~/.agentmux/scripts)

AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/agents.toml}"
AGENTMUX_SCRIPTS="${AGENTMUX_SCRIPTS:-$HOME/.agentmux/scripts}"

source "$AGENTMUX_SCRIPTS/agentmux-config.sh"

_amux_default_session_name() {
  basename "$PWD" | tr . _
}

_amux_attach() {
  local name="$1"
  # Use switch-client if our TTY is already a tmux pane (check via list-panes,
  # not $TMUX which is inherited into subprocesses and gives false positives).
  if tmux list-panes -a -F '#{pane_tty}' 2>/dev/null | grep -qF "$(tty 2>/dev/null)"; then
    tmux switch-client -t "$name"
  else
    tmux attach-session -t "$name"
  fi
}

_amux_launch_window0() {
  local session="$1" agent="$2"
  local idx cmd keep_alive reattach

  idx=$(agentmux_find_by_name "$agent")
  [ "$idx" = "-1" ] && return 1

  cmd=$(agentmux_agent_field "$idx" cmd)
  keep_alive=$(agentmux_agent_field "$idx" keep_alive)
  reattach=$(agentmux_agent_field "$idx" reattach)

  if [ "$keep_alive" = "true" ]; then
    if [ "$reattach" = "true" ]; then
      cmd="$cmd; exec reattach-to-user-namespace -l \$SHELL"
    else
      cmd="$cmd; exec \$SHELL"
    fi
  fi

  source "$AGENTMUX_SCRIPTS/agent_window_style.sh"

  tmux rename-window -t "$session:0" "$agent"
  agentmux_set_window_style "$agent" "$session:0"
  tmux send-keys -t "$session:0" "$cmd" Enter
}

# tmc [(-<flag> | <agent_name>)] [session_name]
#
# Creates or attaches a tmux session managed by agentmux.
# Agent selection (in precedence order):
#   -<flag>        flag defined in agents.toml (e.g. -w for flag="w")
#   <agent_name>   exact agent name (e.g. "work")
#   (none)         first agent in config
# Remaining arg (if any) is the session name; defaults to current dir basename.
tmc() {
  local agent_name="" session_arg=""

  if [ $# -gt 0 ]; then
    case "$1" in
      -*)
        local flag="${1#-}"
        local fidx
        fidx=$(agentmux_find_by_flag "$flag")
        if [ "$fidx" != "-1" ]; then
          agent_name=$(agentmux_agent_field "$fidx" name)
        else
          echo "agentmux: unknown flag -$flag" >&2; return 1
        fi
        shift
        ;;
    esac
  fi

  if [ $# -gt 0 ] && [ -z "$agent_name" ]; then
    local nidx
    nidx=$(agentmux_find_by_name "$1")
    if [ "$nidx" != "-1" ]; then
      agent_name="$1"; shift
    fi
  fi

  session_arg="${1:-$(_amux_default_session_name)}"
  [ -z "$agent_name" ] && agent_name=$(agentmux_first_agent)

  local name="$session_arg"

  if ! tmux has-session -t "$name" 2>/dev/null; then
    tmux new-session -d -s "$name" -c "$PWD"
    tmux set-option -t "$name" "@agent-mode" "$agent_name"
    _amux_launch_window0 "$name" "$agent_name"
  else
    tmux set-option -t "$name" "@agent-mode" "$agent_name"
  fi

  tmux set-option -t "$name" "@autoagent" "1"
  _amux_attach "$name"
}

# tm [session_name] — plain tmux session, no agent auto-launch
tm() {
  local name="${1:-$(_amux_default_session_name)}"
  tmux has-session -t "$name" 2>/dev/null || tmux new-session -d -s "$name" -c "$PWD"
  _amux_attach "$name"
}

# Personal wrappers — kept for direct invocation outside tmc sessions.
# These also self-correct the window tab colour when called inside tmux.
claude-work() {
  agentmux_set_window_style work
  CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude "$@"
}

claude-personal() {
  agentmux_set_window_style personal
  CLAUDE_CONFIG_DIR="$HOME/.claude-personal" claude "$@"
}
