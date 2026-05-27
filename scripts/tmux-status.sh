#!/bin/sh
# Usage: tmux-status.sh <state> [--notify <message>]
# Shared status-hook core — called by each agent's hook glue (e.g. claude/status.sh).
# The adapter sets these env vars before exec'ing this script:
#   AGENTMUX_AGENT_NAME       agent label used in tab and temp-file names (default: agent)
#   AGENTMUX_CTX_BIN          path to transcript context extractor (no default)
#   AGENTMUX_DIGEST_BIN       path to transcript digest builder (no default)
#   AGENTMUX_HOOK_PROMPT      (working state only) latest user prompt
#   AGENTMUX_HOOK_TRANSCRIPT  (working state only) path to the agent's session transcript
# Two jobs:
#  1. Tab label = "<emoji> <agent>" — a STABLE, state-only tab.
#     State tokens: start working permission notify done
#     Emojis:       🤖     ⚡       🔐         📣     ✅  (👀 derived internally)
#  2. AI summary: stable subject + done/now/next trajectory, re-derived on
#     every working hook from AGENTMUX_DIGEST_BIN + summarise.sh stand mode.
#
# /tmp/agentmux-status-<pane>.txt       done/now/next summary (status lines 1-3; each working hook)
# /tmp/agentmux-diag-<pane>.txt         pipeline diagnostic shown when no summary yet
# /tmp/<agent_name>-subject-<pane>.txt  stable subject label (derived once, re-anchored on shift)
# /tmp/<agent_name>-substart-<pane>.txt subject-start line offset (scope B; written on re-anchor)
# /tmp/agentmux-sum-<pane>.lock.d       summariser overlap lock
# start state removes all of the above. Needs jq, AGENTMUX_CTX_BIN, AGENTMUX_DIGEST_BIN,
# summarise.sh, and a reachable LLM endpoint; without it diag shows "llm: unreachable".

[ -z "$TMUX" ] && exit 0

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Cosmetic hook — must be invisible to the agent's control flow: hook stdout is
# injected into the prompt context, and a non-zero exit alters agent behaviour.
# So: no stdout, exit 0 unconditionally, all LM work detached (never blocks the
# turn). stderr left alone (debugging).
exec >/dev/null

# Map semantic state token → display emoji. Unknown tokens are ignored.
state="$1"
case "$state" in
  start)      emoji="🤖" ;;
  working)    emoji="⚡" ;;
  permission) emoji="🔐" ;;
  notify)     emoji="📣" ;;
  done)       emoji="✅" ;;
  *)          exit 0 ;;
esac

pane_key=$(echo "$TMUX_PANE" | tr -d '%')
agent_name="${AGENTMUX_AGENT_NAME:-agent}"
longfile="/tmp/agentmux-status-${pane_key}.txt"
diagfile="/tmp/agentmux-diag-${pane_key}.txt"
subjectfile="/tmp/${agent_name}-subject-${pane_key}.txt"
substartfile="/tmp/${agent_name}-substart-${pane_key}.txt"
TAB_LABEL="${AGENTMUX_TAB_LABEL_BIN:-$HOME/.agentmux/scripts/tab_label.sh}"
label=$([ -x "$TAB_LABEL" ] && "$TAB_LABEL" "$agent_name" 2>/dev/null || echo "$agent_name")
project=$(tmux display-message -p "#{session_name}" 2>/dev/null)
[ -z "$project" ] && project=$(basename "$PWD" 2>/dev/null)
[ -z "$project" ] && project="$label"

