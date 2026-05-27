#!/bin/sh
# ctx.sh <transcript_path> <max_msgs> [percap] [head|tail]
# end=head → the EARLIEST <max_msgs> turns (for the session subject);
# end=tail (default) → the most RECENT ones (for current activity).
# Prints the text of the last <max_msgs> *user AND assistant* turns from a
# Claude Code transcript JSONL — including assistant text segments so the
# concrete subject matter (file/function names, what was changed) reaches
# the summariser instead of just the user's tail-end imperatives. Skips
# tool-use / tool-result entries, pure conversational filler (continue /
# lgtm / ok / yes …), AND pasted noise (shell/REPL prompts, code fences,
# command dumps, ULID/path/hash blobs, anything <55% prose) which otherwise
# makes the model echo garbage or the system prompt — oldest→newest, each
# truncated to [percap] chars (default 240), joined by " / ". If everything
# is filler the output is empty, so callers keep their prior (good) label
# rather than degrade.
# Prints NOTHING and exits 0 on any problem (missing/unreadable transcript,
# no jq, malformed lines): callers are cosmetic and must degrade silently.
# Test: CLAUDE_CTX_SELFTEST=1.

_ctx() {
  _tr=$1
  _n=${2:-5}
  _percap=${3:-240}
  _end=${4:-tail}

  [ -n "$_tr" ] && [ -r "$_tr" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # tail bounds work on very long sessions; we only ever need recent user turns.
  tail -n 800 "$_tr" 2>/dev/null \
  | jq -rR 'fromjson? // empty
      | select(.type=="user" or .type=="assistant")
      | (.message.content) as $c
      | ( if   ($c|type)=="string" then $c
          elif ($c|type)=="array"  then ($c | map(select(.type=="text") | .text) | join(" "))
          else "" end )
      | gsub("\\s+";" ") | gsub("^ +| +$";"")
      | select(length > 0)' 2>/dev/null \
  | grep -viE '^[[:space:][:punct:]]*((y|n|k|ok|okay|yes|yep|yeah|ya|yup|no|nope|nah|sure|ta|thx|thanks|thank|cheers|continue|please|keep|going|carry|on|proceed|go|ahead|do|it|next|lgtm|looks|good|sounds|perfect|great|nice|cool|done|stop|wait|hold|hmm|huh|same|again|retry|right|fine|this|that)[[:space:][:punct:]]*)+$' \
  | awk '
      {
        s=$0
        if (index(s, "❯") || index(s, "```")) next        # REPL/shell prompt or code fence
        if (s ~ /^[ \t]*[$>#][ \t]/) next                   # leading shell prompt
        t=s; gsub(/[^a-zA-Z ]/, "", t)                      # prose = letters+spaces
        if (length(s) > 0 && length(t)*100 < length(s)*55) next   # <55% prose -> code/dump
        ntok=split(s, w, /[ \t]+/); drop=0
        for (i=1;i<=ntok;i++) if (length(w[i])>30) { drop=1; break }  # ULID/path/hash/base64
        if (drop) next
        print s
      }' \
  | ( [ "$_end" = head ] && head -n "$_n" || tail -n "$_n" ) \
  | awk -v pc="$_percap" 'BEGIN{ORS=""} { s=$0; if (length(s)>pc) s=substr(s,1,pc); printf "%s%s", (NR>1 ? " / " : ""), s }'
}

if [ "${CLAUDE_CTX_SELFTEST:-}" = "1" ]; then
  fail=0
  tmp=$(mktemp /tmp/claude-ctx-test-XXXXXX) || exit 1
  cat > "$tmp" <<'JSONL'
{"type":"user","message":{"content":"lets refactor the auth module for soft deletes"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"sounds good, starting on the model layer"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/repo/auth.py"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"applied"}]}}
{"type":"user","message":{"content":"```\ndef foo():\n  pass\n```"}}
{"type":"user","message":{"content":"❯ ls -la /repo"}}
{"type":"user","message":{"content":"$ git status"}}
{"type":"user","message":{"content":"hash 01HZQ4XJ5N8K3MFGRTVBPCY7ASAAAAAA appears in log"}}
{"type":"user","message":{"content":"ok"}}
{"type":"user","message":{"content":"x=1; y=2; z=3; q=4; m=5"}}
{"type":"user","message":{"content":"now wire up the migration script"}}
JSONL

  out=$(_ctx "$tmp" 10 240 tail)
  case "$out" in *"refactor the auth module"*) ;; *) echo "ctx1 FAIL (user prose missing) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"wire up the migration script"*) ;; *) echo "ctx2 FAIL (recent prose missing) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"sounds good"*) ;; *) echo "ctx3 FAIL (assistant prose missing) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"def foo"*) echo "ctx4 FAIL (code fence leaked) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"ls -la"*) echo "ctx5 FAIL (REPL prompt leaked) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"git status"*) echo "ctx6 FAIL (shell prompt leaked) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"01HZQ4XJ5N8K3MFGRTVBPCY7AS"*) echo "ctx7 FAIL (ULID/hash leaked) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"q=4"*) echo "ctx8 FAIL (low-prose leaked) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"applied"*) echo "ctx9 FAIL (tool_result leaked) got=[$out]" >&2; fail=1 ;; esac
  # Filler "ok" appears as its own segment if kept; check both list positions.
  case "$out" in *" / ok / "*|*" / ok"|"ok"*|*"/ ok"*) echo "ctx10 FAIL (filler kept) got=[$out]" >&2; fail=1 ;; esac

  # head mode: earliest surviving prose line, taken on its own.
  head1=$(_ctx "$tmp" 1 240 head)
  [ "$head1" = "lets refactor the auth module for soft deletes" ] || { echo "ctx11 FAIL (head) got=[$head1]" >&2; fail=1; }

  # percap clipping
  clip=$(_ctx "$tmp" 1 8 head)
  [ "$clip" = "lets ref" ] || { echo "ctx12 FAIL (percap) got=[$clip]" >&2; fail=1; }

  # All-filler transcript yields empty (callers keep prior label).
  cat > "$tmp" <<'JSONL'
{"type":"user","message":{"content":"ok"}}
{"type":"user","message":{"content":"yes"}}
{"type":"user","message":{"content":"continue please"}}
JSONL
  empty=$(_ctx "$tmp" 5 240 tail)
  [ -z "$empty" ] || { echo "ctx13 FAIL (all-filler) got=[$empty]" >&2; fail=1; }

  # Missing/unreadable transcript exits silently with empty output.
  miss=$(_ctx "/tmp/does-not-exist-agentmux-ctx-$$" 5 240 tail)
  [ -z "$miss" ] || { echo "ctx14 FAIL (missing file) got=[$miss]" >&2; fail=1; }

  rm -f "$tmp"
  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

_ctx "$1" "${2:-5}" "${3:-240}" "${4:-tail}"
