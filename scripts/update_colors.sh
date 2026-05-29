#!/bin/sh
# Per-session tmux status-bar colour, DETERMINISTIC from the session name:
# cksum(name) % palette_size picks a curated (bg fg) slot. Same name -> same
# colour, on every machine (cksum is a stable CRC) — the randomColor.js
# "seeded, not random, curated range" idea.
#
# A plain name-hash pigeonholes, though: two distinct names can cksum to the
# same slot (e.g. agentmux & reductable). So the slot is COLLISION-RESOLVED —
# each coloured session linear-probes from its preferred slot past slots already
# claimed by other coloured sessions, keeping distinct sessions on distinct
# colours while their count stays <= the palette size. The assignment is a pure
# function of the sorted set of coloured session names, so adding/removing a
# session can reshuffle slots; to stop that leaving a stale, now-colliding colour
# on a session whose hook didn't re-fire, every hook RECONCILES all coloured
# sessions, not just the one that triggered it.
#
# Fired by the client-attached / session-created / client-session-changed
# hooks in .tmux.conf; a static `set -g status-style` is pointless, this
# overrides it per session on every attach/switch.
#
# Palette is hand-picked saturated mid/dark backgrounds, each paired with a
# legible foreground, so the bar text and #(...) right side never end up
# dark-on-dark. Add/remove lines freely; order only affects which name maps
# where, not correctness.

# bg fg — one pair per line. Keep backgrounds saturated, not near-black.
# Must stay >=2 cube-distance from every agent tab base (colours.sh
# _colour_palette), or an inactive window tab blends into the bar. colour60
# (vs slate) and colour99 (vs blue/purple) are deliberately omitted for that
# reason; the "tab bases clear of bar palette" selftest in colours.sh enforces it.
palette='24 231
30 231
25 231
31 231
28 231
90 231
127 231
132 231
130 231
166 231
94 231
100 231
136 16
178 16'

count=$(printf '%s\n' "$palette" | wc -l | tr -d ' ')

# Collision-resolved palette index, a pure function of the sorted set of coloured
# session names read on stdin (one per line). Each name probes from its own
# cksum-preferred slot to the next free one, so distinct sessions land on distinct
# palette entries while their count stays <= <count>; beyond that, reuse is
# unavoidable and it wraps. Deterministic given the same session set.
#   printf '%s\n' "$sorted_names" | _amux_assign_idx <target> <count>
_amux_assign_idx() {
  target=$1 cnt=$2 used=' ' ans=''
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    i=$(( $(printf '%s' "$s" | cksum | cut -d' ' -f1) % cnt ))
    n=0
    while [ "$n" -lt "$cnt" ]; do
      case "$used" in
        *" $i "*) i=$(( (i + 1) % cnt )); n=$(( n + 1 )) ;;
        *) break ;;
      esac
    done
    used="$used$i "
    [ "$s" = "$target" ] && ans=$i
  done
  printf '%s' "$ans"
}

