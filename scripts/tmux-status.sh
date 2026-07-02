#!/bin/sh
# Usage: tmux-status.sh <state> [--notify <message>]
# Shared status-hook core — called by each agent's hook glue (e.g. claude/status.sh).
# The adapter sets these env vars before exec'ing this script:
#   AGENTMUX_AGENT_NAME       agent label used in tab and temp-file names (default: agent)
#   AGENTMUX_CTX_BIN          path to transcript context extractor (no default)
#   AGENTMUX_DIGEST_BIN       path to transcript digest builder (no default)
#   AGENTMUX_HOOK_PROMPT      (UserPromptSubmit only) latest user prompt; optional supplement
#   AGENTMUX_HOOK_TRANSCRIPT  (every working hook) session transcript path; drives the summary
# Two jobs:
#  1. Tab label = "<emoji> <agent>" — a STABLE, state-only tab.
#     State tokens: start working permission notify done
#     Emojis:       🤖     ⚡       🔐         📣     ✅
#  2. AI summary: stable subject + done/now/next trajectory, re-derived on
#     every working hook (UserPromptSubmit AND PostToolUse) from the transcript
#     via AGENTMUX_DIGEST_BIN + summarise.sh stand mode — so it refreshes
#     mid-turn during long autonomous runs, not only when a prompt arrives.
#
# Per-pane state files live under a per-uid runtime dir ($XDG_RUNTIME_DIR, else
# /tmp/agentmux-<uid> at mode 0700 — not world-writable /tmp), keyed by <pane_key>
# = "<hash of tmux socket>-<pane number>". The socket hash folds in server
# identity so two tmux servers' colliding %0/%1 pane numbers (guaranteed under
# `amux --frame`, where the agent runs a second tmux deep) don't clobber each
# other. summary_rows.sh MUST derive the same runtime dir + key or it can't find
# these files — keep the two in lockstep (it takes #{socket_path} as an arg).
# <runtime>/agentmux-status-<pane_key>.txt   done/now/next summary (status lines 1-3; each working hook)
# <runtime>/agentmux-diag-<pane_key>.txt     pipeline diagnostic shown when no summary yet
# <runtime>/<agent_name>-subject-<pane_key>.txt  stable subject label (derived once, re-anchored on shift)
# <runtime>/<agent_name>-substart-<pane_key>.txt subject-start line offset (scope B; written on re-anchor)
# <runtime>/agentmux-sum-<pane_key>.lock.d   summariser overlap lock
# <runtime>/agentmux-sum-<pane_key>.ts       last-refresh stamp (throttles prompt-less PostToolUse refreshes)
# <runtime>/agentmux-sum-<pane_key>.drift    consecutive-drift counter (subject re-derives only after sustained drift)
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

# Per-uid runtime dir instead of world-writable /tmp (a co-tenant could otherwise
# pre-create the fixed-name files to leak summary text or wedge locks).
runtime_dir="${XDG_RUNTIME_DIR:-/tmp/agentmux-$(id -u)}"
# -m 0700 applies the mode atomically at creation (no default-umask window). The
# parent (/tmp or /run/user) always exists, so -p only ever creates this one
# level — SC2174's "intermediate dirs skip -m" caveat can't bite here.
# shellcheck disable=SC2174
mkdir -p -m 0700 "$runtime_dir" 2>/dev/null
# If the dir already existed and isn't ours, a co-tenant squatted the predictable
# per-uid path first; writing our summaries/locks there would hand them the very
# leak the 0700 dir is meant to prevent. Fall back to a private mktemp dir (GNU
# stat first, BSD second — see the mtime footgun). The reader can't guess a mktemp
# path, so the resolved dir is published below via @amux_runtime_dir.
_rd_owner=$(stat -c %u "$runtime_dir" 2>/dev/null || stat -f %u "$runtime_dir" 2>/dev/null || echo -1)
[ "$_rd_owner" = "$(id -u)" ] || runtime_dir=$(mktemp -d "${TMPDIR:-/tmp}/agentmux.XXXXXX" 2>/dev/null) || exit 0
# Publish the resolved dir so summary_rows.sh (the reader, run from agentmux.conf
# via tmux #()) uses exactly this path instead of re-deriving it from its own
# environment — #() does NOT inherit $XDG_RUNTIME_DIR (the same reason the socket
# is passed to it). Read there as #{@amux_runtime_dir}. Global: the dir is per-uid,
# identical for every pane on this server.
tmux set-option -g @amux_runtime_dir "$runtime_dir" 2>/dev/null
# pane_key folds the tmux socket identity (first comma-field of $TMUX) into the
# pane number so two servers can't collide (see header). Whitelist-safe: cksum
# digits + '-' + pane digits. Empty $TMUX (not inside tmux) → bare pane number.
# $TMUX is guaranteed non-empty here by the guard at the top, but stay defensive.
_amux_sock="${TMUX%%,*}"
_amux_pane_num=$(printf '%s' "$TMUX_PANE" | tr -d '%')
if [ -n "$_amux_sock" ]; then
  pane_key="$(printf '%s' "$_amux_sock" | cksum | cut -d' ' -f1)-${_amux_pane_num}"
