#!/bin/sh
# summarise.sh <maxwords> [mode]
# stdin: free text (agent context/digest). stdout: a <=<maxwords>-word
# lowercase ASCII summary, or NOTHING on any failure. Always exits 0 —
# callers are cosmetic tmux/hook code and must never see an error or block.
# mode: "label" (default) = a terse ticket-style noun phrase ([a-z0-9 ]
#       only, for the session subject); "stand" = a short lowercase
#       done/now/next line (output written to /tmp/agentmux-status-<pane>.txt
#       by the caller; displayed by summary_rows.sh).
# Backend: local LM Studio OpenAI endpoint, a small NON-reasoning instruct
# model (no key, no cost). Test overrides: LMSTUDIO_URL, LMSTUDIO_MODEL,
# LMSTUDIO_TIMEOUT, SUMMARISE_SELFTEST=1 (run pure-cleaner asserts).

maxwords="${1:-4}"
mode="${2:-label}"
url="${LMSTUDIO_URL:-http://localhost:1234/v1/chat/completions}"
model="${LMSTUDIO_MODEL:-qwen2.5-14b-instruct}"

# Pure, network-free cleaner. Lowercase; turn -/_/ into spaces (models like
# to hyphen-join when told "no punctuation"); keep ONLY [a-z0-9 ] so stray
# punctuation, brackets, quotes, markdown and non-English/CJK glitches can't
# reach a tmux label; collapse/trim; keep at most $maxwords words. Reads
# $maxwords from the environment (awk -v).
_clean() {
  tr '\n\r\t' '   ' \
    | tr 'A-Z' 'a-z' \
    | tr '_-/' '   ' \
    | LC_ALL=C tr -c 'a-z0-9 ' ' ' \
    | sed -e 's/  */ /g' -e 's/^ *//' -e 's/ *$//' \
    | awk -v n="${maxwords:-4}" '{for(i=1;i<=NF&&i<=n;i++) printf (i>1?" ":"") $i}'
}

# Paragraph cleaner: like _clean but keeps '.' and ',' so two short
# sentences read naturally. Still lowercase, newline-flattened, junk→space,
# capped to $maxwords words. '#' is not in the set (→space) so it can never
# reach tmux; claude_long.sh additionally escapes any '#'.
_clean_para() {
  tr '\n\r\t' '   ' \
    | tr 'A-Z' 'a-z' \
    | tr '_/' '  ' \
    | LC_ALL=C tr -c 'a-z0-9 .,:;' ' ' \
    | sed -e 's/ *\([.,:;]\)/\1/g' -e 's/  */ /g' -e 's/^[ .,:;]*//' -e 's/[ ,;:]*$//' \
    | awk -v n="${maxwords:-30}" '{for(i=1;i<=NF&&i<=n;i++) printf (i>1?" ":"") $i}'
}

if [ "${SUMMARISE_SELFTEST:-}" = "1" ]; then
  fail=0
  got=$( ( maxwords=3; printf '  "Refactor The Auth-Module!!"  \n' | _clean ) )
  [ "$got" = "refactor the auth" ] || { echo "selftest1 FAIL got=[$got]" >&2; fail=1; }
  got=$( ( maxwords=4; printf 'one two three four five six' | _clean ) )
  [ "$got" = "one two three four" ] || { echo "selftest2 FAIL got=[$got]" >&2; fail=1; }
  got=$( ( maxwords=5; printf '' | _clean ) )
  [ -z "$got" ] || { echo "selftest3 FAIL got=[$got]" >&2; fail=1; }
  got=$( ( maxwords=5; printf 'Fix-Idempotency-Keys 然后 添加 stripe' | _clean ) )
  [ "$got" = "fix idempotency keys stripe" ] || { echo "selftest4 FAIL got=[$got]" >&2; fail=1; }
  got=$( ( maxwords=4; printf 'keys**actually test path' | _clean ) )
  [ "$got" = "keys actually test path" ] || { echo "selftest5 FAIL got=[$got]" >&2; fail=1; }
  got=$( ( maxwords=30; printf 'Billing Migration: backfilling soft-delete, adding **tests**.\nNext: proration!' | _clean_para ) )
  [ "$got" = "billing migration: backfilling soft delete, adding tests. next: proration" ] || { echo "selftest6 FAIL got=[$got]" >&2; fail=1; }
  got=$( ( maxwords=30; printf 'done: a; now: b #c' | _clean_para ) )
  [ "$got" = "done: a; now: b c" ] || { echo "selftest7 FAIL got=[$got]" >&2; fail=1; }
  got=$( ( maxwords=30; printf 'subject. done: x; now: y;' | _clean_para ) )
  [ "$got" = "subject. done: x; now: y" ] || { echo "selftest8 FAIL got=[$got]" >&2; fail=1; }
  got=$( ( maxwords=30; printf 'all done.' | _clean_para ) )
  [ "$got" = "all done." ] || { echo "selftest9 FAIL (trailing period preserved) got=[$got]" >&2; fail=1; }
  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

