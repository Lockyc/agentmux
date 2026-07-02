#!/bin/sh
# clear_icon.sh — one-shot dismiss of the current tab's state emoji.
# Strips the leading "<emoji> " that tmux-status.sh prepends to the window name,
# leaving just the label (e.g. "✅ claude·foo" → "claude·foo"). It's one-shot: the
# next status hook re-applies an emoji as normal. No-op on a window with no emoji.
#
# Usage: clear_icon.sh [target]
#   target: tmux -t value (a window id like @3); defaults to the current window
#           via $TMUX_PANE. The prefix-v binding in agentmux.conf passes #{window_id}.
#
# Emoji-agnostic by design — no hardcoded emoji list to keep in sync with
# tmux-status.sh. It leans on that script's invariant: the window name is always
# "<emoji> <label>" where <label> begins with AGENTMUX_AGENT_NAME (an identifier,
# so an ASCII [A-Za-z0-9_.-]). Therefore "first char is NOT an identifier char"
# reliably means an emoji is present, and stripping up to the first space removes
# ONLY the emoji — even when the label itself contains spaces (the emoji's trailing
# space is always the first one).

# _strip_emoji NAME — echo NAME with a leading "<emoji> " removed, or NAME unchanged
# if it already starts with the ASCII label (no emoji). Pure compute; unit-tested.
_strip_emoji() {
  case "$1" in
    [A-Za-z0-9_.-]*) printf '%s' "$1" ;;   # already plain → no-op
    *' '*)           printf '%s' "${1#* }" ;; # emoji + space → drop through first space
    *)               printf '%s' "$1" ;;   # non-ASCII start, no space → leave as-is
  esac
}

# --- selftest: CLEAR_ICON_SELFTEST=1 sh scripts/clear_icon.sh ---
if [ "${CLEAR_ICON_SELFTEST:-}" = "1" ]; then
  pass=0; fail=0
  _assert() {
    if [ "$3" = "$2" ]; then pass=$((pass+1)); echo "PASS: $1"
    else fail=$((fail+1)); echo "FAIL: $1 — expected '$2' got '$3'"; fi
  }
  _assert "strips working emoji"        "claude·foo"          "$(_strip_emoji "⚡ claude·foo")"
  _assert "strips done emoji"           "claude·foo"          "$(_strip_emoji "✅ claude·foo")"
  _assert "strips permission emoji"     "claude"              "$(_strip_emoji "🔐 claude")"
  _assert "label with spaces preserved" "claude·my long lbl"  "$(_strip_emoji "📣 claude·my long lbl")"
  _assert "already plain is no-op"      "claude·foo"          "$(_strip_emoji "claude·foo")"
  _assert "plain, no separator"         "claude"              "$(_strip_emoji "claude")"
  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]; exit
fi

[ -z "$TMUX" ] && exit 0

target="${1:-$TMUX_PANE}"
[ -z "$target" ] && exit 0

name=$(tmux display-message -t "$target" -p '#{window_name}' 2>/dev/null)
[ -z "$name" ] && exit 0

stripped=$(_strip_emoji "$name")
# Only rename when something actually changed — avoids a redundant rename-window
# (and the automatic-rename churn it can trigger) on an already-clear window.
[ "$stripped" != "$name" ] && tmux rename-window -t "$target" "$stripped"
exit 0
