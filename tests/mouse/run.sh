#!/usr/bin/env bash
# run.sh — end-to-end verification that real mouse clicks on the tmux status bar
# drive the notes feature. expect + shell only: no Python, Node, or other
# runtime. Builds an isolated tmux world, drives a genuinely attached client
# through a pty, runs all 10 tests, reaps everything.
#
#   bash tests/mouse/run.sh                      # from anywhere; no arguments
#   AMUX_MOUSE_VERBOSE=1 bash tests/mouse/run.sh # every assertion, not just failures
#   AMUX_MOUSE_BREAK=<guard> bash …/run.sh       # negative-test a guard (see below)
#
# Needs `expect` (a TEST-ONLY dependency, like shellcheck — not a runtime one)
# and `tmux`. `bash test.sh` runs it as one gated check; see tests/mouse/README.md.
#
# Self-contained and idempotent: it derives the repo root from its own location,
# creates every server under a throwaway TMUX_TMPDIR with unique -L labels, and
# leaves nothing behind on any exit path.
#
# WHY expect AND NOT PURE SHELL. The client must be a real pty of a known size:
# `#{client_tty}` in the binding only resolves for a genuinely attached client,
# and the status-row -> screen-line arithmetic needs a known height. Setting a
# pty's window size is exactly what script(1) cannot do; expect's
# `stty rows N cols M < $spawn_out(slave,name)` is the load-bearing line.
#
# SAFETY (a dev box runs real agentmux sessions on the shared socket dir):
#   * every server is created under $WORK, NEVER the shared /tmp/tmux-<uid>/;
#   * -L labels embed $$ so two concurrent runs cannot collide;
#   * AGENTMUX_STATE_DIR is scoped to $WORK/state BEFORE any server starts, so
#     the window-unlinked -> session_log.sh snapshot hook cannot touch the real
#     ledger. Scoping it only "for the tests" is not enough: those writes happen
#     at TEARDOWN (see the cleanup footgun below);
#   * no tmux command in this file or the .exp drivers names a socket other
#     than ours;
#   * the EXIT trap kills both servers and rm -rf's $WORK on every path out.
#
# TRAP GUARD 1 — the wrong-code trap. The binding hardcodes
#   ~/.agentmux/scripts/notes.sh, and on a dev box ~/.agentmux/scripts is a
#   symlink to the INSTALL, so a naive run tests the installed checkout while
#   appearing to test this tree. The conf is rewritten to absolute paths under
#   $ROOT and the rewrite is ASSERTED against `list-keys -T root` before a
#   single test runs.
#
# TRAP GUARD 2 — the no-status-rows trap. `set -g status 5` is silently reverted
#   to `status on` by the client-attached hook -> scripts/update_colors.sh for any
#   session without `@autoagent 1` (the multi-row count is set only by
#   _amux_apply_colour), and drops to 4 without `@amux_note_row 1` (which is what
#   selects five lines over four). With one status line the note rows do not
#   exist and the whole suite would pass nothing while looking busy. Asserted
#   twice: the session option here, and five status lines actually RENDERING on
#   an attached client in main.exp's preflight.
#
# NEGATIVE-TESTING THE GUARDS. AMUX_MOUSE_BREAK deliberately breaks one precondition so
# the guard can be seen to FIRE rather than merely to exist. Four values:
#   rewrite    skip the path rewrite entirely      -> guard 1a (grep) aborts
#   binding    rewrite to a decoy path             -> guard 1b (list-keys) aborts
#   autoagent  skip `set @autoagent 1`             -> guard 2a (session opt) aborts
#   render     pass 2a, then force `status on`     -> guard 2b (preflight) aborts
# Every break must exit 2 with a loud ABORT, and must still reap.

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# tests/mouse/ -> repo root. The two -f checks below catch a wrong depth.
ROOT=$(cd "$HERE/../.." && pwd)
BREAK=${AMUX_MOUSE_BREAK:-}

die() { printf '\n  ABORT: %s\n\n' "$*" >&2; exit 2; }
say() { printf '  %s\n' "$*"; }

# --- preconditions ---------------------------------------------------------
[ -f "$ROOT/tmux/agentmux.conf" ] || die "not a repo root: $ROOT (no tmux/agentmux.conf)"
[ -f "$ROOT/scripts/notes.sh" ]   || die "not a repo root: $ROOT (no scripts/notes.sh)"
command -v tmux   >/dev/null 2>&1 || die "tmux not on PATH"
command -v expect >/dev/null 2>&1 || die "expect not on PATH (the pty driver)"