# Worktree-aware toast subtitle: in `~/Developer/myrepo-feat-x` (a worktree of
# myrepo), basename gives "myrepo-feat-x" which is noisy. Prefer "myrepo (feat-x)"
# — repo from the common git dir, branch from HEAD. Silent fallback to basename
# if not in git or not in a worktree.
case "$(git rev-parse --absolute-git-dir 2>/dev/null)" in
  */worktrees/*)
    repo=$(basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)")" 2>/dev/null)
    branch=$(git branch --show-current 2>/dev/null)
    [ -n "$repo" ] && [ -n "$branch" ] && project="${repo} (${branch})"
    ;;
esac

if [ "$emoji" = "🤖" ]; then
  rm -f "$longfile" "$diagfile" "$subjectfile" "$substartfile" 2>/dev/null
  rmdir "/tmp/agentmux-sum-${pane_key}.lock.d" 2>/dev/null
fi

# Hook payload is parsed by the adapter and handed in via env vars — agent
# hook schemas differ, so payload parsing lives per-adapter (e.g. claude/status.sh).
prompt="${AGENTMUX_HOOK_PROMPT:-}"
transcript="${AGENTMUX_HOOK_TRANSCRIPT:-}"

# Precedence: notify fires AFTER a turn ends if you don't respond promptly, and
# would otherwise overwrite the done/seen/permission tracking. A done or blocked
# window already means "your move", so notify must not clobber those states.
# It still overwrites start/working. Also makes done-vs-notify race order-independent.
if [ "$emoji" = "📣" ]; then
  case "$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)" in
    "✅ "*|"👀 "*|"🔐 "*) exit 0 ;;
  esac
fi

# done means "finished, you haven't looked". If you're already sitting on this
# window (active window of an attached session) it's been seen the moment it
# finished — emit 👀 directly; after-select-window/window_seen.sh covers the
# "switch to it later" case.
render="$emoji"
if [ "$emoji" = "✅" ]; then
  seen=$(tmux display-message -p -t "$TMUX_PANE" '#{window_active}#{?session_attached,1,0}' 2>/dev/null)
  [ "$seen" = "11" ] && render="👀"
fi

tmux rename-window -t "$TMUX_PANE" "$render $label"

# working → AI summary: a stable SUBJECT (derived once from early turns,
# re-anchored when work shifts topic) + done/now/next from AGENTMUX_DIGEST_BIN
# piped into summarise.sh stand mode. Detached: never blocks the hook
# (cosmetic-hook contract); the foreground already did exec >/dev/null and will
# exit 0. Spawned nohup ... >/dev/null 2>&1 </dev/null & so it shares no fd
# with the agent. Up to 3 LM calls (subject-derive OR shift-candidate, then stand);
# detached + per-pane lock so latency is invisible.
SUM="${AGENTMUX_SUMMARISE_BIN:-$HOME/.agentmux/scripts/summarise.sh}"
CTX="${AGENTMUX_CTX_BIN:-}"
DIG="${AGENTMUX_DIGEST_BIN:-}"
if [ "$emoji" = "⚡" ] && [ -n "$prompt" ] && [ -x "$SUM" ] && [ -x "$CTX" ] && [ -x "$DIG" ]; then
  # Resolve the configured LLM URL (used for the diag-ping fallback inside the
  # detached subshell). env > [llm] in agents.toml > default.
  . "$SCRIPT_DIR/llm-config.sh"
  _amux_load_llm
  pfile=$(mktemp /tmp/agentmux-raw-XXXXXX 2>/dev/null) || pfile=""
  if [ -n "$pfile" ]; then
    printf '%s' "$prompt" > "$pfile"
    nohup sh -c '
      sum=$1; ctx=$2; tp=$3; pf=$4; lf=$5; pane=$6; sf=$7; dig=$8; ssf=$9; llm_url=${10}
      cur=$(cat "$pf" 2>/dev/null); rm -f "$pf"
      recent=$("$ctx" "$tp" 6 400 tail 2>/dev/null)
      if [ -n "$recent" ] && [ -n "$cur" ]; then blob="$recent / $cur"
      elif [ -n "$cur" ]; then blob="$cur"
      else blob="$recent"; fi
      [ -n "$blob" ] || exit 0
      lock="/tmp/agentmux-sum-${pane}.lock.d"
      mkdir "$lock" 2>/dev/null || exit 0

      subj=$(cat "$sf" 2>/dev/null)
      if [ -z "$subj" ]; then
        # No subject yet: derive once the early window has enough signal
        # (>= 6 substantive post-filter user turns, roughly the first 20%).
        early=$("$ctx" "$tp" 8 300 head 2>/dev/null)
        if [ -n "$early" ]; then
          seps=$(printf "%s" "$early" | grep -o " / " | wc -l | tr -d " ")
          segs=$(( ${seps:-0} + 1 ))
        else
          segs=0
        fi
        if [ "$segs" -ge 6 ]; then
          subj=$(printf "%s" "$early" | "$sum" 6 label)
          [ -n "$subj" ] && printf "%s" "$subj" > "$sf"
        fi
      else
        # Subject set: if recent work shares no content word (>3 chars) with
        # it, the work moved on. AUGMENT (append) the new aspect instead of
        # replacing, so the original anchor noun survives drift. Punctuation
        # is fine here: the subject is only ever LM context (AGENTMUX_SUBJECT),
        # never rendered as a tmux label.
        cand=$(printf "%s" "$blob" | "$sum" 6 label)
        if [ -n "$cand" ]; then
          sl=" $(printf "%s" "$subj" | tr "A-Z" "a-z" | tr -cs "a-z0-9" " ") "
          ov=
          for w in $(printf "%s" "$cand" | tr "A-Z" "a-z" | tr -cs "a-z0-9" " "); do
            [ "${#w}" -gt 3 ] || continue
            case "$sl" in *" $w "*) ov=1; break ;; esac
          done
          if [ -z "$ov" ]; then
            # cut, not awk: an awk program literal would nest single quotes
            # inside this nohup sh -c block and break the outer quoting.
            subj=$(printf "%s; %s\n" "$subj" "$cand" | tr -s " " | cut -d" " -f1-12)
            printf "%s" "$subj" > "$sf"
            # Record transcript line offset at re-anchor so the digest
            # (scope B) covers only the new task, not the whole session.
            wc -l < "$tp" 2>/dev/null | tr -d " " > "$ssf"
          fi
        fi
      fi

      start=$(cat "$ssf" 2>/dev/null)
      case "$start" in ""|*[!0-9]*) start=1 ;; esac
      digest=$("$dig" "$tp" "$start" 10000 2>/dev/null)
      [ -n "$digest" ] || digest="$blob"
      df="/tmp/agentmux-diag-${pane}.txt"
      p=$(printf "%s" "$digest" | AGENTMUX_SUBJECT="$subj" "$sum" 55 stand)
      if [ -n "$p" ]; then
        printf "%s" "$p" > "$lf"
        rm -f "$df" 2>/dev/null
      else
        if command -v curl >/dev/null 2>&1; then
          if curl -s --max-time 3 "$llm_url" >/dev/null 2>&1; then
            printf "context: building..." > "$df"
          else
            printf "llm: unreachable" > "$df"
          fi
        fi
      fi
      rmdir "$lock" 2>/dev/null
    ' _ "$SUM" "$CTX" "$transcript" "$pfile" "$longfile" "$pane_key" "$subjectfile" "$DIG" "$substartfile" "$_llm_url" \
      >/dev/null 2>&1 </dev/null &
  fi
elif [ "$emoji" = "⚡" ] && [ -n "$prompt" ] && [ -x "$SUM" ]; then
  [ -x "$CTX" ] || printf 'ctx: AGENTMUX_CTX_BIN not set\n' > "$diagfile"
  [ -x "$DIG" ] || printf 'digest: AGENTMUX_DIGEST_BIN not set\n' > "$diagfile"
fi

if [ "$2" = "--notify" ]; then
  # Dedupe across hook types (done + notify fire ~simultaneously at end of turn).
  # mkdir is atomic — only one concurrent hook process wins the claim per cooldown window.
  lockdir="/tmp/${agent_name}-notify-${pane_key}.d"
  cooldown=5

  if [ -d "$lockdir" ]; then
    now=$(date +%s)
    last=$(stat -f %m "$lockdir" 2>/dev/null \
        || stat -c %Y "$lockdir" 2>/dev/null \
        || echo 0)
    if [ "$((now - last))" -lt "$cooldown" ]; then
      exit 0
    fi
    rmdir "$lockdir" 2>/dev/null
  fi

  mkdir "$lockdir" 2>/dev/null || exit 0

  MSG="$3" PROJ="$project" AGENT="$agent_name" osascript -e 'display notification (system attribute "MSG") with title (system attribute "AGENT") subtitle (system attribute "PROJ") sound name "Submarine"' 2>/dev/null
fi

exit 0
