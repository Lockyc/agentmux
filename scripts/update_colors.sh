#!/bin/sh
# Per-session tmux status-bar colour, assigned ONCE at a session's birth and then
# FROZEN for that session's lifetime — a session's colour never moves while it
# lives, no matter what other agent sessions start or stop.
#
# A session's preferred slot is cksum(name) % palette_size: a stable CRC, so the
# same name prefers the same curated (bg fg) slot on every machine — the
# randomColor.js "seeded, not random, curated range" idea. But a plain name-hash
# pigeonholes: two distinct names can cksum to the same slot (e.g. agentmux &
# reductable). So a NEW session DE-DUPS AT BIRTH — it linear-probes from its
# preferred slot past every slot already claimed by a live session and takes the
# first free one. That chosen slot is stored on the session (@l1idx) and never
# recomputed: existing sessions are fixed points; newcomers fill the gaps around
# them. Killing a session frees its slot for the next newcomer without disturbing
# anyone else, which is what keeps live sessions' colours stable.
#
# Fired by the client-attached / session-created / client-session-changed hooks in
# .tmux.conf. Each fire reconciles every coloured session, but reconciliation only
# ASSIGNS sessions that lack a stored @l1idx (newcomers, or one whose creation hook
# raced); already-assigned sessions are repainted from their frozen slot, never
# reshuffled. A static `set -g status-style` is pointless; this overrides it per
# session on every attach/switch.
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

# Pick a palette slot for a newcomer: probe from its cksum-preferred slot past
# every slot already taken, returning the first free one. <used> is a space-padded
# list of claimed slots (" 2 5 "); if all <cnt> slots are taken the palette is
# exhausted and it returns the (now-colliding) preferred slot. Pure; deterministic
# given the same name and used-set.
#   _amux_pick_slot <name> <cnt> <used>
_amux_pick_slot() {
  nm=$1 cnt=$2 used=$3
  i=$(( $(printf '%s' "$nm" | cksum | cut -d' ' -f1) % cnt ))
  n=0
  while [ "$n" -lt "$cnt" ]; do
    case "$used" in
      *" $i "*) i=$(( (i + 1) % cnt )); n=$(( n + 1 )) ;;
      *) break ;;
    esac
  done
  printf '%s' "$i"
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
  # Drop the frozen slot too: a session that is no longer autoagent should carry no
  # marker, so if it is ever re-promoted it re-assigns (de-dups) fresh at that birth.
  tmux set -u -t "$s" @l1idx 2>/dev/null
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

  # Simulate the runtime's two-pass reconcile without tmux. Input: newline-separated
  # "name:frozenidx" lines (no ':' or empty after ':' = a newcomer to assign).
  # Output: "name=idx" lines. Mirrors the live loop exactly, so it exercises the
  # real _amux_pick_slot and the frozen-vs-newcomer split.
  _sim() {
    data=$1 oi=$IFS; IFS='
'
    u=' '
    for ln in $data; do
      nm=${ln%%:*}; fi=${ln#*:}; [ "$fi" = "$ln" ] && fi=''
      case "$fi" in ''|*[!0-9]*) ;; *) u="$u$fi " ;; esac
    done
    out=''
    for ln in $data; do
      nm=${ln%%:*}; fi=${ln#*:}; [ "$fi" = "$ln" ] && fi=''
      case "$fi" in
        ''|*[!0-9]*) idx=$(_amux_pick_slot "$nm" "$count" "$u"); u="$u$idx " ;;
        *) idx=$fi ;;
      esac
      out="$out$nm=$idx