# The suite clicks through scripts/notes.sh's `command-prompt -l`, which does
# not exist before tmux 3.6 (README Prerequisites) — an older tmux would fail
# every click with a confusing "prompt never opened" symptom instead of this
# one legible abort. The parse/compare is single-sourced in tmux_version.sh
# (test.sh's tests/mouse block uses the same file) so the 3.6 floor lives in
# exactly one place.
. "$ROOT/scripts/tmux_version.sh"
TMUX_RAW=$(tmux -V 2>/dev/null)
_amux_tmux_capable "$TMUX_RAW" \
  || die "needs tmux >= ${_AMUX_TMUX_MIN_MAJOR}.${_AMUX_TMUX_MIN_MINOR} for command-prompt -l, found ${AMUX_TMUX_PARSED} (raw: $TMUX_RAW)"

# --- isolated world --------------------------------------------------------
# Short path on purpose: a long dir plus a socket name can exceed the 104-char
# AF_UNIX limit.
WORK=/tmp/amuxmt$$
SOCK_A=amuxmta$$          # inner / agent server (carries the note bindings)
SOCK_B=amuxmtb$$          # outer / frame server (carries none of them)

case "$WORK" in
  /tmp/tmux-*) die "refusing to run: \$WORK would be the shared socket dir" ;;
esac

_cleaned=0
cleanup() {
  # EXIT-only and idempotent, matching bin/amux's trap shape. bash fires EXIT on
  # an untrapped SIGINT, so this covers Ctrl-C too; adding INT/TERM would let the
  # shell RESUME after the handler and run cleanup twice.
  [ "$_cleaned" = 1 ] && return 0
  _cleaned=1
  TMUX_TMPDIR=$WORK tmux -L "$SOCK_B" kill-server 2>/dev/null
  TMUX_TMPDIR=$WORK tmux -L "$SOCK_A" kill-server 2>/dev/null

  # FOOTGUN: `kill-server` RETURNS BEFORE ITS TEARDOWN HOOKS HAVE RUN. Destroying
  # the windows fires agentmux.conf's `window-unlinked` hook, whose
  # `run-shell "... session_log.sh snapshot ..."` children are forked by the dying
  # server and OUTLIVE both the kill-server call and an immediate `rm -rf`.
  # session_log.sh then `mkdir -p`s $AGENTMUX_STATE_DIR/live ~0.3s later,
  # RE-CREATING the directory just deleted. Measured: kill -> rm -> dir GONE ->
  # +0.3s -> $WORK/state/live is back. A run that reaps immediately therefore
  # strands one dir per run while reporting a clean exit.
  #
  # So: wait for the hook children to exit (they carry $WORK in argv, via
  # #{socket_path}), then delete, then re-check — belt and braces, because the
  # pgrep can only see children that name the socket.
  local i
  for i in $(seq 1 40); do
    pgrep -f "$WORK" >/dev/null 2>&1 || break
    sleep 0.2
  done
  rm -rf "$WORK"
  # shellcheck disable=SC2034  # a bounded retry counter; the body needs no $i
  for i in $(seq 1 10); do
    [ -d "$WORK" ] || break
    sleep 0.3
    rm -rf "$WORK"
  done
}
trap cleanup EXIT

mkdir -p "$WORK/state" || die "cannot create $WORK"
export TMUX_TMPDIR="$WORK"
export AGENTMUX_STATE_DIR="$WORK/state"
unset TMUX

OUT="$HERE/last-run"
rm -rf "$OUT"; mkdir -p "$OUT"
: > "$OUT/results.tsv"

say "repo under test     : $ROOT"
say "throwaway dir       : $WORK"
say "sockets             : $SOCK_A (agent)  $SOCK_B (frame)"
[ -n "$BREAK" ] && say "NEGATIVE TEST       : AMUX_MOUSE_BREAK=$BREAK (a guard MUST abort below)"

