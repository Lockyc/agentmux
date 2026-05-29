#!/bin/sh
# colours.sh — agent colour helpers. Resolve a friendly base (curated name or
# 256 code) into a tmux inactive/active style pair, and render the palette.
# Dual-use: SOURCE it for its functions (colour_derive), or EXECUTE it as a CLI
# (render | grid | names). Pure compute + ANSI; no tmux, no source-time deps.

# Curated base colours (the INACTIVE shade). name:code, one per line; this order
# is what `render`/`names` show. The active shade and the fg are derived, never
# hand-set. Every base is drawn from the cube sub-lattice where each channel is
# at level 1, 3 or 5 — `_colour_lighten` collapses {0,1}->3, {2,3}->4, {4,5}->5,
# so confining bases to {1,3,5} keeps lightening injective: distinct names can
# never derive the same active (focused-tab) colour. The "active bgs unique"
# selftest guards this; pick replacements from the same lattice if you edit it.
_colour_palette='red:203
orange:215
yellow:227
lime:155
green:83
teal:73
cyan:87
sky:75
blue:63
purple:135
magenta:207
pink:205
slate:59'

# name -> 256 code, or empty if not a known name.
_colour_name_to_code() {
  printf '%s\n' "$_colour_palette" | while IFS=: read -r n c; do
    [ "$n" = "$1" ] && { printf '%s' "$c"; break; }
  done
}

# Normalise a base (name | "colourNN" | "NN") to a numeric 256 code.
# Empty output = invalid/unknown.
_colour_resolve() {
  case "$1" in
    colour[0-9]*) printf '%s' "${1#colour}" ;;
    [0-9]*) case "$1" in *[!0-9]*) printf '' ;; *) printf '%s' "$1" ;; esac ;;
    *) _colour_name_to_code "$1" ;;
  esac
}

# Lighten a 6x6x6 cube code (16..231): raise each channel halfway to max.
# Codes outside the cube are returned unchanged.
# update_colors.sh inlines this same cube-lighten for its @l2bg shade (kept
# separate so that POSIX hook adapter stays source-dependency-free); mirror any
# change to the cube math there.
_colour_lighten() {
  c="$1"
  if [ "$c" -ge 16 ] && [ "$c" -le 231 ]; then
    v=$((c - 16)); b=$((v % 6)); g=$(((v / 6) % 6)); r=$(((v / 36) % 6))
    r=$((r + (6 - r) / 2)); [ "$r" -gt 5 ] && r=5
    g=$((g + (6 - g) / 2)); [ "$g" -gt 5 ] && g=5
    b=$((b + (6 - b) / 2)); [ "$b" -gt 5 ] && b=5
    n=$((16 + 36 * r + 6 * g + b))
    [ "$n" -eq "$c" ] && n=$((c + 6)); [ "$n" -gt 231 ] && n=231
    printf '%s' "$n"
  else
    printf '%s' "$c"
  fi
}

# Choose a legible fg (16 black / 231 white) for a bg code. The 16..255 codes
# have fixed RGB so we threshold their luminance; the 0..15 base-ANSI codes are
# terminal-theme-dependent (no fixed RGB), so classify the conventionally-light
# ones (silver/white + bright green/yellow/cyan) by index instead of computing.
_colour_fg() {
  c="$1"
  case "$c" in
    7|10|11|14|15) printf '16';  return ;;
    [0-9]|1[0-5])  printf '231'; return ;;
  esac
  if [ "$c" -ge 16 ] && [ "$c" -le 231 ]; then
    v=$((c - 16)); b=$((v % 6)); g=$(((v / 6) % 6)); r=$(((v / 36) % 6))
    R=0; [ "$r" -gt 0 ] && R=$((55 + 40 * r))
    G=0; [ "$g" -gt 0 ] && G=$((55 + 40 * g))
    B=0; [ "$b" -gt 0 ] && B=$((55 + 40 * b))
  elif [ "$c" -ge 232 ] && [ "$c" -le 255 ]; then
    L=$(((c - 232) * 10 + 8)); R=$L; G=$L; B=$L
  else
    R=0; G=0; B=0
  fi
  # Rec.601 luminance; >=140 -> black (16) text, else white (231). red (203 ->
  # R255 G95 B95, lum 142) is the tightest base — 2 above the cut — so re-eyeball
  # red if you ever nudge this threshold or swap red's code.
  lum=$(((299 * R + 587 * G + 114 * B) / 1000))
  [ "$lum" -ge 140 ] && printf '16' || printf '231'
}

# colour_derive <base> -> two lines (inactive, then active); returns 1 if invalid.
# fg is picked per shade, so a dark base (white text) and its lightened active
# shade (black text) can legibly differ — don't "unify" the fg, that regresses
# contrast on one state.
colour_derive() {
  code=$(_colour_resolve "$1")
  case "$code" in ''|*[!0-9]*) return 1 ;; esac
  { [ "$code" -ge 0 ] && [ "$code" -le 255 ]; } || return 1
  act=$(_colour_lighten "$code")
  fin=$(_colour_fg "$code")
  fac=$(_colour_fg "$act")
  printf 'fg=colour%s,bg=colour%s\n' "$fin" "$code"
  printf 'fg=colour%s,bg=colour%s,bold\n' "$fac" "$act"
}

# --- ANSI render helpers ---
_colour_swatch() { # <bg> <fg> <text>
  printf '\033[48;5;%sm\033[38;5;%sm%s\033[0m' "$1" "$2" "$3"
}

colour_render() {
  printf '%s\n' "$_colour_palette" | while IFS=: read -r n c; do
    act=$(_colour_lighten "$c")
    fin=$(_colour_fg "$c"); fac=$(_colour_fg "$act")
    printf '  %-8s ' "$n"
    _colour_swatch "$c" "$fin" " inactive "
    printf ' '
    _colour_swatch "$act" "$fac" " active "
    printf '   colour = "%s"\n' "$n"
  done
}

