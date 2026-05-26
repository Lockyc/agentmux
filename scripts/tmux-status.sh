#!/bin/sh
# Usage: tmux-status.sh <emoji> [--notify <message>]
# Called by Claude Code hooks in settings.json. Two jobs:
#  1. Tab label = "<emoji> claude" — a STABLE, state-only tab. The emoji is
#     the Claude state (🤖 start ⚡ working 📣 waiting 🔐 perm ✅ done
#     👀 seen); the text is just "claude". Deliberately not an LM summary —
#     the tab is the at-a-glance state; the *what* lives on status line 2.
#  2. Long summary on the dedicated 2nd status line (status-format[1] →
#     claude_long.sh): a stable subject + done/now/next trajectory line,
#     re-derived on every ⚡ from /tmp/claude-long-<pane>.txt (built by
#     claude_digest.sh + claude_summarise.sh stand mode).
#
# /tmp/claude-long-<pane>.txt      long summary (status line 2; each ⚡)
# /tmp/claude-subject-<pane>.txt   stable subject label (derived once, re-anchored on shift)
# /tmp/claude-substart-<pane>.txt  subject-start line offset (scope B; written on re-anchor)
# /tmp/claude-sum-<pane>.lock.d    summariser overlap lock
# SessionStart (🤖) removes them. Long summary needs `jq`, claude_ctx.sh,
# claude_summarise.sh, and claude_digest.sh; without them line 2 stays blank (no error).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

[ -z "$TMUX" ] && exit 0

# Cosmetic hook running as a sibling of cavemem's hooks. Must be invisible to
# Claude's control flow: SessionStart/UserPromptSubmit hook stdout is injected
# into the prompt context, and a non-zero exit (esp. 2 on Stop) alters
# Claude's behaviour. So: no stdout, exit 0 unconditionally, all LM work
# detached (never blocks the turn). stderr left alone (debugging).
exec >/dev/null

emoji="$1"
pane_key=$(echo "$TMUX_PANE" | tr -d '%')
longfile="/tmp/claude-long-${pane_key}.txt"
subjectfile="/tmp/claude-subject-${pane_key}.txt"
substartfile="/tmp/claude-substart-${pane_key}.txt"
label="claude"
_mode=$(tmux show-options -wv -t "$TMUX_PANE" "@window-claude-mode" 2>/dev/null)
case "$_mode" in work) label="claude·work" ;; personal) label="claude·pers" ;; esac
project=$(basename "$PWD" 2>/dev/null)
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
  rm -f "$longfile" "$subjectfile" "$substartfile" 2>/dev/null
  rmdir "/tmp/claude-sum-${pane_key}.lock.d" 2>/dev/null
fi

# Read the hook payload ONLY for ⚡ — that's the only state that needs the
# prompt + transcript_path (the long-summary job). Reading stdin for the
# other states would `cat`-block forever whenever the caller doesn't send
# and close a payload (only ⚡ is piped one), hanging the hook.
prompt=""
transcript=""
if [ "$emoji" = "⚡" ] && [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  payload=$(cat)
  prompt=$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null)
  transcript=$(printf '%s' "$payload" | jq -r '.transcript_path // empty' 2>/dev/null)
fi

# Precedence: 📣 (Notification = Claude idle/waiting for input) fires AFTER a
# turn ends if you don't respond promptly, and would otherwise overwrite the
# ✅/👀 done-tracking — the "tick sometimes isn't set" symptom. A done or
# blocked window already means "your move", so 📣 must not clobber ✅/👀/🔐.
# It still overwrites 🤖/⚡. Also makes the Stop(✅)-vs-Notification(📣)
# end-of-turn race order-independent.
if [ "$emoji" = "📣" ]; then
  case "$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)" in
    "✅ "*|"👀 "*|"🔐 "*) exit 0 ;;
  esac
fi

