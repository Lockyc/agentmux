#!/bin/sh
# frame_reattach.sh — `amux --frame` pane-died hook.
#
# Keeps the frame's two nested-tmux panes alive across an accidental detach. The
# frame passes `C-b` through to the focused pane, so a stray `C-b d` on the agent
# (right) or scratch-terminal (left) pane detaches that inner client and its
# attach process exits. With remain-on-exit on (bin/amux sets it per-pane) the
# pane lingers in an exited state instead of being destroyed and the frame
# reflowing to full width; this hook re-attaches it in place, so the detach is a
# visual no-op. (The optional top scratch shell is a plain shell, not a nested
# tmux client, so it has no detach footgun and is left untagged.)
#
# bin/amux tags each pane with @amux_role so we know how to re-attach:
#   term  — disposable/persistent: always re-attach (its `new-session -A` command
#           just recreates the scratch terminal if it was gone).
#   agent — re-attach ONLY while the agent session is still alive on its socket;
#           a genuine kill leaves the pane dead so the next `amux --frame`
#           rebuilds it (the live-pane staleness check in bin/amux) rather than
#           this resurrecting the session in a loop.
#
# Run from frame.conf via run-shell, so $TMUX points at the FRAME socket: bare
# `tmux` targets the frame; `TMUX= tmux` reaches the agent's (default) socket.
# Arg: <dead-pane-id> (a %-prefixed tmux pane id, never contains spaces).

# tmux on the agent (default) socket. AGENTMUX_AGENT_SOCKET mirrors bin/amux's
# test-isolation override; empty in production = the real default socket.
agent_tmux() {
  # TMUX= scopes an empty TMUX to this one command so tmux talks to the agent's
  # socket, not the frame socket we're invoked under (SC1007: intentional, not a typo).
  if [ -n "${AGENTMUX_AGENT_SOCKET:-}" ]; then
    # shellcheck disable=SC1007
    TMUX= tmux -L "$AGENTMUX_AGENT_SOCKET" "$@"
  else
    # shellcheck disable=SC1007
    TMUX= tmux "$@"
  fi
}

frame_reattach() {
  _pane=$1
  [ -n "$_pane" ] || return 0
  _role=$(tmux display-message -p -t "$_pane" '#{@amux_role}' 2>/dev/null)
  case "$_role" in
    term)
      tmux respawn-pane -t "$_pane" 2>/dev/null
      ;;
    agent)
      # Resolve the frame session from the pane (handles spaces in the name),
      # then strip the -frame suffix to get the agent session.
      _fsess=$(tmux display-message -p -t "$_pane" '#{session_name}' 2>/dev/null)
      [ -n "$_fsess" ] || return 0
      _agent=${_fsess%-frame}
      agent_tmux has-session -t "$_agent" 2>/dev/null && tmux respawn-pane -t "$_pane" 2>/dev/null
      ;;
  esac
}

if [ -n "${FRAME_REATTACH_SELFTEST:-}" ]; then
  fail=0
  # Stubs: `tmux` answers display-message by format and records the respawn
  # target; `agent_tmux`'s has-session result is driven per-case via $_alive.
  tmux() {
    case "$1" in
      display-message)
        case "$5" in
          '#{@amux_role}')   printf '%s' "$_role_val" ;;
          '#{session_name}') printf '%s' "$_sess_val" ;;
        esac ;;
      respawn-pane) _respawned=$3 ;;
    esac
  }
  agent_tmux() { [ -n "$_alive" ]; }

  _role_val=agent; _sess_val=proj-frame; _alive=1; _respawned=
  frame_reattach %7
  [ "$_respawned" = %7 ] || { echo "FAIL: live agent should respawn (got '$_respawned')"; fail=1; }

  _role_val=agent; _sess_val=proj-frame; _alive=; _respawned=
  frame_reattach %7
  [ -z "$_respawned" ] || { echo "FAIL: dead agent must not respawn (got '$_respawned')"; fail=1; }

  _role_val=term; _sess_val=proj-frame; _alive=; _respawned=
  frame_reattach %3
  [ "$_respawned" = %3 ] || { echo "FAIL: term should always respawn (got '$_respawned')"; fail=1; }

  _role_val=; _sess_val=proj-frame; _alive=1; _respawned=
  frame_reattach %9
  [ -z "$_respawned" ] || { echo "FAIL: untagged pane is a no-op (got '$_respawned')"; fail=1; }

  _role_val=agent; _alive=1; _respawned=
  frame_reattach ""
  [ -z "$_respawned" ] || { echo "FAIL: empty pane id is a no-op (got '$_respawned')"; fail=1; }

  # Agent name = frame session minus the -frame suffix (capture has-session's -t).
  agent_tmux() { _captured=$3; return 1; }
  _role_val=agent; _sess_val="My Proj-frame"; _captured=
  frame_reattach %1
  [ "$_captured" = "My Proj" ] || { echo "FAIL: agent name should strip -frame, keep spaces (got '$_captured')"; fail=1; }

  [ "$fail" = 0 ] && echo "frame_reattach.sh selftest OK"
  exit "$fail"
fi

frame_reattach "$1"