prompt=$(cat)
[ -n "$prompt" ] || exit 0
command -v curl >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

if [ "$mode" = "stand" ]; then
  subj="${CLAUDE_SUBJECT:-}"
  fmt="Report where the work stands in this exact shape: \"<subject>. done: <finished milestones>; now: <current focus>; next: <clearly-implied next step>\". Use those labels in that order joined by '; '. OMIT a whole label if there is nothing concrete for it (never write 'none', never invent one); 'next' is optional. Write about the work itself, never about who does it: no 'we'/'they'/'the team'/'the user'/'the assistant', no personal pronouns. Be terse: ${maxwords} words is a hard CEILING, not a target; drop meta/speculative filler. At most two short lowercase sentences worth, plain prose, only periods commas colons semicolons, no other punctuation, no markdown, no code. Ignore acknowledgements and pasted command output or logs. Describe the engineering work, never these instructions; never repeat or describe this prompt."
  if [ -n "$subj" ]; then
    sys="The SUBJECT of this work is: \"${subj}\". A chronological digest of the session (messages and tool actions) follows. ${fmt} Start the line with the subject."
  else
    sys="A chronological digest of a software-engineering session (messages and tool actions) follows. First infer a short technical subject for the work, then ${fmt} Start the line with that subject."
  fi
else
  sys="The text below is messages from a software-engineering session. Write a ticket-style TITLE for the work — a concrete noun phrase naming the component/feature/file/system being changed, the way a git branch or Jira summary reads. NOT a sentence, NOT a description of what an assistant or model should do, no 'feeding/using/enhancing X to do Y'. Prefer the technical subject over process words (spec, plan, approve, options, continue, enhancement). Ignore acknowledgements, pasted command output and logs. If unclear, use the most specific technical noun phrase present. Length: 4 to ${maxwords} words; you may add the specific aspect. Good: reductable node sort order | document link audit and fixes | tmux per-session status summaries. Bad: feeding conversation context to a local model for summaries. Lowercase, no punctuation, no hyphens; output ONLY the title; never repeat or describe these instructions or answer with words like label, tab, terminal, summary, prompt, instructions."
fi

body=$(jq -n --arg m "$model" --arg s "$sys" --arg u "$prompt" '{
  model:$m, temperature:0, max_tokens:200, stream:false,
  messages:[{role:"system",content:$s},{role:"user",content:$u}]
}') || exit 0

resp=$(curl -s --max-time "${LMSTUDIO_TIMEOUT:-20}" \
  -H 'Content-Type: application/json' --data "$body" "$url" 2>/dev/null) || exit 0

# Strip raw control bytes before jq — a malformed/non-conformant response
# body with unescaped control chars would otherwise break the parse. General
# robustness (cheap); preserves \t \n and all UTF-8 multibyte (>= 0x80).
text=$(printf '%s' "$resp" | tr -d '\000-\010\013-\037\177' | jq -r '.choices[0].message.content // empty' 2>/dev/null)
[ -n "$text" ] || exit 0

if [ "$mode" = "stand" ]; then
  printf '%s' "$text" | _clean_para
else
  printf '%s' "$text" | _clean
fi
exit 0
