#!/bin/sh
# Flip a "done / unviewed" Claude window (✅) to "seen" (👀) the moment the
# user selects it. This is herdr's Done→Idle distinction: ✅ means "finished,
# you haven't looked", 👀 means "finished, acknowledged" — so a wall of
# windows can be triaged at a glance and read ones stop shouting.
#
# Invoked by the after-select-window tmux hook with the now-current window's
# id and name. Only ✅ flips: 🔐 (blocked) stays put because selecting the
# window doesn't unblock Claude, and ⚡/🤖/👀 need no transition. The next
# Claude hook (⚡/✅) overwrites the name again, so the cycle self-resets.

win="$1"
name="$2"

case "$name" in
  "✅ "*) tmux rename-window -t "$win" "👀 ${name#✅ }" ;;
esac