else
  pane_key="$_amux_pane_num"
fi
agent_name="${AGENTMUX_AGENT_NAME:-agent}"
longfile="$runtime_dir/agentmux-status-${pane_key}.txt"
diagfile="$runtime_dir/agentmux-diag-${pane_key}.txt"
subjectfile="$runtime_dir/${agent_name}-subject-${pane_key}.txt"
substartfile="$runtime_dir/${agent_name}-substart-${pane_key}.txt"
sumtsfile="$runtime_dir/agentmux-sum-${pane_key}.ts"
driftfile="$runtime_dir/agentmux-sum-${pane_key}.drift"
sumlockdir="$runtime_dir/agentmux-sum-${pane_key}.lock.d"
TAB_LABEL="${AGENTMUX_TAB_LABEL_BIN:-$HOME/.agentmux/scripts/tab_label.sh}"
label=$([ -x "$TAB_LABEL" ] && "$TAB_LABEL" "$agent_name" 2>/dev/null || echo "$agent_name")
# Target our own pane explicitly: an un-targeted display-message resolves against
# the most recently active client, which is the wrong session when several agent
# panes share the default socket. $TMUX_PANE is set inside the agent's pane (see
# pane_key above), so it always points at us here.
project=$(tmux display-message -t "$TMUX_PANE" -p "#{session_name}" 2>/dev/null)
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
  rm -f "$longfile" "$diagfile" "$subjectfile" "$substartfile" "$sumtsfile" "$driftfile" 2>/dev/null
  rmdir "$sumlockdir" 2>/dev/null
fi

# Hook payload is parsed by the adapter and handed in via env vars — agent
# hook schemas differ, so payload parsing lives per-adapter (e.g. claude/status.sh).
prompt="${AGENTMUX_HOOK_PROMPT:-}"
transcript="${AGENTMUX_HOOK_TRANSCRIPT:-}"

# Precedence: notify fires AFTER a turn ends if you don't respond promptly, and
# would otherwise overwrite the done/permission tracking. A done or blocked
# window already means "your move", so notify must not clobber those states.
# It still overwrites start/working. Also makes done-vs-notify race order-independent.
if [ "$emoji" = "📣" ]; then
  case "$(tmux display-message -p -t "$TMUX_PANE" '#{window_name}' 2>/dev/null)" in
    "✅ "*|"🔐 "*) exit 0 ;;
  esac
fi

tmux rename-window -t "$TMUX_PANE" "$emoji $label"

# working → AI summary: a stable SUBJECT (derived once from early turns,
# re-anchored when work shifts topic) + done/now/next from AGENTMUX_DIGEST_BIN
# piped into summarise.sh stand mode. Built from the TRANSCRIPT — the user
# prompt is only an optional supplement — so it runs on every working hook,
# including the prompt-less PostToolUse that fires throughout a long autonomous
# turn (gating on $prompt would freeze the summary between user messages).
# Detached: never blocks the hook (cosmetic-hook contract); the foreground
# already did exec >/dev/null and will exit 0. Spawned nohup ... >/dev/null
# 2>&1 </dev/null & so it shares no fd with the agent. Up to 3 LM calls
# (drift-probe, then a goal re-derive once drift is sustained, then stand);
# detached + per-pane lock so latency is invisible.
SUM="${AGENTMUX_SUMMARISE_BIN:-$HOME/.agentmux/scripts/summarise.sh}"
CTX="${AGENTMUX_CTX_BIN:-}"
DIG="${AGENTMUX_DIGEST_BIN:-}"
GATE="${AGENTMUX_STRIP_GATE_BIN:-$HOME/.agentmux/scripts/strip_unbacked_done.sh}"

