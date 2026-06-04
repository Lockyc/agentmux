#!/bin/sh
# digest.sh <transcript_path> [start_line] [char_budget]
# Compact chronological digest of a Claude Code transcript JSONL, from
# start_line (1-based, default 1) to EOF, for the done/now/next status line.
# Emits oldest->newest, joined by " / ":
#   - user prose, assistant prose (filler/pasted-noise filtered)
#   - tool-action one-liners for MUTATING tools only:
#       Edit/MultiEdit/NotebookEdit -> "edited <basename>"
#       Write                        -> "wrote <basename>"
#       Bash                         -> "ran: <command, first 60 chars>"
#     a failed paired tool_result (is_error true) appends " (failed)".
#   Read/Grep/Glob/LS/Task and other non-mutating tools are skipped. The LATEST
#   TodoWrite snapshot is appended as "todo-done:/todo-now:/todo-next: <item>".
# Over char_budget, drops the OLDEST prose first but keeps ALL tool lines.
# Prints NOTHING and exits 0 on any problem (cosmetic caller degrades silently).
# Test: CLAUDE_DIGEST_SELFTEST=1.

_digest() {
  _f=$1; _start=$2; _budget=$3
  case "$_start" in ''|*[!0-9]*) _start=1 ;; esac
  [ "$_start" -lt 1 ] && _start=1
  case "$_budget" in ''|*[!0-9]*) _budget=10000 ;; esac

  # Pass 1: tool_use ids whose paired tool_result errored.
  _ferr=$(tail -n +"$_start" "$_f" 2>/dev/null \
    | jq -rR 'fromjson? // empty
        | select(.type=="user")
        | (.message.content // empty)
        | if type=="array" then .[] else empty end
        | select((.type=="tool_result") and (.is_error==true))
        | .tool_use_id' 2>/dev/null)

  # Pass 2: tagged stream (prose + mutating tool one-liners), captured so we can
  # append the latest TodoWrite snapshot after the budget trim.
  _main=$(tail -n +"$_start" "$_f" 2>/dev/null \
  | jq -rR --arg ferr "$_ferr" '
      ($ferr | split("\n") | map(select(length>0))) as $F
      | fromjson? // empty
      | (.message.content) as $c
      | if .type=="user" then
          ( if ($c|type)=="string" then "U\t"+($c|gsub("\\s+";" "))
            elif ($c|type)=="array" then
              (($c|map(select(.type=="text")|.text)|join(" "))|gsub("\\s+";" ")) as $t
              | if ($t|gsub("^ +| +$";"")|length)>0 then "U\t"+$t else empty end
            else empty end )
        elif .type=="assistant" and ($c|type)=="array" then
          ( $c[]
            | if .type=="text" then "A\t"+(.text|gsub("\\s+";" "))
              elif .type=="tool_use" then
                ( .name as $n | .input as $in | (.id // "") as $id
                  | ( if   ($n=="Edit" or $n=="MultiEdit" or $n=="NotebookEdit")
                        then (($in.file_path // $in.notebook_path // "")|gsub("\\s+";" ")|split("/")|last) as $b
                          | if ($b|length)>0 then "edited "+$b else empty end
                      elif $n=="Write"
                        then (($in.file_path // "")|gsub("\\s+";" ")|split("/")|last) as $b
                          | if ($b|length)>0 then "wrote "+$b else empty end
                      elif $n=="Bash"
                        then (($in.command // "")|gsub("\\s+";" ")|.[0:60]) as $cmd
                          | if ($cmd|length)>0 then "ran: "+$cmd else empty end
                      else empty end ) as $line
                  | if ($line|type)=="string" and (($line|length)>0)
                    then "T\t"+$line+(if ($F|index($id)) then " (failed)" else "" end)
                    else empty end )
              else empty end )
        else empty end' 2>/dev/null \
  | awk -F '\t' -v budget="$_budget" '
      function isfiller(s,   x) {
        x=tolower(s)
        return (x ~ /^[[:space:][:punct:]]*((yes|yep|yeah|yup|nope|nah|okay|ok|sure|thanks|thank|thx|cheers|ta|continue|please|keep|going|carry|on|proceed|go|ahead|do|it|next|lgtm|looks|good|sounds|perfect|great|nice|cool|done|stop|wait|hold|hmm|huh|same|again|retry|right|fine|this|that|ya|y|n|k)[[:space:][:punct:]]*)+$/)
      }
      {
        tag=$1; text=$2
        if (tag!="T") {
          if (text=="" ) next
          if (isfiller(text)) next
          if (index(text,"```") || index(text,"❯")) next
          if (text ~ /^ *[$>#] /) next
          pr=text; gsub(/[^a-zA-Z ]/,"",pr)
          if (length(text)>0 && length(pr)*100 < length(text)*55) next
          drop=0; m=split(text,w," "); for(i=1;i<=m;i++) if(length(w[i])>30){drop=1;break}
          if (drop) next
          if (length(text)>240) text=substr(text,1,240)
        }
        n++; T[n]=tag; X[n]=text; removed[n]=0
      }
      END {
        total=0; for(i=1;i<=n;i++) total+=length(X[i]); if(n>1) total+=3*(n-1)
        while (total>budget) {
          cut=0
          for(i=1;i<=n;i++) if(!removed[i] && T[i]!="T"){ removed[i]=1; total-=length(X[i])+3; cut=1; break }
          if(!cut) break
        }
        first=1
        for(i=1;i<=n;i++) if(!removed[i]){ printf "%s%s", (first?"":" / "), X[i]; first=0 }
      }')

  # Latest TodoWrite snapshot -> labeled segments (agent's own done/now/next).
  # TodoWrite is a full-state snapshot per call, so take the LAST one in the
  # window. @json keeps each snapshot on one line; tail -n1 = newest.
  _todojson=$(tail -n +"$_start" "$_f" 2>/dev/null \
    | jq -rR 'fromjson? // empty
        | select(.type=="assistant")
        | (.message.content // empty)
        | if type=="array" then .[] else empty end
        | select(.type=="tool_use" and .name=="TodoWrite")
        | (.input.todos // empty) | @json' 2>/dev/null \
    | tail -n 1)
  # jq joins the ordered segments itself, so no shell word-splitting / subshell
  # var-mutation (keeps shellcheck clean — no SC2030/SC2086).
  _todoseg=""
  if [ -n "$_todojson" ]; then
    _todoseg=$(printf '%s' "$_todojson" | jq -r '
        ( map(select(.status=="completed"))
          + map(select(.status=="in_progress"))
          + map(select(.status=="pending")) )
        | map( if .status=="completed"    then "todo-done: " + ((.content // "")|gsub("\\s+";" ")|.[0:240])
               elif .status=="in_progress" then "todo-now: "  + ((.activeForm // .content // "")|gsub("\\s+";" ")|.[0:240])
               else "todo-next: " + ((.content // "")|gsub("\\s+";" ")|.[0:240]) end )
        | join(" / ")' 2>/dev/null)
  fi

  # Emit main digest + todo segments joined by " / ", omitting the separator
  # when either side is empty (preserves the "prints NOTHING when empty" contract).
  if [ -n "$_main" ] && [ -n "$_todoseg" ]; then
    printf '%s / %s' "$_main" "$_todoseg"
  elif [ -n "$_main" ]; then
    printf '%s' "$_main"
  else
    printf '%s' "$_todoseg"
  fi
}

if [ "${CLAUDE_DIGEST_SELFTEST:-}" = "1" ]; then
  fail=0
  tmp=$(mktemp /tmp/claude-digest-test-XXXXXX) || exit 1
  cat > "$tmp" <<'JSONL'
{"type":"user","message":{"content":"lets refactor the auth module for soft deletes"}}
{"type":"assistant","message":{"content":[{"type":"text","text":"sounds good, starting on the model layer"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/repo/auth.py"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/repo/models.py"}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t9","name":"Edit","input":{}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"pytest -q tests/test_auth.py"}}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t3","is_error":true,"content":"2 failed"}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"td1","name":"TodoWrite","input":{"todos":[{"content":"Investigate bug","activeForm":"Investigating bug","status":"in_progress"}]}}]}}
{"type":"assistant","message":{"content":[{"type":"tool_use","id":"td2","name":"TodoWrite","input":{"todos":[{"content":"Write backfill","activeForm":"Writing backfill","status":"completed"},{"content":"Add proration tests","activeForm":"Adding proration tests","status":"in_progress"},{"content":"Run migration","activeForm":"Running migration","status":"pending"}]}}]}}
{"type":"user","message":{"content":"ok"}}
JSONL

  out=$(_digest "$tmp" 1 10000)
  case "$out" in *"refactor the auth module"*) ;; *) echo "selftest1 FAIL (user prose) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"edited auth.py"*) ;; *) echo "selftest2 FAIL (edited) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"ran: pytest -q tests/test_auth.py (failed)"*) ;; *) echo "selftest3 FAIL (ran+failed) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"models.py"*|*"Read"*|*"read "*) echo "selftest4 FAIL (Read leaked) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *" / ok"|*" / ok "*|"ok"|*"/ ok /"*) echo "selftest5 FAIL (filler 'ok' kept) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"edited  "*) echo "selftest9 FAIL (empty-input tool emitted bare line) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"todo-done: Write backfill"*) ;; *) echo "selftest_todo1 FAIL (completed) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"todo-now: Adding proration tests"*) ;; *) echo "selftest_todo2 FAIL (in_progress activeForm) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"todo-next: Run migration"*) ;; *) echo "selftest_todo3 FAIL (pending) got=[$out]" >&2; fail=1 ;; esac
  case "$out" in *"Investigating bug"*|*"Investigate bug"*) echo "selftest_todo4 FAIL (stale earlier snapshot leaked) got=[$out]" >&2; fail=1 ;; esac

  # Budget trim: with a tiny budget the prose drops but the tool lines survive.
  small=$(_digest "$tmp" 1 30)
  case "$small" in *"edited auth.py"*) ;; *) echo "selftest6 FAIL (tool kept under budget) got=[$small]" >&2; fail=1 ;; esac
  case "$small" in *"refactor the auth module"*) echo "selftest7 FAIL (prose not trimmed) got=[$small]" >&2; fail=1 ;; esac

  # start_line skips earlier turns.
  tail2=$(_digest "$tmp" 5 10000)
  case "$tail2" in *"refactor the auth module"*) echo "selftest8 FAIL (start_line ignored) got=[$tail2]" >&2; fail=1 ;; esac

  rm -f "$tmp"
  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

tp=$1
start=${2:-1}
budget=${3:-10000}
[ -n "$tp" ] && [ -r "$tp" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
_digest "$tp" "$start" "$budget"
exit 0
