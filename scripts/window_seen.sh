#!/bin/sh
# window_seen.sh — flip a "done / unviewed" window (✅) to "seen" (👀).
# Invoked by the after-select-window tmux hook with the now-current window's
# id and name. Agents signal completion by prefixing the window name with ✅;
# selecting the window acknowledges it. Only ✅ flips: other states need no
# transition. The next agent hook overwrites the name, so the cycle self-resets.

win="$1"
name="$2"

case "$name" in
  "✅ "*) tmux rename-window -t "$win" "👀 ${name#✅ }" ;;
esac
