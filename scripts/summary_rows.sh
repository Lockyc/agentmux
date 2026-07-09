#!/bin/sh
# summary_rows.sh --stdin <row 1|2|3> [width]
# Pure render helper: renders ONE done/now/next status row from content on stdin.
# tmux-status.sh (the writer) calls this per row and pushes the result into an
# @amux_rowN pane option that the status bar reads statically — the display is
# event-driven (pushed), not a tmux #() poll. This script no longer reads any
# file or the tmux socket; that was the old polled reader, now removed.
# Format produced by summarise.sh stand mode: "<subject>. done: …; now: …; next: …"
#   row 1 = "<subject>. done: …"  (everything before " now:")
#   row 2 = "now: …"              (between " now:" and " next:")
#   row 3 = "next: …"             (from " next:" to end)
# Each row is trimmed and clipped to <width> with a trailing "…" if it overflows;
# the writer passes a large width (9999) so nothing is clipped here and tmux
# clips the rendered line to the terminal width instead. Missing fields print a
# blank row; text with no " now:"/" next:" marker lands whole on row 1, 2/3 blank.
# '#' is escaped to '##' (tmux re-parses format directives). Always exits 0.
# Content is the lowercase ASCII set _clean_para emits, so substr == columns.
# Test: SUMMARY_ROWS_SELFTEST=1.

# _render <content> <row> <width> -> the row's field, trimmed/clipped/escaped.
_render() {
  awk -v r="$2" -v w="$3" -v s="$1" '
    function clip(t,   cut, sp) {
      sub(/^[ ;]+/, "", t); sub(/[ ;]+$/, "", t)
      if (length(t) > w) {
        cut = substr(t, 1, w - 1)
        sp = cut
        sub(/[^ ]*$/, "", sp)   # drop the trailing partial word
        sub(/ +$/, "", sp)      # and the space before it
        if (length(sp) > 0) cut = sp   # else: single token > width, keep hard cut
        t = cut "…"
      }
      gsub(/#/, "##", t)
      return t
    }
    BEGIN {
      xi = index(s, " next:")
      if (xi > 0) { nextf = substr(s, xi + 1); head2 = substr(s, 1, xi - 1) }
      else        { nextf = "";                head2 = s }
      ni = index(head2, " now:")
      if (ni > 0) { nowf = substr(head2, ni + 1); head1 = substr(head2, 1, ni - 1) }
      else        { nowf = "";                    head1 = head2 }
      if (r == 1) o = head1; else if (r == 2) o = nowf; else o = nextf
      o = clip(o)
      if (o != "") printf "%s", o
    }'
}

if [ "${SUMMARY_ROWS_SELFTEST:-}" = "1" ]; then
  fail=0
  s="billing soft delete migration. done: edited models.py, wrote backfill.py; now: add proration tests; next: fix and rerun"
  got=$(_render "$s" 1 200)
  [ "$got" = "billing soft delete migration. done: edited models.py, wrote backfill.py" ] || { echo "lt1 FAIL [$got]" >&2; fail=1; }
  got=$(_render "$s" 2 200)
  [ "$got" = "now: add proration tests" ] || { echo "lt2 FAIL [$got]" >&2; fail=1; }
  got=$(_render "$s" 3 200)
  [ "$got" = "next: fix and rerun" ] || { echo "lt3 FAIL [$got]" >&2; fail=1; }

  # Missing next -> row 3 blank; done present on row 1.
  s2="subj. done: x; now: y"
  [ "$(_render "$s2" 3 200)" = "" ] || { echo "lt4 FAIL [$(_render "$s2" 3 200)]" >&2; fail=1; }
  [ "$(_render "$s2" 1 200)" = "subj. done: x" ] || { echo "lt5 FAIL [$(_render "$s2" 1 200)]" >&2; fail=1; }

  # Missing done -> row 1 is just the subject; now on row 2.
  s3="subj. now: exploring options."
  [ "$(_render "$s3" 1 200)" = "subj." ] || { echo "lt6 FAIL [$(_render "$s3" 1 200)]" >&2; fail=1; }
  [ "$(_render "$s3" 2 200)" = "now: exploring options." ] || { echo "lt7 FAIL [$(_render "$s3" 2 200)]" >&2; fail=1; }

  # No markers at all -> whole line on row 1, rows 2/3 blank.
  s4="just a bare subject phrase"
  [ "$(_render "$s4" 1 200)" = "just a bare subject phrase" ] || { echo "lt8 FAIL [$(_render "$s4" 1 200)]" >&2; fail=1; }
  [ "$(_render "$s4" 2 200)" = "" ] || { echo "lt9 FAIL" >&2; fail=1; }

  # Clip at the last word boundary within width-1, then "…".
  got=$(_render "aaaaaaaaaa bbbbbbbbbb cccccccccc. now: x" 1 12)
  [ "$got" = "aaaaaaaaaa…" ] || { echo "lt10 FAIL clip [$got]" >&2; fail=1; }
  got=$(_render "alpha beta gamma. now: x" 1 14)
  [ "$got" = "alpha beta…" ] || { echo "lt10b FAIL wordbreak [$got]" >&2; fail=1; }
  # Single token longer than width -> hard cut fallback.
  got=$(_render "supercalifragilistic. now: x" 1 12)
  [ "$got" = "supercalifr…" ] || { echo "lt10c FAIL hardcut [$got]" >&2; fail=1; }

  # '#' is escaped to '##'.
  [ "$(_render "subj #1. now: y" 1 200)" = "subj ##1." ] || { echo "lt12 FAIL [$(_render "subj #1. now: y" 1 200)]" >&2; fail=1; }

  # stdin entry point renders the same as _render. SUMMARY_ROWS_SELFTEST is
  # explicitly cleared for the subshell: without it the subshell inherits
  # SUMMARY_ROWS_SELFTEST=1 from this very run, re-enters this selftest block
  # instead of the --stdin branch, and recurses -- an unbounded fork bomb.
  got=$(printf '%s' "$s" | SUMMARY_ROWS_SELFTEST='' sh "$0" --stdin 1 200)
  [ "$got" = "billing soft delete migration. done: edited models.py, wrote backfill.py" ] || { echo "lt-stdin1 FAIL [$got]" >&2; fail=1; }
  got=$(printf '%s' "$s" | SUMMARY_ROWS_SELFTEST='' sh "$0" --stdin 2 200)
  [ "$got" = "now: add proration tests" ] || { echo "lt-stdin2 FAIL [$got]" >&2; fail=1; }

  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

# Render one row from content on stdin (used by tmux-status.sh, the writer, which
# now pushes rendered rows into @amux_rowN pane options instead of the status bar
# polling this script via #()). Pass a large width to disable clipping — tmux
# auto-clips the status line to the terminal width.
if [ "${1:-}" = "--stdin" ]; then
  _row=${2:-1}; _w=${3:-9999}
  case "$_row" in 1|2|3) ;; *) exit 0 ;; esac
  case "$_w" in ''|*[!0-9]*) _w=9999 ;; esac
  # Flatten newlines to spaces (as the old file reader did): a stray newline in
  # the content would otherwise reach the tmux option and break the status line.
  _render "$(cat | tr '\n' ' ')" "$_row" "$_w"
  exit 0
fi

# No --stdin → no-op: the status bar reads the @amux_rowN pane options the writer
# pushes, so this script is only ever a render helper now. Exit 0 (see header).
exit 0