# Refresh cadence + throttle. A new user prompt (UserPromptSubmit, $prompt set)
# always refreshes immediately. PostToolUse carries no $prompt and fires per
# tool call, so throttle those prompt-less refreshes to at most once per
# AGENTMUX_SUM_THROTTLE seconds (default 30) — the per-pane lock only prevents
# overlap, not frequency, and each refresh costs ~2 local-LM calls.
sum_ok=1
if [ "$emoji" = "⚡" ] && [ -z "$prompt" ]; then
  _now=$(date +%s 2>/dev/null || echo 0)
  # GNU `stat -c %Y` is tried BEFORE BSD `stat -f %m` on purpose — do not flip.
  # When a GNU-semantics stat (coreutils/uutils) shadows BSD stat in PATH,
  # `stat -f %m` reads `-f` as --file-system, exits nonzero (triggering the ||)
  # AND leaks a "File: …" block to stdout, so the two outputs concatenate into a
  # non-numeric value that breaks the arithmetic below. GNU-first avoids it:
  # `-c %Y` works under GNU, and fails cleanly (stderr only) under BSD.
  _last=$(stat -c %Y "$sumtsfile" 2>/dev/null || stat -f %m "$sumtsfile" 2>/dev/null || echo 0)
  [ "$((_now - _last))" -lt "${AGENTMUX_SUM_THROTTLE:-30}" ] && sum_ok=0
fi

