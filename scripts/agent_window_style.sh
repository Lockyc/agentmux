#!/usr/bin/env bash
# agent_window_style.sh — source this; do not execute directly.
# Sets tmux window-status colours and @window-agent for a named agent.
# Requires agentmux-config.sh to already be sourced.
# Usage: agentmux_set_window_style <agent_name> [target] [socket]
#   target: optional tmux -t value (e.g. "mysession:0"); omit for current window.
#   socket: optional tmux -L socket. Callers running INSIDE the agent tmux server
#           (the after-new-window hook → launch_agent.sh) inherit the correct
#           $TMUX and omit it. A caller OUTSIDE that server — bin/amux styling
#           window 0 (or a restored window) before it has attached — has no
#           ambient $TMUX pointing at the (possibly sharded) agent socket, so a
#           bare `tmux -t <target>` falls back to the literal "default" socket and
#           silently styles nothing there. Pass the resolved agent socket to force
#           the right one (-L overrides any inherited $TMUX; env -u TMUX is
#           belt-and-suspenders, matching _amux_atmux / session_log.sh's _sl_ctx).

# colour_derive lives here; sourced for the friendly `colour` field fallback.
# Sourcing is a no-op CLI-wise: colours.sh only dispatches when executed directly.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/colours.sh"

agentmux_set_window_style() {
  local name="$1" target="${2:-}" sock="${3:-}"
  # No-op outside tmux when no explicit target (e.g. wrapper called from a plain terminal).
  [ -z "${TMUX_PANE:-}" ] && [ -z "$target" ] && return 0

  # A passed socket forces the target server (see the header): bin/amux styles
  # window 0 / restored windows from a process with no ambient $TMUX pointing at
  # the sharded agent socket, so a bare `tmux` would land on the default socket.
  # Hook callers omit it and use the inherited $TMUX.
  local -a tx=(tmux)
  [ -n "$sock" ] && tx=(env -u TMUX tmux -L "$sock")

  local idx inactive active
  idx=$(agentmux_find_by_name "$name")
  [ "$idx" = "-1" ] && return 1

  inactive=$(agentmux_agent_field "$idx" colour_inactive)
  active=$(agentmux_agent_field "$idx" colour_active)
  # Raw fields are a pair: derivation only kicks in when BOTH are absent, so a
  # lone raw field silently leaves one window state unstyled AND shadows `colour`.
  # Warn rather than fail quietly.
  if { [ -n "$inactive" ] && [ -z "$active" ]; } || { [ -z "$inactive" ] && [ -n "$active" ]; }; then
    echo "agentmux: agent '$name' sets only one of colour_inactive/colour_active — set both as a pair, or use 'colour' for auto-derived shades." >&2
  fi
  # Raw fields win; otherwise derive both shades from the friendly `colour` base.
  if [ -z "$inactive" ] && [ -z "$active" ]; then
    local base derived
    base=$(agentmux_agent_field "$idx" colour)
    if [ -n "$base" ] && derived=$(colour_derive "$base"); then
      inactive=$(printf '%s\n' "$derived" | sed -n 1p)
      active=$(printf '%s\n'  "$derived" | sed -n 2p)
    fi
  fi

  local -a t=()
  [ -n "$target" ] && t=(-t "$target")

  [ -n "$inactive" ] && "${tx[@]}" set-window-option "${t[@]}" window-status-style         "$inactive"
  [ -n "$active"   ] && "${tx[@]}" set-window-option "${t[@]}" window-status-current-style "$active"
  "${tx[@]}" set-window-option "${t[@]}" window-status-format         " #I: #W "
  "${tx[@]}" set-window-option "${t[@]}" window-status-current-format "[#I: #W]"
  "${tx[@]}" set-window-option "${t[@]}" "@window-agent" "$name"
}

# Self-test: AGENTMUX_STYLE_SELFTEST=1 bash scripts/agent_window_style.sh
if [ "${AGENTMUX_STYLE_SELFTEST:-}" = "1" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  export AGENTMUX_CONFIG="$SCRIPT_DIR/../config/amux.toml.example"
  source "$SCRIPT_DIR/agentmux-config.sh"
  _amux_json_cache=""

  pass=0; fail=0
  _assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
      echo "PASS: $desc"; pass=$((pass+1))
    else
      echo "FAIL: $desc — expected '$expected' got '$actual'"; fail=$((fail+1))
    fi
  }

  # Friendly `colour` base derives the inactive shade via colour_derive.
  idx=$(agentmux_find_by_name "ollama")
  _assert "ollama colour field" "orange" "$(agentmux_agent_field "$idx" colour)"
  _assert "ollama derived inactive" "fg=colour16,bg=colour215" \
    "$(colour_derive "$(agentmux_agent_field "$idx" colour)" | sed -n 1p)"

  # Raw fields still take precedence and are read verbatim.
  idx=$(agentmux_find_by_name "opencode")
  _assert "opencode raw inactive" "fg=black,bg=colour54"      "$(agentmux_agent_field "$idx" colour_inactive)"
  _assert "opencode raw active"   "fg=black,bg=colour99,bold" "$(agentmux_agent_field "$idx" colour_active)"

  # Guard: no TMUX_PANE, no target → returns 0 without calling tmux
  TMUX_PANE="" agentmux_set_window_style "work" 2>&1
  _assert "guard no-op exit code" "0" "$?"

  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]
fi
