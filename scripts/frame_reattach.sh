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
# bin/amux tags each pane with @amux_role so we know which session to re-attach
# to, and the frame session with @amux_{term,agent}_socket so we know where:
#   term  — session <name>-term on @amux_term_socket.
#   agent — session <name>      on @amux_agent_socket.
# Either way we re-attach ONLY while that session still exists. A genuine kill
# leaves the pane dead so the next `amux --frame` rebuilds it (the live-pane
# staleness check in bin/amux) — and a command that fast-fails (so its session
# never comes up) is likewise left dead rather than respawned in a busy loop.
#
# Run from frame.conf via run-shell, so $TMUX points at the FRAME socket: bare
# `tmux` targets the frame; `TMUX= tmux -L <sock>` reaches another socket.
# Arg: <dead-pane-id> (a %-prefixed tmux pane id, never contains spaces).

# tmux on another socket with TMUX cleared, so it talks to that socket rather
# than the frame socket we're invoked under. An empty socket = the real default
# socket (where the agent lives in production).
sock_tmux() {
  _s=$1; shift
  # TMUX= scopes an empty TMUX to this one command (SC1007: intentional, not a typo).
  if [ -n "$_s" ]; then
    # shellcheck disable=SC1007
    TMUX= tmux -L "$_s" "$@"
  else
    # shellcheck disable=SC1007
    TMUX= tmux "$@"
  fi
}

frame_reattach() {
  _pane=$1
  [ -n "$_pane" ] || return 0
  _role=$(tmux display-message -p -t "$_pane" '#{@amux_role}' 2>/dev/null)
  case "$_role" in agent|term) ;; *) return 0 ;; esac
  # Frame session -> base name (handles spaces), then the role picks the target
  # session name and the socket it lives on.
  _fsess=$(tmux display-message -p -t "$_pane" '#{session_name}' 2>/dev/null)
  [ -n "$_fsess" ] || return 0
  _base=${_fsess%-frame}
  # The socket comes from the frame SESSION's own @amux_{term,agent}_socket option
  # (bin/amux sets both on every `amux --frame`), read back through the dead pane so
  # it resolves pane -> window -> session. NOT from $AGENTMUX_*_SOCKET: amux exports
  # neither (see bin/amux's header — an exported per-project socket leaks into every
  # descendant of the frame), so reading the env here found the agent socket EMPTY and
  # silently probed the default socket, and the term one whatever a stale ancestor had.
  if [ "$_role" = term ]; then
    _sess="${_base}-term"
    _sock=$(tmux display-message -p -t "$_pane" '#{@amux_term_socket}' 2>/dev/null)
  else
    _sess="$_base"
    _sock=$(tmux display-message -p -t "$_pane" '#{@amux_agent_socket}' 2>/dev/null)
  fi
  # Exact-match (`=`): tmux resolves a bare `-t name` by prefix/fnmatch too, so a
  # killed agent whose name is a prefix of another live session would falsely read
  # as alive and get resurrected — defeating the no-resurrection guarantee.
  if sock_tmux "$_sock" has-session -t "=$_sess" 2>/dev/null; then
    tmux respawn-pane -t "$_pane" 2>/dev/null
  fi
}

if [ -n "${FRAME_REATTACH_SELFTEST:-}" ]; then
  fail=0
  # No AGENTMUX_*_SOCKET scrubbing needed: the sockets come from the frame session's
  # own options now, so the ambient environment of a maintainer running this from
  # inside a live amux frame can no longer reach the assertions below.
  # Stubs: `tmux` answers display-message by format and records the respawn
  # target; `sock_tmux` records the socket/session it was asked about and
  # answers has-session per-case via $_alive.
  tmux() {
    case "$1" in
      display-message)
        case "$5" in
          '#{@amux_role}')          printf '%s' "$_role_val" ;;
          '#{session_name}')        printf '%s' "$_sess_val" ;;
          '#{@amux_term_socket}')   printf '%s' "$_term_sock_val" ;;
          '#{@amux_agent_socket}')  printf '%s' "$_agent_sock_val" ;;
        esac ;;
      respawn-pane) _respawned=$3 ;;
    esac
  }
  sock_tmux() { _q_sock=$1; _q_sess=$4; [ -n "$_alive" ]; }
  _term_sock_val=agentmux-term-42; _agent_sock_val=agentmux-agent-42

  # agent + alive -> respawn, checked on the session's OWN agent socket (the sharded
  # one from @amux_agent_socket, never the default socket), session=base
  _role_val=agent; _sess_val=proj-frame; _alive=1; _respawned=; _q_sock=x; _q_sess=
  frame_reattach %7
  { [ "$_respawned" = %7 ] && [ "$_q_sock" = agentmux-agent-42 ] && [ "$_q_sess" = =proj ]; } \
    || { echo "FAIL: live agent respawn on the session's agent socket (resp='$_respawned' sock='$_q_sock' sess='$_q_sess')"; fail=1; }

  # agent + dead -> no respawn (no resurrection)
  _role_val=agent; _sess_val=proj-frame; _alive=; _respawned=
  frame_reattach %7
  [ -z "$_respawned" ] || { echo "FAIL: dead agent must not respawn (got '$_respawned')"; fail=1; }

  # A frame session predating the options (option unset -> empty) degrades to the
  # default socket rather than erroring; nothing is resurrected there, so the worst
  # case is a pane left dead until the next `amux --frame` rebuild.
  _role_val=agent; _sess_val=proj-frame; _alive=1; _respawned=; _q_sock=x
  _agent_sock_val=
  frame_reattach %7
  [ -z "$_q_sock" ] || { echo "FAIL: absent @amux_agent_socket must fall back to the default socket (got '$_q_sock')"; fail=1; }
  _agent_sock_val=agentmux-agent-42

  # term + alive -> respawn, checked on the term socket, session=base-term (spaces kept)
  _role_val=term; _sess_val="My Proj-frame"; _alive=1; _respawned=; _q_sock=; _q_sess=
  frame_reattach %3
  { [ "$_respawned" = %3 ] && [ "$_q_sock" = agentmux-term-42 ] && [ "$_q_sess" = "=My Proj-term" ]; } \
    || { echo "FAIL: live term respawn on term socket (resp='$_respawned' sock='$_q_sock' sess='$_q_sess')"; fail=1; }

  # term + dead (killed or fast-failed) -> no respawn (busy-loop guard)
  _role_val=term; _sess_val=proj-frame; _alive=; _respawned=
  frame_reattach %3
  [ -z "$_respawned" ] || { echo "FAIL: dead term must not respawn (got '$_respawned')"; fail=1; }

  # untagged pane -> no-op
  _role_val=; _sess_val=proj-frame; _alive=1; _respawned=
  frame_reattach %9
  [ -z "$_respawned" ] || { echo "FAIL: untagged pane is a no-op (got '$_respawned')"; fail=1; }

  # empty pane id -> no-op
  _role_val=agent; _alive=1; _respawned=
  frame_reattach ""
  [ -z "$_respawned" ] || { echo "FAIL: empty pane id is a no-op (got '$_respawned')"; fail=1; }

  [ "$fail" = 0 ] && echo "frame_reattach.sh selftest OK"
  exit "$fail"
fi

frame_reattach "$1"