# --- build the confs, rewritten to $ROOT -----------------------------------
# mouse/status live in agent.conf + update_colors.sh, not agentmux.conf, so they
# are appended here to reproduce a real agent socket.
case "$BREAK" in
  rewrite) cp "$ROOT/tmux/agentmux.conf" "$WORK/base.conf" ;;
  binding) sed "s#~/.agentmux/scripts/#/tmp/amuxmt-decoy-not-the-worktree/scripts/#g; \
                s#~/.agentmux/tmux/#$ROOT/tmux/#g" \
             "$ROOT/tmux/agentmux.conf" > "$WORK/base.conf" ;;
  *)       sed "s#~/.agentmux/scripts/#$ROOT/scripts/#g; s#~/.agentmux/tmux/#$ROOT/tmux/#g" \
             "$ROOT/tmux/agentmux.conf" > "$WORK/base.conf" ;;
esac
[ -s "$WORK/base.conf" ] || die "conf rewrite failed"
{ printf '\n'
  printf 'set -g mouse on\n'
  printf 'set -g status 5\n'
  printf 'set -g status-keys emacs\n'
} >> "$WORK/base.conf"

sed "s#~/.agentmux/scripts/#$ROOT/scripts/#g; s#~/.agentmux/tmux/#$ROOT/tmux/#g" \
    "$ROOT/tmux/frame.conf" > "$WORK/frame.conf" || die "frame conf rewrite failed"

# GUARD 1a — cheap textual check before a server even starts.
# shellcheck disable=SC2088  # the tilde is LITERAL TEXT we are searching the file for
grep -q '~/\.agentmux' "$WORK/base.conf" && \
  die "rewrite incomplete: base.conf still names ~/.agentmux (the MAIN checkout)"

# --- agent server ----------------------------------------------------------
tmux -L "$SOCK_A" -f "$WORK/base.conf" new-session -d -s test -x 120 -y 30 \
  || die "could not start the agent server"

# GUARD 1b — prove the LIVE binding runs THIS worktree's notes.sh.
KEYS=$(tmux -L "$SOCK_A" list-keys -T root)
case "$KEYS" in
  *"$ROOT/scripts/notes.sh"*) : ;;
  *) printf '%s\n' "$KEYS" | grep -i mousedown1status >&2
     die "MouseDown1Status does NOT point at $ROOT/scripts/notes.sh — every result would be worthless" ;;
esac
case "$KEYS" in
  *'~/.agentmux/scripts/notes.sh'*)
     die "MouseDown1Status still points at ~/.agentmux (the MAIN checkout)" ;;
esac
say "binding asserted    : MouseDown1Status -> \$ROOT/scripts/notes.sh"

# Two windows: test 8 needs an observable window switch.
tmux -L "$SOCK_A" new-window -t test -n second || die "could not create the second window"
PANE=$(tmux -L "$SOCK_A" list-panes -t test:1 -F '#{pane_id}')
[ -n "$PANE" ] || die "could not resolve the target pane"
[ "$PANE" = "%0" ] && die "target pane resolved to %0; tests must run off %0"
say "target pane         : $PANE (deliberately not %0)"

# GUARD 2a — @autoagent 1 is what makes update_colors.sh choose a multi-row
# `status N` over `status on`; @amux_note_row (set below) then picks 5 over 4.
# Part 2 (the render-time assertion) is in main.exp.
[ "$BREAK" = autoagent ] || tmux -L "$SOCK_A" set -t test @autoagent 1
# The fourth agentmux row exists only for a session carrying @amux_note_row —
# bin/amux publishes it from `[notes] row`; here we set it directly, since this
# suite drives tmux, not amux.
tmux -L "$SOCK_A" set -t test @amux_note_row 1
# bin/amux publishes BOTH in the same pre-attach batch: the second is row 4's
# empty-state default, without which a pane nothing has clicked renders the row
# as blank padding (notes.sh's _nt_render is reachable only from a click or
# `prefix N`, neither of which is on the launch path). Reproduce it here the same
# way bin/amux does — by ASKING notes.sh for the string, never restating the
# literal — so the value under test stays single-sourced in scripts/notes.sh.
HINT4=$(sh "$ROOT/scripts/notes.sh" hint 4)
[ -n "$HINT4" ] || die "scripts/notes.sh hint 4 printed nothing — row 4 would have no empty state to assert on"
tmux -L "$SOCK_A" set -t test @amux_note4 "$HINT4"
tmux -L "$SOCK_A" run-shell "$ROOT/scripts/update_colors.sh test"
for _i in 1 2 3 4 5 6 7 8 9 10; do
  ST=$(tmux -L "$SOCK_A" show-options -t test status)
  [ "$ST" = "status 5" ] && break
  sleep 0.2
done
[ "$ST" = "status 5" ] || die "session status is [$ST], not [status 5] — the note rows would not exist"
say "status asserted     : $ST"

