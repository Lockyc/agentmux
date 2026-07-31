#!/usr/bin/env bash
# note_popup.sh — the body of the "you are editing a note" popup.
#
#   bash note_popup.sh <row> [target]
#
# INFORMATIONAL ONLY. It never reads a note, never writes one, and never takes
# part in editing: notes.sh's command-prompt still does all of that, with the
# prefill, the `-l` literal prefill and the `%%%` escaping it already does. This
# window exists so that an UNNOTICED click on a note row is impossible to miss —
# tmux swallows all mouse input while a command-prompt is open, so a click you
# did not mean to make reads as a locked interface.
#
# A SCRIPT, NOT AN INLINE STRING, deliberately: a popup command transits tmux's
# own parser and then a shell, and inline quoting through both silently produced
# a popup that never started in three separate throwaway probes.
#
# IT OPENS BEFORE THE COMMAND-PROMPT, NOT ALONGSIDE IT, and that is forced by
# what a popup actually is. Measured on tmux 3.7b driving a real pty client:
#
#   * A LIVE POPUP TAKES ALL OF THE CLIENT'S INPUT. With one on screen the
#     command-prompt receives nothing, NO root-table binding fires (a pane
#     click, a status-bar click and a plain key each failed to run their
#     binding), and nothing reaches the pane. A popup shown OVER an open prompt
#     therefore eats the note instead of advertising it: typing "abc" then Enter
#     with one up left the note option EMPTY, and the text reached neither the
#     prompt nor the shell.
#   * `tmux command-prompt` BLOCKS ITS CALLER until the prompt is dismissed, so
#     there is no "open the popup on the next line" either — that line does not
#     run until editing is already over.
#   * The prompt SURVIVES a popup. Opening the popup first and the prompt second
#     therefore costs nothing: the prompt opens as the popup goes away, with its
#     prefill intact, and commits normally.
#
# THE HARD RULE IT ENCODES: because a live popup traps the client's input, this
# one must be impossible to strand — a popup nobody can dismiss is a worse
# version of the bug it exists to fix. Two independent exits, and BOTH are
# load-bearing: the next keystroke closes it (the normal path — the trap lasts
# exactly one key, which is consumed here and reaches nothing else), and NP_TTL
# closes it if no key ever arrives (the backstop, for a popup nobody is sitting
# in front of). `display-popup -C` from a mouse binding — the obvious third
# route, and the one that looks best on paper — CANNOT work: no binding of any
# kind fires while the popup is up.
#
# bash, not POSIX sh, and for `read -t <n> -s -n 1` alone: one builtin gives the
# keystroke AND the timeout. The sh equivalent is `stty raw` + `dd bs=1 count=1`
# plus a watchdog subshell, and the watchdog cannot work — a POSIX shell blocked
# on a foreground child defers its traps until that child returns, so the
# watchdog's signal arrives only after the read it was meant to interrupt.
# Measured too: a BACKGROUNDED reader returns immediately with no byte at all.
# bash 3.2 — macOS's stock /bin/bash — has all three flags.
#
# Test: NOTE_POPUP_SELFTEST=1 bash scripts/note_popup.sh
NP_ROW=${1:-?}
# The pane whose SESSION carries @amux_popup. notes.sh passes its already
# resolved, placeholder-free `#{window_id}.#{pane_index}` target; with none, the
# option lands on whatever session tmux resolves for us.
NP_TARGET=${2:-}
# The backstop. Seconds, and it must stay a positive integer: a 0 or empty value
# would make `read -t` return instantly (a popup nobody ever sees) and removes
# the guarantee that this window cannot outlive its own usefulness. Asserted in
# the selftest.
NP_TTL=5

# np_body <row> — the popup's text. A function so the selftest can assert on it
# without opening a popup at all.
#
# It names how it goes away, for the same reason notes.sh's prompt names esc and
# enter: while this is up the keyboard belongs to it, so the way out has to be
# on screen. The other two lines describe the prompt that opens the moment this
# closes — which is why they are in the future tense of the interaction, not a
# description of what the status bar shows right now.
np_body() {
  printf '\n'
  printf '   editing note %s\n' "${1:-$NP_ROW}"
  printf '\n'
  printf '   press any key — then type in the status bar\n'
  printf '\n'
  printf '   enter   save\n'
  printf '   esc     cancel\n'
}

# np_set — @amux_popup at SESSION scope, resolved from NP_TARGET when we were
# given one. Bare `tmux`: this runs INSIDE the popup's own pane, where $TMUX is
# set and resolves to the right server (verified), so it is hook-path code, not
# the CLI path that needs an explicit socket.
np_set() {
  if [ -n "$NP_TARGET" ]; then tmux set-option -t "$NP_TARGET" "$@" 2>/dev/null
  else                         tmux set-option "$@" 2>/dev/null
  fi
}

if [ "${NOTE_POPUP_SELFTEST:-}" = "1" ]; then
  fail=0
  ck() { [ "$2" = "$3" ] || { echo "$1 FAIL got[$2] want[$3]" >&2; fail=1; }; }

  # The body names the row it was GIVEN — not a fixed one, or every popup would
  # claim to be editing the same note.
  ck row-4        "$(np_body 4 | grep -c 'editing note 4')" 1
  ck row-2        "$(np_body 2 | grep -c 'editing note 2')" 1
  ck row-distinct "$([ "$(np_body 1)" != "$(np_body 2)" ] && echo distinct)" distinct
  # It names both exits of the prompt it is announcing.
  ck names-enter  "$(np_body 4 | grep -c 'enter')" 1
  ck names-esc    "$(np_body 4 | grep -c 'esc')"   1
  # And it names its OWN exit. Without this the user is looking at a window that
  # has taken their keyboard and says nothing about giving it back.
  ck names-own    "$(np_body 4 | grep -c 'press any key')" 1
  # THE BACKSTOP MUST EXIST. A non-positive TTL silently removes the only exit
  # that does not depend on someone being at the keyboard.
  ck ttl-positive "$([ "$NP_TTL" -gt 0 ] 2>/dev/null && echo yes)" yes

  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

# Cleared on EVERY exit path, and idempotent so the signal handlers below cannot
# double-run it into something surprising. A stale @amux_popup would tell the
# world a popup is on screen when none is.
_np_done=0
_np_cleanup() {
  [ "$_np_done" = 1 ] && return 0
  _np_done=1
  np_set -u @amux_popup
}
trap '_np_cleanup' EXIT
# Unlike a selftest's cleanup trap (EXIT-only, see CLAUDE.md), the signals matter
# here: tmux tears the popup's pane down with a signal when the popup is closed
# from outside, and the handlers exit rather than returning, so the shell cannot
# resume past them.
trap '_np_cleanup; exit 0' HUP INT TERM

np_set @amux_popup 1
np_body "$NP_ROW"

# The hold. -s so the consumed keystroke is not echoed into the window on its
# way out; -n 1 so ANY key ends it rather than only Enter; -t so it ends anyway.
read -r -s -t "$NP_TTL" -n 1 _np_key
_np_cleanup
exit 0