# Apply the bar colour for session $1 using palette slot $2.
_amux_apply_colour() {
  s=$1 i=$2
  pair=$(printf '%s\n' "$palette" | sed -n "$((i + 1))p")
  bg=${pair% *}
  fg=${pair#* }
  tmux set -t "$s" status-style "bg=colour${bg},fg=colour${fg}"

  # The summary rows (status-format[1..3]) get a SHADE of the same hue: keep
  # the proven legible fg, shift the bg lightness so contrast is >= line 0 —
  # darker when the fg is light (231), lighter when the fg is dark (16).
  # Decompose the 6x6x6 colour cube (idx = 16 + 36r + 6g + b), scale, recompose.
  # The fg=16 (lighten) branch mirrors colours.sh `_colour_lighten`; keep them in
  # step if you change the cube math. Exposed as per-session @l2bg/@l2fg, consumed
  # by status-format[1..3] in .tmux.conf.
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
    tmux set -t "$s" @l2bg "colour${bg2}"
    tmux set -t "$s" @l2fg "colour${fg}"
  else
    tmux set -u -t "$s" @l2bg 2>/dev/null
    tmux set -u -t "$s" @l2fg 2>/dev/null
  fi

  tmux set -t "$s" status-right-length 24
  tmux set -t "$s" status-right "#{?@agent-mode,[ #{@agent-mode} ] ,}#{?window_zoomed_flag,🔍 ,}"
  tmux set -t "$s" status 4
}

# Drop the bar overrides for session $1 (non-autoagent sessions).
_amux_clear_colour() {
  s=$1
  tmux set -u -t "$s" status-style 2>/dev/null
  tmux set -u -t "$s" status-right-length 2>/dev/null
  tmux set -u -t "$s" status-right 2>/dev/null
  tmux set -u -t "$s" @l2bg 2>/dev/null
  tmux set -u -t "$s" @l2fg 2>/dev/null
  tmux set -t "$s" status on
}

# Self-test: UPDATE_COLORS_SELFTEST=1 sh scripts/update_colors.sh
if [ "${UPDATE_COLORS_SELFTEST:-}" = "1" ]; then
  pass=0; fail=0
  _assert() {
    if [ "$3" = "$2" ]; then echo "PASS: $1"; pass=$((pass + 1))
    else echo "FAIL: $1 — expected '$2' got '$3'"; fail=$((fail + 1)); fi
  }
  _pref() { echo $(( $(printf '%s' "$1" | cksum | cut -d' ' -f1) % count )); }
  _idx()  { printf '%s\n' "$2" | _amux_assign_idx "$1" "$count"; }

  # The reported regression: agentmux & reductable both prefer the same slot.
  names='agentmux
lockyc
locus
reductable'
  _assert "agentmux & reductable collide (pure hash)" "yes" \
    "$([ "$(_pref agentmux)" = "$(_pref reductable)" ] && echo yes || echo no)"
  a=$(_idx agentmux "$names"); r=$(_idx reductable "$names")
  _assert "collision-resolved: distinct slots" "no" \
    "$([ "$a" = "$r" ] && echo yes || echo no)"
  _assert "preferred slot kept when free (agentmux)" "$(_pref agentmux)" "$a"
  # Deterministic: same set -> same answer on recompute.
  _assert "deterministic" "$a" "$(_idx agentmux "$names")"
  # All four live sessions land on four distinct slots.
  l=$(_idx lockyc "$names"); o=$(_idx locus "$names")
  _assert "all four distinct" "4" "$(printf '%s\n%s\n%s\n%s\n' "$a" "$r" "$l" "$o" | sort -u | wc -l | tr -d ' ')"
  # A full palette of distinct sessions fills every slot exactly once.
  big=$(i=0; while [ "$i" -lt "$count" ]; do echo "s$i"; i=$((i + 1)); done)
  got=$(for s in $big; do _idx "$s" "$big"; echo; done | sort -un | wc -l | tr -d ' ')
  _assert "full palette: all slots unique" "$count" "$got"

  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]; exit $?
fi

session="${1:-$(tmux display-message -p '#S')}"

# Coloured (autoagent) sessions, sorted so the assignment is order-independent.
names=$(tmux list-sessions -F '#{?@autoagent,#S,}' 2>/dev/null | grep . | sort)

# Reconcile EVERY coloured session to the current global assignment (see header).
printf '%s\n' "$names" | while IFS= read -r s; do
  [ -n "$s" ] || continue
  idx=$(printf '%s\n' "$names" | _amux_assign_idx "$s" "$count")
  # Guard against a not-yet-registered session (hook racing session creation).
  [ -n "$idx" ] || idx=$(( $(printf '%s' "$s" | cksum | cut -d' ' -f1) % count ))
  _amux_apply_colour "$s" "$idx"
done

# If the triggering session is not (or no longer) autoagent, clear its overrides.
if [ "$(tmux show-options -t "$session" -qv @autoagent 2>/dev/null)" != "1" ]; then
  _amux_clear_colour "$session"
fi
