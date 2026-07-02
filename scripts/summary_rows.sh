#!/bin/sh
# summary_rows.sh <pane-id> <row> [width] [socket-path] [runtime-dir]
# Renders the pane's done/now/next status file across THREE status rows. The file
# lives under the runtime dir the writer published (arg 5, else $XDG_RUNTIME_DIR,
# else /tmp/agentmux-<uid>), keyed by "<hash of tmux socket>-<pane number>". Both
# the dir and the key MUST match tmux-status.sh (the writer) or the file can't be
# found. tmux `#()` format commands don't inherit $TMUX (nor $XDG_RUNTIME_DIR), so
# agentmux.conf passes #{socket_path} as arg 4 and #{@amux_runtime_dir} as arg 5;
# if either is absent (e.g. manual invocation, or a server predating the option)
# we fall back — to the bare pane number, and to re-deriving the dir from env.
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

  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

pane_num=$(printf '%s' "${1:-}" | tr -d '%')
row=${2:-1}
width=${3:-120}
sock="${4:-}"
rtd="${5:-}"
[ -n "$pane_num" ] || exit 0
case "$row" in 1|2|3) ;; *) exit 0 ;; esac
case "$width" in ''|*[!0-9]*) width=120 ;; esac
[ "$width" -lt 20 ] && width=120
# Fold the socket into the key (see header) so this matches tmux-status.sh.
if [ -n "$sock" ]; then
  pane="$(printf '%s' "$sock" | cksum | cut -d' ' -f1)-${pane_num}"
else
  pane="$pane_num"
fi
# Prefer the dir the writer published (arg 5); re-derive from env only for a
# manual call or a server predating @amux_runtime_dir. #() can't see the hook's
# $XDG_RUNTIME_DIR, so the arg is the reliable source.
runtime_dir="${rtd:-${XDG_RUNTIME_DIR:-/tmp/agentmux-$(id -u)}}"
f="$runtime_dir/agentmux-status-${pane}.txt"
df="$runtime_dir/agentmux-diag-${pane}.txt"
if [ -s "$f" ]; then
  content=$(tr '\n' ' ' < "$f")
elif [ -s "$df" ]; then
  content=$(tr '\n' ' ' < "$df")
else
  exit 0
fi
_render "$content" "$row" "$width"