if [ "$emoji" = "⚡" ] && [ -n "$transcript" ] && [ "$sum_ok" = 1 ] && [ -x "$SUM" ] && [ -x "$CTX" ] && [ -x "$DIG" ]; then
  # Stamp the attempt up front so the throttle covers failures too (don't retry
  # the LM on every tool call when it's down).
  : > "$sumtsfile" 2>/dev/null || true
  # Resolve the configured LLM URL (used for the diag-ping fallback inside the
  # detached subshell). env > [llm] in amux.toml > default.
  . "$SCRIPT_DIR/llm-config.sh"
  _amux_load_llm
  pfile=$(mktemp /tmp/agentmux-raw-XXXXXX 2>/dev/null) || pfile=""
  if [ -n "$pfile" ]; then
    printf '%s' "$prompt" > "$pfile"
    nohup sh -c '
      sum=$1; ctx=$2; tp=$3; pf=$4; lf=$5; pane=$6; sf=$7; dig=$8; ssf=$9; llm_url=${10}; gate=${11}; dcf=${12}; rtd=${13}
      cur=$(cat "$pf" 2>/dev/null); rm -f "$pf"
      recent=$("$ctx" "$tp" 6 400 tail 2>/dev/null)
      if [ -n "$recent" ] && [ -n "$cur" ]; then blob="$recent / $cur"
      elif [ -n "$cur" ]; then blob="$cur"
      else blob="$recent"; fi
      [ -n "$blob" ] || exit 0
      lock="$rtd/agentmux-sum-${pane}.lock.d"
      mkdir "$lock" 2>/dev/null || exit 0

      # GOAL context for the subject: early intent (read from the session START,
      # so it captures the stated goal even on long sessions) + the agent task
      # list (the umbrella goal). Deliberately EXCLUDES recent activity: folding
      # recent in narrows the subject to the current subtask (the exact drift we
      # are avoiding — e.g. "tiptap editor" degrading to "init destroy race
      # guard"). Recent is used only for the drift probe below and for the
      # done/now/next stand line. "plan:" is a process word the label prompt is
      # told to ignore, so it cues the model without leaking into the title.
      early=$("$ctx" "$tp" 8 300 head 2>/dev/null)
      todos=$("$ctx" "$tp" 12 120 todos 2>/dev/null)
      goal="$early"
      [ -n "$todos" ] && goal="${goal:+$goal / }plan: $todos"
      [ -n "$goal" ] || goal="$blob"

      subj=$(cat "$sf" 2>/dev/null)
      if [ -z "$subj" ]; then
        # No subject yet: derive once the early window has enough signal
        # (>= 6 substantive post-filter user turns, roughly the first 20%),
        # from the broad GOAL context above.
        if [ -n "$early" ]; then
          seps=$(printf "%s" "$early" | grep -o " / " | wc -l | tr -d " ")
          segs=$(( ${seps:-0} + 1 ))
        else
          segs=0
        fi
        if [ "$segs" -ge 6 ]; then
          subj=$(printf "%s" "$goal" | "$sum" 6 label)
          [ -n "$subj" ] && printf "%s" "$subj" > "$sf"
        fi
      else
        # Subject set: probe whether recent work has moved off the subject. If
        # the recent candidate shares no >3-char content word with it, that is
        # ONE drift tick (persisted in $dcf). Only after AGENTMUX_SUM_DRIFT
        # consecutive ticks (a SUSTAINED move, not a brief subtask dive) do we
        # re-derive — and we re-derive from the broad GOAL context, never the
        # bare recent slice, so the new subject stays goal-level. Any overlap
        # resets the counter. (The subject is only ever LM context via
        # AGENTMUX_SUBJECT, never rendered as a tmux label, so punctuation is
        # harmless here.)
        cand=$(printf "%s" "$blob" | "$sum" 6 label)
        if [ -n "$cand" ]; then
          sl=" $(printf "%s" "$subj" | tr "A-Z" "a-z" | tr -cs "a-z0-9" " ") "
          ov=
          for w in $(printf "%s" "$cand" | tr "A-Z" "a-z" | tr -cs "a-z0-9" " "); do
            [ "${#w}" -gt 3 ] || continue
            case "$sl" in *" $w "*) ov=1; break ;; esac
          done
          if [ -n "$ov" ]; then
            rm -f "$dcf"
          else
            dc=$(cat "$dcf" 2>/dev/null); case "$dc" in ""|*[!0-9]*) dc=0 ;; esac
            dc=$((dc + 1))
            if [ "$dc" -ge "${AGENTMUX_SUM_DRIFT:-3}" ]; then
              # Sustained drift: re-derive the subject from the broad GOAL
              # context. Only replace + re-anchor the digest window when the
              # goal actually CHANGED (a real pivot). A long subtask dive within
              # the same goal re-derives to the same subject, so keep the
              # trajectory window intact and just clear the counter.
              new=$(printf "%s" "$goal" | "$sum" 6 label)
              if [ -n "$new" ]; then
                if [ "$new" != "$subj" ]; then
                  subj="$new"
                  printf "%s" "$subj" > "$sf"
                  # Re-anchor the digest offset so done/now/next cover only the
                  # new slice, not the whole session.
                  wc -l < "$tp" 2>/dev/null | tr -d " " > "$ssf"
                fi
                rm -f "$dcf"
              fi
            else
              printf "%s" "$dc" > "$dcf"
            fi
          fi
        fi
      fi

      start=$(cat "$ssf" 2>/dev/null)
      case "$start" in ""|*[!0-9]*) start=1 ;; esac
      digest=$("$dig" "$tp" "$start" 10000 2>/dev/null)
      [ -n "$digest" ] || digest="$blob"
      df="$rtd/agentmux-diag-${pane}.txt"
      p=$(printf "%s" "$digest" | AGENTMUX_SUBJECT="$subj" "$sum" 55 stand)
      # Defence-in-depth: strip any "done:" clause the model invented despite
      # the prompt, when the digest has no file-mutation evidence (edited or
      # wrote). Bash "ran:" is intentionally NOT evidence here, since read-only
      # investigation is the failure shape this gate catches.
      # See scripts/strip_unbacked_done.sh for the full rationale.
      [ -n "$p" ] && [ -x "$gate" ] && p=$("$gate" "$digest" "$p")
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
    ' _ "$SUM" "$CTX" "$transcript" "$pfile" "$longfile" "$pane_key" "$subjectfile" "$DIG" "$substartfile" "$_llm_url" "$GATE" "$driftfile" "$runtime_dir" \
      >/dev/null 2>&1 </dev/null &
  fi
elif [ "$emoji" = "⚡" ] && [ -n "$transcript" ] && [ -x "$SUM" ]; then
  [ -x "$CTX" ] || printf 'ctx: AGENTMUX_CTX_BIN not set\n' > "$diagfile"
  [ -x "$DIG" ] || printf 'digest: AGENTMUX_DIGEST_BIN not set\n' > "$diagfile"
fi

