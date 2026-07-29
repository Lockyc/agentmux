#!/bin/sh
# tmux_version.sh — source this; do not execute directly.
#
# Single source of truth for "is the running tmux new enough for the notes
# feature's click-to-edit prefill" — scripts/notes.sh's `click` case uses
# `command-prompt -l`, added in tmux 3.6 (README Prerequisites; verified
# against tmux's own CHANGES, section "CHANGES FROM 3.5a TO 3.6"). Both
# tests/mouse/run.sh (hard-abort preflight) and test.sh (skip-vs-fail
# classification of the tests/mouse block) source this rather than each
# re-encoding the floor and the parse, so the two cannot drift.
#
# Pure POSIX sh — safe to source from /bin/sh or bash.
#
# Test: TMUX_VERSION_SELFTEST=1 sh scripts/tmux_version.sh

# The floor. Anchor any comment/message mentioning "3.6" back to these two
# variables rather than restating the number.
_AMUX_TMUX_MIN_MAJOR=3
_AMUX_TMUX_MIN_MINOR=6

# _amux_tmux_parse <raw `tmux -V` output> -> "MAJOR.MINOR" on stdout, or
# nothing if no major.minor token is found.
#
# `tmux -V` forms seen in the wild: "tmux 3.7b", "tmux 3.4", "tmux next-3.6",
# and on some builds "tmux master" (no version at all). A letter suffix on
# the minor ("3.7b") is a patch release ABOVE that minor, not a bump to the
# next one, so it's dropped before comparing — "3.7b" parses to "3.7", which
# is what makes it compare correctly against the 3.6 floor.
_amux_tmux_parse() {
  printf '%s\n' "$1" | LC_ALL=C sed -n \
    's/^[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\).*$/\1.\2/p' | head -n 1
}

# _amux_tmux_capable <raw `tmux -V` output>
#   Sets AMUX_TMUX_PARSED to the parsed "MAJOR.MINOR", or "" if unparseable.
#   Returns 0 (capable) when the parsed version is >= the floor, OR when
#   nothing could be parsed — an unparseable string ("tmux master", a build
#   identifier) is far more likely a bleeding-edge build than an ancient one,
#   and a false "too old" would block a perfectly capable tmux, which is
#   worse than the rare case where an actually-too-old unparseable build
#   surfaces as a real test failure instead of a clean skip.
#   Returns 1 (too old) only when a version WAS parsed and sits below the
#   floor.
_amux_tmux_capable() {
  AMUX_TMUX_PARSED=$(_amux_tmux_parse "$1")
  [ -n "$AMUX_TMUX_PARSED" ] || return 0
  _atc_maj=${AMUX_TMUX_PARSED%%.*}
  _atc_min=${AMUX_TMUX_PARSED#*.}
  if [ "$_atc_maj" -gt "$_AMUX_TMUX_MIN_MAJOR" ]; then
    return 0
  elif [ "$_atc_maj" -eq "$_AMUX_TMUX_MIN_MAJOR" ] && [ "$_atc_min" -ge "$_AMUX_TMUX_MIN_MINOR" ]; then
    return 0
  else
    return 1
  fi
}

if [ "${TMUX_VERSION_SELFTEST:-}" = "1" ]; then
  fail=0
  ck() { # ck <label> <got> <want>
    [ "$2" = "$3" ] || { echo "$1 FAIL got[$2] want[$3]" >&2; fail=1; }
  }
  ck_ok() { # ck_ok <label> <raw> — must be treated as capable
    if _amux_tmux_capable "$2"; then :; else
      echo "$1 FAIL expected capable, got NOT capable (parsed[$AMUX_TMUX_PARSED])" >&2
      fail=1
    fi
  }
  ck_old() { # ck_old <label> <raw> — must be treated as too old
    if _amux_tmux_capable "$2"; then
      echo "$1 FAIL expected too-old, got capable (parsed[$AMUX_TMUX_PARSED])" >&2
      fail=1
    fi
  }

  # --- _amux_tmux_parse: the exact forms named in the header comment -------
  ck parse-plain   "$(_amux_tmux_parse 'tmux 3.6')"      "3.6"
  ck parse-letter  "$(_amux_tmux_parse 'tmux 3.7b')"     "3.7"
  ck parse-old     "$(_amux_tmux_parse 'tmux 3.4')"      "3.4"
  ck parse-next    "$(_amux_tmux_parse 'tmux next-3.6')" "3.6"
  ck parse-master  "$(_amux_tmux_parse 'tmux master')"   ""
  ck parse-empty   "$(_amux_tmux_parse '')"              ""

  # --- _amux_tmux_capable: floor is 3.6 ------------------------------------
  ck_ok  at-floor      'tmux 3.6'
  ck_ok  above-minor   'tmux 3.7b'
  ck_ok  above-major   'tmux 4.0'
  ck_ok  next-at-floor 'tmux next-3.6'
  ck_old below-minor   'tmux 3.4'
  ck_old below-major   'tmux 2.9'
  # 3.5a is a patch release WITHIN 3.5 (below the 3.6 floor), not a bump to
  # 3.6 — the letter must not be misread as advancing the minor.
  ck_old patch-below   'tmux 3.5a'
  # Unparseable — treated as capable, not blocked.
  ck_ok  unparseable   'tmux master'
  ck_ok  blank         ''

  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi
