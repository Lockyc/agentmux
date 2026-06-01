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
# to and on which socket:
#   term  — session <name>-term on the term socket ($AGENTMUX_TERM_SOCKET).
#   agent — session <name>     on the agent (default) socket.
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
  if [ "$_role" = term ]; then
    _sess="${_base}-term"; _sock="${AGENTMUX_TERM_SOCKET:-agentmux-term}"
  else
    _sess="$_base";        _sock="${AGENTMUX_AGENT_SOCKET:-}"
  fi
  if sock_tmux "$_sock" has-session -t "$_sess" 2>/dev/null; then
    tmux respawn-pane -t "$_pane" 2>/dev/null
  fi
}

if [ -n "${FRAME_REATTACH_SELFTEST:-}" ]; then
  fail=0
  # Stubs: `tmux` answers display-message by format and records the respawn
  # target; `sock_tmux` records the socket/session it was asked about and
  # answers has-session per-case via $_alive.
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
  sock_tmux() { _q_sock=$1; _q_sess=$4; [ -n "$_alive" ]; }

  # agent + alive -> respawn, checked on the default socket (empty), session=base
  _role_val=agent; _sess_val=proj-frame; _alive=1; _respawned=; _q_sock=x; _q_sess=
  frame_reattach %7
  { [ "$_respawned" = %7 ] && [ -z "$_q_sock" ] && [ "$_q_sess" = proj ]; } \
    || { echo "FAIL: live agent respawn on default socket (resp='$_respawned' sock='$_q_sock' sess='$_q_sess')"; fail=1; }

  # agent + dead -> no respawn (no resurrection)
  _role_val=agent; _sess_val=proj-frame; _alive=; _respawned=
  frame_reattach %7
  [ -z "$_respawned" ] || { echo "FAIL: dead agent must not respawn (got '$_respawned')"; fail=1; }

  # term + alive -> respawn, checked on the term socket, session=base-term (spaces kept)
  _role_val=term; _sess_val="My Proj-frame"; _alive=1; _respawned=; _q_sock=; _q_sess=
  frame_reattach %3
  { [ "$_respawned" = %3 ] && [ "$_q_sock" = agentmux-term ] && [ "$_q_sess" = "My Proj-term" ]; } \
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
