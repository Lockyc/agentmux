#!/bin/sh
# colours.sh — agent colour helpers. Resolve a friendly base (curated name or
# 256 code) into a tmux inactive/active style pair, and render the palette.
# Dual-use: SOURCE it for its functions (colour_derive), or EXECUTE it as a CLI
# (render | grid | names). Pure compute + ANSI; no tmux, no source-time deps.

# Curated base colours (the INACTIVE shade). name:code, one per line; this order
# is what `render`/`names` show. Backgrounds are saturated mid cube colours; the
# active shade and the fg are derived, never hand-set.
_colour_palette='green:82
lime:154
teal:37
cyan:44
blue:33
indigo:63
purple:99
violet:135
magenta:169
pink:211
red:203
orange:208
amber:214
yellow:178
slate:60'

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

# Choose a legible fg (16 black / 231 white) for a bg code by luminance.
_colour_fg() {
  c="$1"
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
  lum=$(((299 * R + 587 * G + 114 * B) / 1000))
  [ "$lum" -ge 140 ] && printf '16' || printf '231'
}

# colour_derive <base> -> two lines (inactive, then active); returns 1 if invalid.
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
  _assert "resolve name"     "82" "$(_colour_resolve green)"
  _assert "resolve colourNN" "37" "$(_colour_resolve colour37)"
  _assert "resolve NN"       "37" "$(_colour_resolve 37)"
  _assert "resolve bogus"    ""   "$(_colour_resolve nope)"
  colour_derive bogus >/dev/null 2>&1; _assert "derive bogus rc" "1" "$?"
  _assert "derive teal inactive" "fg=colour231,bg=colour37" "$(colour_derive teal | sed -n 1p)"
  ac=$(colour_derive teal | sed -n 2p)
  case "$ac" in *,bold) g=ok ;; *) g=bad ;; esac
  _assert "derive active bold" "ok" "$g"
  case "$ac" in fg=colour*,bg=colour*,bold) g=ok ;; *) g=bad ;; esac
  _assert "derive active shape" "ok" "$g"
  _assert "fg light bg" "16"  "$(_colour_fg 231)"
  _assert "fg dark bg"  "231" "$(_colour_fg 16)"
  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]; exit $?
fi

# CLI dispatch only when executed directly (not when sourced: $0 is the parent).
case "${0##*/}" in
  colours.sh)
    case "${1:-render}" in
      render) colour_render ;;
      grid)   colour_grid ;;
      names)  colour_names ;;
      *) echo "usage: colours.sh [render|grid|names]" >&2; exit 1 ;;
    esac
    ;;
esac
