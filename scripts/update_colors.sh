#!/bin/sh
# Per-session tmux status-bar colour, DETERMINISTIC from the session name:
# cksum(name) % palette_size indexes a curated (bg fg) palette. Same name ->
# same colour, on every machine, forever (cksum is a stable CRC) — the
# randomColor.js "seeded, not random, curated range" idea. No special cases.
#
# Fired by the client-attached / session-created / client-session-changed
# hooks in .tmux.conf; a static `set -g status-style` is pointless, this
# overrides it per session on every attach/switch.
#
# Palette is hand-picked saturated mid/dark backgrounds, each paired with a
# legible foreground, so the bar text and #(...) right side never end up
# dark-on-dark. Add/remove lines freely; order only affects which name maps
# where, not correctness.

session="${1:-$(tmux display-message -p '#S')}"

# bg fg — one pair per line. Keep backgrounds saturated, not near-black.
palette='24 231
30 231
25 231
31 231
28 231
60 231
90 231
99 231
127 231
132 231
130 231
166 231
94 231
100 231
136 16
178 16'

count=$(printf '%s\n' "$palette" | wc -l | tr -d ' ')
sum=$(printf '%s' "$session" | cksum | cut -d' ' -f1)
idx=$(( sum % count ))
pair=$(printf '%s\n' "$palette" | sed -n "$((idx + 1))p")

bg=${pair% *}
fg=${pair#* }
tmux set -t "$session" status-style "bg=colour${bg},fg=colour${fg}"

# The summary rows (status-format[1..3]) get a SHADE of the same hue: keep
# the proven legible fg, shift the bg lightness so contrast is >= line 0 —
# darker when the fg is light (231), lighter when the fg is dark (16).
# Decompose the 6x6x6 colour cube (idx = 16 + 36r + 6g + b), scale, recompose.
# Exposed as per-session @l2bg/@l2fg, consumed by status-format[1..3] in .tmux.conf.
case "$bg" in
  ''|*[!0-9]*) bg2='' ;;
  *) if [ "$bg" -ge 16 ] && [ "$bg" -le 231 ]; then
       c=$((bg - 16)); b=$((c % 6)); g=$(((c / 6) % 6)); r=$(((c / 36) % 6))
       if [ "$fg" = 16 ]; then
         r=$((r + (6 - r) / 2)); g=$((g + (6 - g) / 2)); b=$((b + (6 - b) / 2))
         [ "$r" -gt 5 ] && r=5; [ "$g" -gt 5 ] && g=5; [ "$b" -gt 5 ] && b=5
       else
         r=$((r / 2)); g=$((g / 2)); b=$((b / 2))
       fi
       bg2=$((16 + 36 * r + 6 * g + b))
       if [ "$bg2" -eq "$bg" ]; then
         [ "$fg" = 16 ] && bg2=252 || bg2=234
       fi
     else
       bg2=''
     fi ;;
esac

if [ -n "$bg2" ]; then
  tmux set -t "$session" @l2bg "colour${bg2}"
  tmux set -t "$session" @l2fg "colour${fg}"
else
  tmux set -u -t "$session" @l2bg 2>/dev/null
  tmux set -u -t "$session" @l2fg 2>/dev/null
fi

# The 3-row AI summary block only applies to @autoagent sessions
# (the `tmc` function sets @autoagent=1). Everything else (tm and
# plain sessions) keeps a single normal status line — no summary rows,
# no wasted terminal height. `status` is a per-session option so this
# overrides the global default (1) just for tmc sessions. status 4 =
# line 0 + the 3 summary rows (status-format[1..3]).
if [ "$(tmux show-options -t "$session" -qv @autoagent 2>/dev/null)" = "1" ]; then
  tmux set -t "$session" status 4
else
  tmux set -t "$session" status on
fi
