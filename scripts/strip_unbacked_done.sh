#!/bin/sh
# strip_unbacked_done.sh <digest> <summary>
# Tool-evidence gate for stand-mode summaries: if the digest contains zero
# file-MUTATION markers (the literal phrases "edited <file>" or "wrote <file>"
# that digest.sh emits, anchored at segment boundaries), then any
# "done: ..." clause in the summary line cannot be evidence-grounded — strip
# it. Otherwise the summary is returned unchanged.
#
# Why mutation-only (not "ran:"): read-only investigation Bash — git
# status/log/diff, ls, grep, find — also emits "ran: ..." in the digest, but
# investigating is not "done" work. Planning / recap sessions characteristically
# do only read-only Bash, and that is precisely where the small model fabricates
# "done:" milestones. We accept that a Bash-heavy ops session (no edits, only
# ran-mutations like deploys) may have its done: stripped — rare, and the
# prompt remains defence #1.
#
# Always exits 0; caller is cosmetic. Test: STRIP_UNBACKED_DONE_SELFTEST=1.

_has_mutation() {
  # digest.sh joins segments with " / "; evidence segments start with one of
  # "edited ", "wrote " (file mutation) or "todo-done:" (agent self-report of
  # finished work). Match at line start or after " / ".
  case "$1" in
    'edited '*|'wrote '*|'todo-done:'*) return 0 ;;
  esac
  case "$1" in
    *' / edited '*|*' / wrote '*|*' / todo-done:'*) return 0 ;;
  esac
  return 1
}

_strip_done() {
  # Remove a "done:" CLAUSE LABEL from a stand-mode summary line, in place.
  # Matches "done:" (with optional whitespace before the colon) only when it
  # appears as a clause label: at start-of-line, or preceded by a sentence
  # boundary ('.') or a clause separator (';'). This guards against false
  # positives where "done:" appears inside another clause's content
  # (e.g. "subject. now: rewrote done: notes" must stay intact).
  # The matched clause runs up to the next ';' or to end-of-line. Trailing
  # orphan whitespace and ';' are trimmed; '.' is preserved so a remaining
  # "subject." reads cleanly.
  printf '%s' "$1" | awk '
    {
      s = $0
      if (match(s, /(^|[.;])[ \t]*done[ \t]*:/) == 0) { print s; next }
      # RSTART/RLENGTH cover the whole match including any leading boundary
      # char. Re-locate where the literal "done" begins inside the match so
      # that boundary char (which belongs to the preceding clause) is kept
      # in head, while only "done:" and its value are stripped.
      ms = substr(s, RSTART, RLENGTH)
      do_off = index(ms, "done")
      done_start = RSTART + do_off - 1
      done_end = RSTART + RLENGTH
      head = substr(s, 1, done_start - 1)
      tail = substr(s, done_end)
      j = index(tail, ";")
      if (j > 0) {
        rest = substr(tail, j + 1)
        sub(/^[ \t]+/, "", rest)
        out = head rest
      } else {
        out = head
      }
      sub(/[ \t;]+$/, "", out)
      print out
    }'
}

