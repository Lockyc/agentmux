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
#
# Each line is `bg fg name`. The trailing `name` lets a project pin this slot via
# [amux.dirs."<dir>"].colour; names are appended LAST so every positional `bg fg`
# parse (and the colours.sh cross-palette selftest's `awk '{print $1}'`) is
# unaffected.
palette='24 231 blue
30 231 teal
25 231 cobalt
31 231 cyan
28 231 green
90 231 purple
127 231 magenta
132 231 rose
130 231 rust
166 231 orange
94 231 brown
100 231 olive
136 16 amber
178 16 gold'

count=$(printf '%s\n' "$palette" | wc -l | tr -d ' ')

# Bar-palette name -> 0-based slot index (empty if unknown). Slot = line number-1,
# matching @l1idx and _amux_pick_slot's index space.
_bar_name_to_slot() {
  printf '%s\n' "$palette" | awk -v want="$1" '$3 == want { print NR - 1; exit }'
}

# Bar-palette slot index -> name (empty if out of range).
_bar_slot_name() {
  printf '%s\n' "$palette" | awk -v i="$1" 'NR == i + 1 { print $3; exit }'
}

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
  bg=${pair%% *}; rest=${pair#* }; fg=${rest%% *}
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
    data=$1 reserved=$2 oi=$IFS; IFS='
'
    u=' '
    for _r in $reserved; do u="$u$_r "; done
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

  # Bar palette names resolve to stable slots and round-trip.
  _assert "name->slot blue is 0"   "0"  "$(_bar_name_to_slot blue)"
  _assert "name->slot gold is last" "$((count - 1))" "$(_bar_name_to_slot gold)"
  _assert "name->slot unknown empty" ""  "$(_bar_name_to_slot nosuchcolour)"
  _assert "slot->name 0 is blue"   "blue" "$(_bar_slot_name 0)"
  _assert "slot->name round-trip"  "teal" "$(_bar_slot_name "$(_bar_name_to_slot teal)")"

  # A lone newcomer takes its cksum-preferred slot.
  _assert "newcomer takes preferred slot" "$(_pref agentmux)" \
    "$(_get "$(_sim 'agentmux:')" agentmux)"

  # Global reservation: a slot reserved via @l1reserved is avoided by a newcomer
  # that prefers it, even though NO live session holds that slot.
  _rp=$(_pref locus)
  _assert "newcomer avoids reserved slot (no live holder)" "no" \
    "$([ "$(_get "$(_sim 'locus:' "$_rp")" locus)" = "$_rp" ] && echo yes || echo no)"

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

# The hook body: reconcile every coloured session's bar colour. Exposed as a
# function so bin/amux can SOURCE this file for _bar_name_to_slot without running
# it — the dispatch guard below only calls this when the file is executed directly.
_amux_reconcile() {
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

  # Pass 1: collect the slots already FROZEN onto live sessions plus the globally
  # RESERVED slots (pins from [amux.dirs.*].colour, published by bin/amux as the
  # global @l1reserved). Both are fixed points the newcomer probe must avoid — the
  # reserved set keeps a pinned colour out of the pool even when its project is not
  # running.
  used=' '
  res=$(tmux show-options -gqv @l1reserved 2>/dev/null)
  for r in $res; do
    case "$r" in ''|*[!0-9]*) ;; *) used="$used$r " ;; esac
  done
  for s in $names; do
    [ -n "$s" ] || continue
    fi=$(tmux show-options -t "$s" -qv @l1idx 2>/dev/null)
    case "$fi" in ''|*[!0-9]*) ;; *) used="$used$fi " ;; esac
  done

  # Pass 2: repaint everyone. A session with a frozen slot is painted from it as-is;
  # a newcomer (no @l1idx, or one whose creation hook raced) de-dups against every
  # claimed/reserved slot, stores its pick, and joins the fixed points.
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
}

# Dispatch only when executed directly, never when sourced (so bin/amux can source
# this file for its resolvers). Mirror colours.sh's guard: under bash/sh a sourced
# file keeps $0 as the parent, so the basename guard suffices — but zsh sets $0 to
# the sourced file, so also bail on a zsh ':file' eval context.
case "${0##*/}" in
  update_colors.sh)
    case "${ZSH_EVAL_CONTEXT:-}" in
      *:file) : ;;
      *) _amux_reconcile "$@" ;;
    esac
    ;;
esac