"
    done
    IFS=$oi; printf '%s' "$out"
  }
  _get() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

  # A lone newcomer takes its cksum-preferred slot.
  _assert "newcomer takes preferred slot" "$(_pref agentmux)" \
    "$(_get "$(_sim 'agentmux:')" agentmux)"

  # De-dup at birth: agentmux & reductable both PREFER the same slot, but two
  # newcomers must still land on distinct slots.
  _assert "agentmux & reductable collide (pure hash)" "yes" \
    "$([ "$(_pref agentmux)" = "$(_pref reductable)" ] && echo yes || echo no)"
  o=$(_sim 'agentmux:
reductable:')
  _assert "newcomers de-dup at birth" "no" \
    "$([ "$(_get "$o" agentmux)" = "$(_get "$o" reductable)" ] && echo yes || echo no)"

  # The whole point: a FROZEN slot never moves when other sessions come or go.
  # agentmux is pinned to 0; adding two newcomers must not budge it, and they must
  # avoid it.
  o=$(_sim 'agentmux:0
lockyc:
reductable:')
  _assert "frozen slot unmoved by newcomers" "0" "$(_get "$o" agentmux)"
  _assert "newcomer avoids frozen slot (lockyc)" "no" \
    "$([ "$(_get "$o" lockyc)" = "0" ] && echo yes || echo no)"
  _assert "newcomer avoids frozen slot (reductable)" "no" \
    "$([ "$(_get "$o" reductable)" = "0" ] && echo yes || echo no)"

  # Removing a session frees its slot without touching the survivor: agentmux pinned
  # to 0 stays at 0 whether or not reductable is present.
  solo=$(_get "$(_sim 'agentmux:0')" agentmux)
  _assert "survivor unmoved when peer removed" "0" "$solo"

  # A full palette of distinct newcomers fills every slot exactly once.
  big=$(i=0; while [ "$i" -lt "$count" ]; do echo "s$i:"; i=$((i + 1)); done)
  got=$(_sim "$big" | sed 's/.*=//' | sort -un | wc -l | tr -d ' ')
  _assert "full palette: all slots unique" "$count" "$got"

  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]; exit $?
fi

# Triggering session, passed by the hook (#{session_name}). NOT resolved with an
# un-targeted display-message: that picks the most recently active client, so the
# wrong session would be cleared when several agent sessions share the socket. The
# reconcile loop below colours every session regardless; $session only scopes the
# demote-cleanup, which is simply skipped when no session was passed (manual runs).
session="${1:-}"

# Coloured (autoagent) sessions, sorted so a batch of simultaneous newcomers picks
# slots in a stable order. Iterated with IFS=newline so names with spaces survive.
names=$(tmux list-sessions -F '#{?@autoagent,#S,}' 2>/dev/null | grep . | sort)
oldifs=$IFS
IFS='
'

# Pass 1: collect the slots already FROZEN onto live sessions. These are fixed
# points — never recomputed — which is what keeps a session's colour stable for
# its whole life regardless of who else starts or stops.
used=' '
for s in $names; do
  [ -n "$s" ] || continue
  fi=$(tmux show-options -t "$s" -qv @l1idx 2>/dev/null)
  case "$fi" in ''|*[!0-9]*) ;; *) used="$used$fi " ;; esac
done

# Pass 2: repaint everyone. A session with a frozen slot is painted from it as-is;
# a newcomer (no @l1idx, or one whose creation hook raced) de-dups against every
# claimed slot, stores its pick, and joins the fixed points.
for s in $names; do
  [ -n "$s" ] || continue
  fi=$(tmux show-options -t "$s" -qv @l1idx 2>/dev/null)
  case "$fi" in
    ''|*[!0-9]*)
      idx=$(_amux_pick_slot "$s" "$count" "$used")
      used="$used$idx "
      tmux set -t "$s" @l1idx "$idx"
      ;;
    *) idx=$fi ;;
  esac
  _amux_apply_colour "$s" "$idx"
done
IFS=$oldifs

# If the triggering session is not (or no longer) autoagent, clear its overrides.
if [ -n "$session" ] && [ "$(tmux show-options -t "$session" -qv @autoagent 2>/dev/null)" != "1" ]; then
  _amux_clear_colour "$session"
fi
