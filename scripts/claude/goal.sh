#!/bin/sh
# goal.sh <resume_uuid> [width]
# Prints a one-line GOAL for a recovered Claude session — the earliest
# substantive user prose from its transcript — for the amux restore picker.
#
# The restore entry's resume UUID (last token of resume_cmd) IS the transcript
# filename: ~/.claude*/projects/<encoded-cwd>/<uuid>.jsonl. We glob by the
# (globally unique) UUID so we never reimplement Claude's cwd path-encoding, and
# the ~/.claude* glob covers the .claude / .claude-personal / .claude-work
# profile roots. Extraction is delegated to ctx.sh head mode — the one source of
# truth for transcript goal parsing — so there is no LM call: deterministic,
# offline, cheap. This exists because the live per-pane AI summary is gone by
# restore time (its /tmp files are cleared on the dead server / by the start
# hook, and were never keyed to anything a restore entry records).
#
# Prints NOTHING and exits 0 on any problem (non-UUID token, no transcript, no
# jq, empty extraction): the caller is cosmetic and degrades silently.
# Test: CLAUDE_GOAL_SELFTEST=1.

_goal() {
  _uuid=$1
  _width=${2:-66}

  # Only a canonical 8-4-4-4-12 hex UUID is a transcript id. Any other token (a
  # non-Claude resume program like `gemini-cli`, an empty token) can't map to a
  # transcript, so short-circuit before touching the filesystem.
  case "$_uuid" in
    [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) ;;
    *) return 0 ;;
  esac

  # First readable transcript matching this UUID across the profile roots. A
  # non-matching glob stays literal (POSIX sh has no nullglob), so the -r test
  # rejects it.
  _tp=""
  for _f in "$HOME"/.claude*/projects/*/"$_uuid".jsonl; do
    [ -r "$_f" ] || continue
    _tp=$_f; break
  done
  [ -n "$_tp" ] || return 0

  # ctx.sh lives beside this script. head mode, 1 message, capped to width =
  # "earliest substantive user prose, one line".
  _dir=$(dirname "$0")
  "$_dir/ctx.sh" "$_tp" 1 "$_width" head 2>/dev/null
}

if [ "${CLAUDE_GOAL_SELFTEST:-}" = "1" ]; then
  fail=0
  root=$(mktemp -d /tmp/claude-goal-test-XXXXXX) || exit 1
  uuid="3f2a1b4c-5d6e-7a8b-9c0d-1e2f3a4b5c6d"
  proj="$root/.claude/projects/-Users-x-repo"
  mkdir -p "$proj"
  cat > "$proj/$uuid.jsonl" <<'JSONL'
{"type":"user","message":{"content":"Fix the OSC 777 notify wrapping under --frame"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"on it"}]}}
JSONL

  # Happy path: earliest user prose, extracted via ctx.sh head.
  out=$(HOME="$root" _goal "$uuid")
  [ "$out" = "Fix the OSC 777 notify wrapping under --frame" ] \
    || { echo "goal1 FAIL (goal not extracted) got=[$out]" >&2; fail=1; }

  # Width cap clips the goal line (ctx.sh percap).
  clip=$(HOME="$root" _goal "$uuid" 8)
  [ "$clip" = "Fix the " ] || { echo "goal2 FAIL (width cap) got=[$clip]" >&2; fail=1; }

  # A non-UUID token (non-Claude resume program) short-circuits to empty.
  none=$(HOME="$root" _goal "gemini-cli")
  [ -z "$none" ] || { echo "goal3 FAIL (non-uuid token) got=[$none]" >&2; fail=1; }

  # A UUID with no matching transcript yields empty + exit 0.
  miss=$(HOME="$root" _goal "00000000-0000-0000-0000-000000000000")
  [ -z "$miss" ] || { echo "goal4 FAIL (no transcript) got=[$miss]" >&2; fail=1; }

  # Empty token yields empty.
  mt=$(HOME="$root" _goal "")
  [ -z "$mt" ] || { echo "goal5 FAIL (empty token) got=[$mt]" >&2; fail=1; }

  rm -rf "$root"
  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

_goal "$1" "${2:-}"