# Count nested tmux layers between this pane and the real terminal. A single tmux
# passthrough envelope only escapes ONE layer; under `amux --frame` the agent runs
# inside two tmux servers (frame + agent), so an OSC wrapped once is unwrapped by
# the inner (agent) tmux and then SWALLOWED by the outer (frame) tmux, never
# reaching the host terminal. We must wrap once per layer. Walk outward: our
# current tmux's client tty is a pane in the next tmux out; follow that until a
# client tty belongs to no tmux (the real terminal). Falls back to 1 if anything
# is unknown — i.e. the plain single-tmux behaviour.
_tmux_nest_depth() {
  [ -n "${TMUX:-}" ] || { echo 0; return; }
  _nd_sock=${TMUX%%,*}
  _nd_dir=$(dirname "$_nd_sock")
  _nd_depth=1
  # Target our own pane explicitly (same reason as `project` above): an un-targeted
  # display-message resolves against the most recently active client, which is the
  # wrong session when several agent panes share the default socket.
  _nd_client=$(tmux display-message -t "$TMUX_PANE" -p '#{client_tty}' 2>/dev/null)
  while [ -n "$_nd_client" ]; do
    _nd_next=''
    for _nd_s in "$_nd_dir"/*; do
      [ -S "$_nd_s" ] || continue
      [ "$_nd_s" = "$_nd_sock" ] && continue
      # A pane in $_nd_s whose tty is our current client tty ⇒ we're displayed
      # inside that tmux ⇒ one more layer. Exact tty match, so no false hits.
      _nd_pane=$(tmux -S "$_nd_s" list-panes -a -F '#{pane_tty} #{pane_id}' 2>/dev/null \
                 | awk -v t="$_nd_client" '$1==t{print $2; exit}')
      [ -n "$_nd_pane" ] || continue
      _nd_next=$(tmux -S "$_nd_s" display-message -p -t "$_nd_pane" '#{client_tty}' 2>/dev/null)
      _nd_sock=$_nd_s
      break
    done
    [ -n "$_nd_next" ] || break
    _nd_depth=$((_nd_depth + 1))
    _nd_client=$_nd_next
  done
  echo "$_nd_depth"
}

if [ "$2" = "--notify" ]; then
  # Dedupe across hook types (done + notify fire ~simultaneously at end of turn).
  # mkdir is atomic — only one concurrent hook process wins the claim per cooldown window.
  lockdir="$runtime_dir/${agent_name}-notify-${pane_key}.d"
  cooldown=5

  if [ -d "$lockdir" ]; then
    now=$(date +%s)
    last=$(stat -c %Y "$lockdir" 2>/dev/null \
        || stat -f %m "$lockdir" 2>/dev/null \
        || echo 0)
    if [ "$((now - last))" -lt "$cooldown" ]; then
      exit 0
    fi
    rmdir "$lockdir" 2>/dev/null
  fi

  mkdir "$lockdir" 2>/dev/null || exit 0

  # Notify *through the terminal*, not via osascript: emit an OSC 777 desktop-notification escape so
  # a notification-aware host (warden) badges THIS agent's tab + raises a banner, tied to the pane it
  # came from. We're inside tmux, so wrap it in tmux's passthrough envelope (needs `allow-passthrough
  # on`, set in agentmux.conf): DCS `tmux;` + the payload with every ESC doubled + ST. Wrap ONCE PER
  # NESTED TMUX LAYER (see _tmux_nest_depth) — each layer strips one envelope, so under `--frame`
  # (frame tmux → agent tmux) a single wrap is unwrapped by the agent tmux and then dropped by the
  # frame tmux before it can reach the host. Write to the pane's own tty (#{pane_tty}) so it flows up
  # through tmux regardless of where the hook's stdout points. `;` is the OSC field separator, and
  # control chars (ESC/BEL/…) could terminate the OSC early or inject their own escapes — strip both
  # from title/body so an arbitrary message can't break out of the sequence (this also keeps the
  # payload ESC-free, so only the wrap envelopes carry ESCs to double). A non-warden / non-OSC-777
  # terminal just ignores it (osascript trade-off).
  title=$(printf '%s · %s' "$agent_name" "$project" | LC_ALL=C tr -d ';[:cntrl:]')
  body=$(printf '%s' "$3" | LC_ALL=C tr -d ';[:cntrl:]')
  pane_tty=$(tmux display-message -t "$TMUX_PANE" -p '#{pane_tty}' 2>/dev/null)
  if [ -n "$pane_tty" ]; then
    osc=$(printf '\033]777;notify;%s;%s\007' "$title" "$body")
    depth=$(_tmux_nest_depth)
    [ "${depth:-1}" -ge 1 ] || depth=1
    while [ "$depth" -gt 0 ]; do
      # Double the ESCs already in $osc (data to this layer), then wrap in this
      # layer's passthrough envelope (its own ESCs stay single).
      osc=$(printf '%s' "$osc" | awk 'BEGIN{E=sprintf("%c",27); RS="\1"; ORS=""}{gsub(E,E E); printf "\033Ptmux;%s\033\\", $0}')
      depth=$((depth - 1))
    done
    printf '%s' "$osc" > "$pane_tty"
  fi
fi

exit 0