if [ "${STRIP_UNBACKED_DONE_SELFTEST:-}" = "1" ]; then
  fail=0

  # _has_mutation: positive cases (file edits/writes only)
  _has_mutation "edited foo.sh" || { echo "ta1 FAIL (edited at start)" >&2; fail=1; }
  _has_mutation "wrote bar.txt" || { echo "ta2 FAIL (wrote at start)" >&2; fail=1; }
  _has_mutation "user prose / edited foo.sh" || { echo "ta3 FAIL (edited after sep)" >&2; fail=1; }
  _has_mutation "x / y / wrote bar / z" || { echo "ta4 FAIL (wrote mid sep)" >&2; fail=1; }

  _has_mutation "todo-done: shipped backfill" || { echo "ta11 FAIL (todo-done at start)" >&2; fail=1; }
  _has_mutation "prose / todo-done: shipped backfill" || { echo "ta12 FAIL (todo-done after sep)" >&2; fail=1; }

  # _has_mutation: negative cases — ran: is NOT mutation evidence
  if _has_mutation "ran: pytest -q"; then echo "ta5 FAIL (ran at start matched)" >&2; fail=1; fi
  if _has_mutation "prose / ran: ls -la"; then echo "ta6 FAIL (ran after sep matched)" >&2; fail=1; fi
  if _has_mutation "prose / ran: git status / more / ran: git log"; then echo "ta7 FAIL (ran-only digest matched)" >&2; fail=1; fi
  if _has_mutation ""; then echo "ta8 FAIL (empty matched)" >&2; fail=1; fi
  if _has_mutation "i edited the file earlier"; then echo "ta9 FAIL (prose w/ edited matched)" >&2; fail=1; fi
  if _has_mutation "discussing migration"; then echo "ta10 FAIL (unrelated prose matched)" >&2; fail=1; fi

  # _strip_done: middle clause stripped, separator collapsed
  got=$(_strip_done "subject. done: foo; now: bar; next: baz")
  [ "$got" = "subject. now: bar; next: baz" ] || { echo "sd1 FAIL got=[$got]" >&2; fail=1; }

  # _strip_done: done is first clause
  got=$(_strip_done "subject. done: foo; now: bar")
  [ "$got" = "subject. now: bar" ] || { echo "sd2 FAIL got=[$got]" >&2; fail=1; }

  # _strip_done: done is last clause -> trailing punctuation period preserved
  got=$(_strip_done "subject. now: bar; done: foo")
  [ "$got" = "subject. now: bar" ] || { echo "sd3 FAIL got=[$got]" >&2; fail=1; }

  # _strip_done: done is only clause -> leaves subject with its period
  got=$(_strip_done "subject. done: foo")
  [ "$got" = "subject." ] || { echo "sd4 FAIL got=[$got]" >&2; fail=1; }

  # _strip_done: no done -> unchanged
  got=$(_strip_done "subject. now: bar; next: baz")
  [ "$got" = "subject. now: bar; next: baz" ] || { echo "sd5 FAIL got=[$got]" >&2; fail=1; }

  # _strip_done: "done :" with space tolerated
  got=$(_strip_done "subject. done : foo; now: bar")
  [ "$got" = "subject. now: bar" ] || { echo "sd6 FAIL got=[$got]" >&2; fail=1; }

  # _strip_done: no space after ; (still split)
  got=$(_strip_done "subject. done: foo;now: bar")
  [ "$got" = "subject. now: bar" ] || { echo "sd7 FAIL got=[$got]" >&2; fail=1; }

  # _strip_done: "done:" appearing inside another clause's VALUE must NOT
  # be treated as a clause label (regression guard for the audit finding).
  got=$(_strip_done "subject. now: rewrote done: notes; next: ship")
  [ "$got" = "subject. now: rewrote done: notes; next: ship" ] || { echo "sd8 FAIL (inner done: stripped) got=[$got]" >&2; fail=1; }

  # _strip_done: "done:" at very start of line (no subject prefix)
  got=$(_strip_done "done: foo; now: bar")
  [ "$got" = "now: bar" ] || { echo "sd9 FAIL got=[$got]" >&2; fail=1; }

  # _strip_done: boundary requires '.' or ';' — a word ending in "done"
  # followed immediately by ":" is NOT a clause label (e.g. "predone:")
  got=$(_strip_done "subject. predone: marker; now: bar")
  [ "$got" = "subject. predone: marker; now: bar" ] || { echo "sd10 FAIL (word-suffix matched) got=[$got]" >&2; fail=1; }

  # End-to-end gate behaviour: simulates how the caller composes it.
  _gate() {
    if _has_mutation "$1"; then printf '%s' "$2"; else _strip_done "$2"; fi
  }

  # mutation present -> done preserved
  got=$(_gate "user said hi / edited a.sh" "subject. done: shipped a; now: writing tests")
  [ "$got" = "subject. done: shipped a; now: writing tests" ] || { echo "g1 FAIL got=[$got]" >&2; fail=1; }

  # zero mutations -> done stripped (planning-session shape)
  got=$(_gate "user prose / more user prose" "subject. done: shipped a; now: writing tests")
  [ "$got" = "subject. now: writing tests" ] || { echo "g2 FAIL got=[$got]" >&2; fail=1; }

  # The originally-observed failure case from the design doc: digest is all
  # prose plus read-only investigation Bash (git status/log/diff), no edits.
  badsum="product migration. done: initial data transfer, setup of new environment; now: enhancement of desktop electron shell; next: integration testing of migrated components"
  baddigest="we are part way through the product migration / i have an agent working on improving the desktop electron shell / where are we at with the migration / ran: git log --oneline / ran: git status / ran: git diff main / shadow CRDT shipped step 1 backend removal in flight on step-2"
  got=$(_gate "$baddigest" "$badsum")
  case "$got" in
    *"done:"*) echo "g3 FAIL (done not stripped on observed failure) got=[$got]" >&2; fail=1 ;;
  esac

  # Sanity: a commit/test session with edits keeps done:
  goodsum="auth refactor. done: split session module; now: writing tests; next: integration"
  gooddigest="lets refactor auth / edited auth.py / wrote tests/test_auth.py / ran: pytest -q"
  got=$(_gate "$gooddigest" "$goodsum")
  [ "$got" = "$goodsum" ] || { echo "g4 FAIL (legit done stripped) got=[$got]" >&2; fail=1; }

  # todo-done is valid done evidence even with zero file mutations.
  got=$(_gate "discussing scope / todo-done: shipped backfill / todo-now: writing tests" "subj. done: shipped backfill; now: writing tests")
  [ "$got" = "subj. done: shipped backfill; now: writing tests" ] || { echo "g5 FAIL (todo-done evidence stripped) got=[$got]" >&2; fail=1; }

  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

_dig=${1:-}
_sum=${2:-}
[ -n "$_sum" ] || exit 0
if _has_mutation "$_dig"; then
  printf '%s' "$_sum"
else
  _strip_done "$_sum"
fi
exit 0