# ✅ means "done, you haven't looked". If you're already sitting on this
# window (active window of an attached session) it's been seen the moment it
# finished — emit 👀 directly; after-select-window/claude_seen.sh covers the
# "switch to it later" case.
render="$emoji"
if [ "$emoji" = "✅" ]; then
  seen=$(tmux display-message -p -t "$TMUX_PANE" '#{window_active}#{?session_attached,1,0}' 2>/dev/null)
  [ "$seen" = "11" ] && render="👀"
fi

tmux rename-window -t "$TMUX_PANE" "$render $label"

# ⚡ → 2-row summary: a stable SUBJECT (derived once from early turns,
# re-anchored when work shifts topic) + done/now/next from claude_digest.sh
# piped into claude_summarise.sh stand mode. Detached: never blocks the hook
# (cosmetic-hook contract); the foreground already did exec >/dev/null and will
# exit 0. Spawned nohup ... >/dev/null 2>&1 </dev/null & so it shares no fd
# with Claude. Up to 3 LM calls (subject-derive OR shift-candidate, then stand);
# detached + per-pane lock so latency is invisible.
SUM="${CLAUDE_SUMMARISE_BIN:-"$SCRIPT_DIR/claude_summarise.sh"}"
CTX="${CLAUDE_CTX_BIN:-"$SCRIPT_DIR/claude_ctx.sh"}"
DIG="${CLAUDE_DIGEST_BIN:-"$SCRIPT_DIR/claude_digest.sh"}"
if [ "$emoji" = "⚡" ] && [ -n "$prompt" ] && [ -x "$SUM" ] && [ -x "$CTX" ] && [ -x "$DIG" ]; then
  pfile=$(mktemp /tmp/claude-raw-XXXXXX 2>/dev/null) || pfile=""
  if [ -n "$pfile" ]; then
    printf '%s' "$prompt" > "$pfile"
    nohup sh -c '
      sum=$1; ctx=$2; tp=$3; pf=$4; lf=$5; pane=$6; sf=$7; dig=$8; ssf=$9
      cur=$(cat "$pf" 2>/dev/null); rm -f "$pf"
      recent=$("$ctx" "$tp" 6 400 tail 2>/dev/null)
      if [ -n "$recent" ] && [ -n "$cur" ]; then blob="$recent / $cur"
      elif [ -n "$cur" ]; then blob="$cur"
      else blob="$recent"; fi
      [ -n "$blob" ] || exit 0
      lock="/tmp/claude-sum-${pane}.lock.d"
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
        # is fine here: the subject is only ever LM context (CLAUDE_SUBJECT),
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
      p=$(printf "%s" "$digest" | CLAUDE_SUBJECT="$subj" "$sum" 55 stand)
      [ -n "$p" ] && printf "%s" "$p" > "$lf"
      rmdir "$lock" 2>/dev/null
    ' _ "$SUM" "$CTX" "$transcript" "$pfile" "$longfile" "$pane_key" "$subjectfile" "$DIG" "$substartfile" \
      >/dev/null 2>&1 </dev/null &
  fi
fi

if [ "$2" = "--notify" ]; then
  # Dedupe across hook types (Stop + Notification fire ~simultaneously at end of turn).
  # mkdir is atomic — only one concurrent hook process wins the claim per cooldown window.
  lockdir="/tmp/claude-notify-${pane_key}.d"
  cooldown=5

  if [ -d "$lockdir" ]; then
    now=$(date +%s)
    last=$(stat -f %m "$lockdir" 2>/dev/null || echo 0)
    if [ "$((now - last))" -lt "$cooldown" ]; then
      exit 0
    fi
    rmdir "$lockdir" 2>/dev/null
  fi

  mkdir "$lockdir" 2>/dev/null || exit 0

  osascript -e "display notification \"$3\" with title \"Claude Code\" subtitle \"$project\" sound name \"Submarine\"" 2>/dev/null
fi

exit 0
