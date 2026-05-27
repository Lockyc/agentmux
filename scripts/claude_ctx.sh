#!/bin/sh
# claude_ctx.sh <transcript_path> <max_msgs> [percap] [head|tail]
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
tr=$1
n=${2:-5}
percap=${3:-240}
end=${4:-tail}

[ -n "$tr" ] && [ -r "$tr" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# tail bounds work on very long sessions; we only ever need recent user turns.
tail -n 800 "$tr" 2>/dev/null \
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
| ( [ "$end" = head ] && head -n "$n" || tail -n "$n" ) \
| awk -v pc="$percap" 'BEGIN{ORS=""} { s=$0; if (length(s)>pc) s=substr(s,1,pc); printf "%s%s", (NR>1 ? " / " : ""), s }'
