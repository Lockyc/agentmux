#!/usr/bin/env bash
# agent_window_style.sh — source this; do not execute directly.
# Sets tmux window-status colours and @window-agent for a named agent.
# Requires agentmux-config.sh to already be sourced.
# Usage: agentmux_set_window_style <agent_name> [target]
#   target: optional tmux -t value (e.g. "mysession:0"); omit for current window.

agentmux_set_window_style() {
  local name="$1" target="${2:-}"
  # No-op outside tmux when no explicit target (e.g. wrapper called from a plain terminal).
  [ -z "${TMUX_PANE:-}" ] && [ -z "$target" ] && return 0

  local idx inactive active
  idx=$(agentmux_find_by_name "$name")
  [ "$idx" = "-1" ] && return 1

  inactive=$(agentmux_agent_field "$idx" colour_inactive)
  active=$(agentmux_agent_field "$idx" colour_active)

  local -a t=()
  [ -n "$target" ] && t=(-t "$target")

  [ -n "$inactive" ] && tmux set-window-option "${t[@]}" window-status-style         "$inactive"
  [ -n "$active"   ] && tmux set-window-option "${t[@]}" window-status-current-style "$active"
  tmux set-window-option "${t[@]}" "@window-agent" "$name"
}

# Self-test: AGENTMUX_STYLE_SELFTEST=1 bash scripts/agent_window_style.sh
if [ "${AGENTMUX_STYLE_SELFTEST:-}" = "1" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$SCRIPT_DIR/agentmux-config.sh"

  pass=0; fail=0
  _assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
      echo "PASS: $desc"; pass=$((pass+1))
    else
      echo "FAIL: $desc — expected '$expected' got '$actual'"; fail=$((fail+1))
    fi
  }

  idx=$(agentmux_find_by_name "work")
  _assert "work colour_inactive" "fg=black,bg=colour30"      "$(agentmux_agent_field "$idx" colour_inactive)"
  _assert "work colour_active"   "fg=black,bg=colour37,bold" "$(agentmux_agent_field "$idx" colour_active)"

  idx=$(agentmux_find_by_name "ollama")
  _assert "ollama colour_inactive" "fg=black,bg=colour208" "$(agentmux_agent_field "$idx" colour_inactive)"

  # Guard: no TMUX_PANE, no target → returns 0 without calling tmux
  TMUX_PANE="" agentmux_set_window_style "work" 2>&1
  _assert "guard no-op exit code" "0" "$?"

  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]
fi