# The `render` break passes 2a and then breaks what 2b watches. Note it must
# UNSET @autoagent rather than just `set status on`: the client-attached hook
# re-runs update_colors.sh when main.exp attaches, which would put `status 5`
# straight back for an @autoagent session (with @amux_note_row set above) — so
# a plain `set status on` here is silently undone and negative-tests nothing
# (verified). Unsetting @autoagent makes that same hook choose `status on`,
# which is exactly the real-world trap.
[ "$BREAK" = render ] && tmux -L "$SOCK_A" set -u -t test @autoagent

# --- frame server: an outer tmux with the agent client nested inside it ----
tmux -L "$SOCK_B" -f "$WORK/frame.conf" new-session -d -s frame -x 120 -y 30 \
  "env -u TMUX tmux -L $SOCK_A attach -t test" \
  || die "could not start the frame server"
for _i in $(seq 1 30); do
  tmux -L "$SOCK_B" has-session -t frame 2>/dev/null && break
  sleep 0.2
done
tmux -L "$SOCK_B" has-session -t frame 2>/dev/null || die "frame session did not survive startup"
say "frame server        : agent client nested in one pane"

# --- run the suite ---------------------------------------------------------
printf '\n%s\n' "  ============================================================================"
printf '%s\n'   "   status-bar note clicks — real mouse events through a real pty"
printf '%s\n'   "  ============================================================================"

expect "$HERE/main.exp"  "$ROOT" "$SOCK_A" "$SOCK_B" "$WORK" "$OUT" "$PANE"
rc_main=$?
# exit 2 from main.exp is the render-time half of GUARD 2 firing: five status
# lines did not actually render, so the note rows do not exist and every later
# result would be meaningless. Stop rather than report a table of nothing.
if [ "$rc_main" -eq 2 ]; then
  die "preflight failed — five status lines did not render, or the derived geometry does not hold; the note rows do not exist"
fi
expect "$HERE/frame.exp" "$ROOT" "$SOCK_A" "$SOCK_B" "$WORK" "$OUT" "$PANE"
rc_frame=$?

# --- table -----------------------------------------------------------------
printf '\n%s\n' "  ----------------------------------------------------------------------------"
total=0; failed=0
while IFS=$'\t' read -r n name tag; do
  [ -n "${n:-}" ] || continue
  total=$((total + 1))
  [ "$tag" = FAIL ] && failed=$((failed + 1))
  label=$([ "$n" = 0 ] && echo pre || echo "$n")
  printf '   [%s] %3s  %s\n' "$tag" "$label" "$name"
done < "$OUT/results.tsv"
printf '%s\n' "  ----------------------------------------------------------------------------"
if [ "$total" -lt 11 ]; then
  printf '   %s\n' "INCOMPLETE: only $total of 11 checks reported (a driver aborted early)"
  failed=$((failed + 11 - total))
fi
printf '   %s\n' "$((total - failed))/$total checks passed$([ "$failed" -eq 0 ] || echo "  —  $failed FAILED")"
printf '   %s\n' "transcripts: $OUT/*.pty.log"

rc=0
[ "$rc_main" -ne 0 ] && rc=1
[ "$rc_frame" -ne 0 ] && rc=1
[ "$failed" -ne 0 ] && rc=1

# --- safety re-confirmation (read-only) ------------------------------------
printf '\n  %s\n' "safety re-check"
printf '    shared sockets in /tmp/tmux-%s/ : %s\n' "$(id -u)" \
       "$(ls "/tmp/tmux-$(id -u)/" 2>/dev/null | wc -l | tr -d ' ')"
LEDGER=${XDG_STATE_HOME:-$HOME/.local/state}/agentmux/sessions.jsonl
[ -f "$LEDGER" ] && printf '    real ledger lines               : %s\n' \
       "$(wc -l < "$LEDGER" | tr -d ' ')"
[ -d "$(dirname "$LEDGER")/live" ] && printf '    real live/ entries              : %s\n' \
       "$(ls "$(dirname "$LEDGER")/live" | wc -l | tr -d ' ')"
printf '    throwaway state dir written to  : %s file(s)\n' \
       "$(find "$WORK/state" -type f 2>/dev/null | wc -l | tr -d ' ')"

cleanup
trap - EXIT
printf '    throwaway dir reaped            : %s\n\n' \
       "$([ -d "$WORK" ] && echo NO || echo yes)"
exit "$rc"
