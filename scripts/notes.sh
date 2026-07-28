#!/bin/sh
# notes.sh — per-tab notes in the three summary status rows.
#
# The three rows (status-format[1..3]) show either the LM summary (@amux_rowN,
# pushed by tmux-status.sh) or the user's notes (@amux_noteN), chosen by the
# @amux_notes pane-option flag. This script owns the notes side only; it never
# touches @amux_rowN, so the summary pipeline runs untouched and toggling back
# shows a CURRENT summary rather than a stale one.
#
# Two options per row is deliberate: @amux_note_rawN holds what the user typed
# (the command-prompt prefill source), @amux_noteN holds the escaped, padded
# display value. Escaping in place would make every edit re-escape its own
# output ("fix #42" -> "fix ##42" -> "fix ####42").
#
# HOOK-PATH helper: invoked from a key binding, so $TMUX is inherited and bare
# `tmux` is correct. Do NOT use the CLI-path $(_amux_agent_sock) + `env -u TMUX`
# pattern here — that is for helpers called from the bin/amux process.
#
# Test: NOTES_SELFTEST=1 sh scripts/notes.sh

# Mode indicator, leading row 1 whenever notes mode is on.
NT_MARK='✎ '
# Shown on row 1 when notes mode is on and all three notes are empty. Carries a
# style directive of OUR OWN — added after escaping, never escaped itself.
NT_HINT='#[fg=colour240]✎ click a row to write a note'

# _nt_row <mouse_status_range> -> 1|2|3 on stdout, or nothing.
# tmux sets mouse_status_range to the bare `X` of range=user|X, but accept a
# `user|` prefix too so this cannot break if that ever changes. Anything that
# is not one of our three ranges (a window-list or status-left click) prints
# nothing — the caller treats that as "not a note click" and does nothing.
_nt_row() {
  case "$1" in
    amuxnote1|user\|amuxnote1) printf '1' ;;
    amuxnote2|user\|amuxnote2) printf '2' ;;
    amuxnote3|user\|amuxnote3) printf '3' ;;
    *) : ;;
  esac
}

# _nt_esc <text> -> text with every '#' doubled.
# status-format re-parses the value it substitutes, so an unescaped '#' in a
# note ("fix #42", "PR #7") would be read as a format directive.
_nt_esc() {
  printf '%s' "$1" | sed 's/#/##/g'
}

# _nt_display <row> <raw1> <raw2> <raw3> -> the finished display string.
# All three raws are passed because row 1's content depends on whether ANY note
# exists (the empty-state hint replaces it when none do).
_nt_display() {
  _d_r=$1; _d_1=$2; _d_2=$3; _d_3=$4
  if [ -z "$_d_1" ] && [ -z "$_d_2" ] && [ -z "$_d_3" ]; then
    # Nothing written yet: one dim hint on row 1 so notes mode never looks
    # broken and the rows advertise that they are clickable.
    [ "$_d_r" = 1 ] && printf '%s' "$NT_HINT"
    return 0
  fi
  case "$_d_r" in
    # NT_MARK is prepended AFTER escaping: it is our directive, not user text.
    1) printf '%s%s' "$NT_MARK" "$(_nt_esc "$_d_1")" ;;
    2) _nt_esc "$_d_2" ;;
    3) _nt_esc "$_d_3" ;;
  esac
}

if [ "${NOTES_SELFTEST:-}" = "1" ]; then
  fail=0
  ck() { # ck <label> <got> <want>
    [ "$2" = "$3" ] || { echo "$1 FAIL got[$2] want[$3]" >&2; fail=1; }
  }

  # --- _nt_row: range argument -> row number -------------------------------
  ck row-bare    "$(_nt_row amuxnote2)"      "2"
  ck row-prefix  "$(_nt_row 'user|amuxnote3')" "3"
  ck row-one     "$(_nt_row amuxnote1)"      "1"
  # A click on the window list must NOT parse as a note click.
  ck row-window  "$(_nt_row 'window|@3')"    ""
  # shellcheck disable=SC2016
  ck row-session "$(_nt_row 'session|$0')"   ""
  ck row-empty   "$(_nt_row '')"             ""
  # Only rows 1-3 exist.
  ck row-oob     "$(_nt_row amuxnote9)"      ""
  ck row-junk    "$(_nt_row amuxnoteX)"      ""

  # --- _nt_esc: '#' is doubled, nothing else changes -----------------------
  ck esc-hash    "$(_nt_esc 'fix #42')"      'fix ##42'
  ck esc-multi   "$(_nt_esc 'a#b#c')"        'a##b##c'
  ck esc-none    "$(_nt_esc 'plain text')"   'plain text'
  ck esc-quote   "$(_nt_esc "sam's cert")"   "sam's cert"
  ck esc-empty   "$(_nt_esc '')"             ''

  # --- _nt_display: all three empty -> hint on row 1, others blank ---------
  ck disp-hint1  "$(_nt_display 1 '' '' '')" "$NT_HINT"
  ck disp-hint2  "$(_nt_display 2 '' '' '')" ''
  ck disp-hint3  "$(_nt_display 3 '' '' '')" ''

  # --- _nt_display: any content -> hint gone, mark leads row 1 -------------
  ck disp-r1     "$(_nt_display 1 'deploy blocked' 'ask sam' '')" "${NT_MARK}deploy blocked"
  ck disp-r2     "$(_nt_display 2 'deploy blocked' 'ask sam' '')" 'ask sam'
  ck disp-r3     "$(_nt_display 3 'deploy blocked' 'ask sam' '')" ''
  # Row 1 empty but others filled: mark still shows, so the mode stays visible.
  ck disp-mark   "$(_nt_display 1 '' 'ask sam' '')" "$NT_MARK"
  # Escaping is applied by _nt_display, on user text only.
  ck disp-esc    "$(_nt_display 2 '' 'fix #42' '')" 'fix ##42'
  ck disp-esc1   "$(_nt_display 1 'PR #7' '' '')"   "${NT_MARK}PR ##7"

  # Feeding display output back in DOES double-escape — which is exactly why
  # the raw text is kept in a separate option and _nt_display is only ever
  # given raws. This asserts the hazard is real, so the two-option split can
  # never be "simplified" away without a red test.
  ck disp-reesc  "$(_nt_display 2 '' "$(_nt_display 2 '' 'fix #42' '')" '')" 'fix ####42'

  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

exit 0
