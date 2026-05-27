#!/bin/sh
# summary_rows.sh <pane-id> <row> [width]
# Renders the pane's /tmp/agentmux-status-<pane>.txt across THREE status rows.
# Agents write "done/now/next" text to that file; this script displays it.
# Format produced by summarise.sh stand mode: "<subject>. done: …; now: …; next: …"
#   row 1 = "<subject>. done: …"  (everything before " now:")
#   row 2 = "now: …"              (between " now:" and " next:")
#   row 3 = "next: …"             (from " next:" to end)
# Each row is trimmed and clipped to <width> with a trailing "…" if it
# overflows. Missing fields print a blank row. If text has no " now:"/" next:"
# marker it lands whole on row 1, rows 2/3 blank.
# tmux re-parses #() output for format directives so '#' is escaped to '##'.
# Always exits 0. Content is the lowercase ASCII set _clean_para emits, so
# byte-wise substr == column-wise.
# Test: SUMMARY_ROWS_SELFTEST=1.

# _render <content> <row> <width> -> the row's field, trimmed/clipped/escaped.
_render() {
  awk -v r="$2" -v w="$3" -v s="$1" '
    function clip(t) {
      sub(/^[ ;]+/, "", t); sub(/[ ;]+$/, "", t)
      if (length(t) > w) t = substr(t, 1, w - 1) "…"
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

  # Clip to width-1 chars + "…" when the field overflows (width 12 -> 11 kept).
  got=$(_render "aaaaaaaaaa bbbbbbbbbb cccccccccc. now: x" 1 12)
  [ "$got" = "aaaaaaaaaa …" ] || { echo "lt10 FAIL clip [$got]" >&2; fail=1; }

  # '#' is escaped to '##'.
  [ "$(_render "subj #1. now: y" 1 200)" = "subj ##1." ] || { echo "lt12 FAIL [$(_render "subj #1. now: y" 1 200)]" >&2; fail=1; }

  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

pane=$(printf '%s' "${1:-}" | tr -d '%')
row=${2:-1}
width=${3:-120}
[ -n "$pane" ] || exit 0
case "$row" in 1|2|3) ;; *) exit 0 ;; esac
case "$width" in ''|*[!0-9]*) width=120 ;; esac
[ "$width" -lt 20 ] && width=120
f="/tmp/agentmux-status-${pane}.txt"
[ -s "$f" ] || exit 0
content=$(tr '\n' ' ' < "$f")
_render "$content" "$row" "$width"