colour_grid() {
  i=0
  while [ "$i" -le 255 ]; do
    printf '\033[48;5;%sm\033[38;5;%sm %3d \033[0m' "$i" "$(_colour_fg "$i")" "$i"
    i=$((i + 1))
    [ $((i % 8)) -eq 0 ] && printf '\n'
  done
  [ $((i % 8)) -ne 0 ] && printf '\n'
}

colour_names() {
  printf '%s\n' "$_colour_palette" | while IFS=: read -r n c; do printf '%s\n' "$n"; done
}

# Self-test: COLOURS_SELFTEST=1 sh scripts/colours.sh
if [ "${COLOURS_SELFTEST:-}" = "1" ]; then
  pass=0; fail=0
  _assert() {
    if [ "$3" = "$2" ]; then echo "PASS: $1"; pass=$((pass + 1))
    else echo "FAIL: $1 — expected '$2' got '$3'"; fail=$((fail + 1)); fi
  }
  _assert "resolve name"     "83" "$(_colour_resolve green)"
  _assert "resolve colourNN" "37" "$(_colour_resolve colour37)"
  _assert "resolve NN"       "37" "$(_colour_resolve 37)"
  _assert "resolve bogus"    ""   "$(_colour_resolve nope)"
  colour_derive bogus >/dev/null 2>&1; _assert "derive bogus rc" "1" "$?"
  _assert "derive teal inactive" "fg=colour16,bg=colour73" "$(colour_derive teal | sed -n 1p)"
  ac=$(colour_derive teal | sed -n 2p)
  case "$ac" in *,bold) g=ok ;; *) g=bad ;; esac
  _assert "derive active bold" "ok" "$g"
  case "$ac" in fg=colour*,bg=colour*,bold) g=ok ;; *) g=bad ;; esac
  _assert "derive active shape" "ok" "$g"
  _assert "fg light bg" "16"  "$(_colour_fg 231)"
  _assert "fg dark bg"  "231" "$(_colour_fg 16)"
  # base-ANSI 0..15: light indices get black fg, the rest white.
  _assert "fg ansi white"  "16"  "$(_colour_fg 15)"
  _assert "fg ansi silver" "16"  "$(_colour_fg 7)"
  _assert "fg ansi black"  "231" "$(_colour_fg 0)"
  _assert "fg ansi blue"   "231" "$(_colour_fg 4)"
  # No two curated names may derive the same active (focused-tab) bg, nor the
  # same inactive bg — that is the whole point of per-agent colours.
  _adups() { for nm in $(colour_names); do colour_derive "$nm" | sed -n "${1}p" \
    | sed 's/.*bg=colour//; s/,bold//'; done | sort | uniq -d | tr '\n' ' '; }
  _assert "active bgs unique"   "" "$(_adups 2)"
  _assert "inactive bgs unique" "" "$(_adups 1)"
  # Cross-palette guard: every inactive tab base must stay >=2 cube-distance from
  # every status-bar colour (update_colors.sh), else a tab blends into the bar.
  # Test-only read of the sibling script — the runtime stays dependency-free.
  bars=$(sed -n "/palette='/,/'\$/p" "$(dirname "$0")/update_colors.sh" \
         | sed "s/.*palette='//; s/'\$//" | awk '{print $1}')
  # If the sibling's palette block is ever reformatted this parse yields nothing,
  # and an empty $bars makes _bar_mindist return 999 for every base — a vacuous
  # PASS that hides the very regression this guards. Fail loudly instead.
  case "$bars" in '') bguard=EMPTY ;; *) bguard=ok ;; esac
  _assert "bar palette parsed (guard not vacuous)" "ok" "$bguard"
  _bar_mindist() { # min squared cube-distance from base $1 to any bar colour
    br=$((($1-16)/36%6)); bg=$((($1-16)/6%6)); bb=$((($1-16)%6)); m=999
    for s in $bars; do
      d=$(( (br-($s-16)/36%6)*(br-($s-16)/36%6) \
          + (bg-($s-16)/6%6)*(bg-($s-16)/6%6) \
          + (bb-($s-16)%6)*(bb-($s-16)%6) ))
      [ "$d" -lt "$m" ] && m=$d
    done
    echo "$m"
  }
  worst=999; worstn=""
  for nm in $(colour_names); do
    d=$(_bar_mindist "$(_colour_resolve "$nm")")
    [ "$d" -lt "$worst" ] && { worst=$d; worstn=$nm; }
  done
  [ "$worst" -ge 2 ] && near="ok" || near="CLASH:$worstn(d=$worst)"
  _assert "tab bases clear of bar palette" "ok" "$near"
  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]; exit $?
fi

# CLI dispatch only when executed directly. Under bash/sh a sourced file keeps $0
# as the parent, so the basename guard alone suffices — but zsh sets $0 to the
# sourced file (FUNCTION_ARGZERO) and would run the CLI on `source`, dumping the
# palette into the caller. zsh marks a sourced frame with ':file' in
# ZSH_EVAL_CONTEXT; bail then. The real CLI path executes under /bin/sh, where
# ZSH_EVAL_CONTEXT is unset, so dispatch proceeds normally.
case "${0##*/}" in
  colours.sh)
    case "${ZSH_EVAL_CONTEXT:-}" in
      *:file) : ;;   # sourced into zsh — stay a no-op
      *)
        case "${1:-render}" in
          render) colour_render ;;
          grid)   colour_grid ;;
          names)  colour_names ;;
          *) echo "usage: colours.sh [render|grid|names]" >&2; exit 1 ;;
        esac
        ;;
    esac
    ;;
esac
