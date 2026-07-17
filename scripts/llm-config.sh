#!/bin/sh
# llm-config.sh — source this; do not execute directly.
# Resolves the [llm] settings into _llm_url / _llm_model / _llm_timeout.
# Precedence: AGENTMUX_LLM_URL / AGENTMUX_LLM_MODEL / AGENTMUX_LLM_TIMEOUT
# env vars > [llm] in amux.toml > built-in defaults.
# Also exposes _amux_config_json — a shared config-JSON loader used by
# _amux_load_llm and other [section] consumers (e.g. version_check.sh's
# [update] check).
# Reads the disk cache (config-<phash>-<mtime>.json under XDG_CACHE_HOME) populated
# by agentmux-config.sh; falls back to live toml2json if cache is cold.
# Pure POSIX sh — safe to source from /bin/sh scripts.

# Echo the parsed amux.toml as JSON — disk cache (config-<phash>-<mtime>.json under
# XDG_CACHE_HOME) if present, else live toml2json. Empty output + non-zero if the
# config is missing or no parser is available. Shared by _amux_load_llm and other
# [section] consumers (e.g. version_check.sh's [update] check).
_amux_config_json() {
  _cfg="${AGENTMUX_CONFIG:-$HOME/.agentmux/amux.toml}"
  [ -f "$_cfg" ] || return 1
  _mtime=$(stat -c %Y "$_cfg" 2>/dev/null || stat -f %m "$_cfg" 2>/dev/null || echo 0)
  # Key must match agentmux-config.sh's _amux_json (the cache writer): PATH hash
  # (cksum, no extra dep) + mtime. Keying on mtime alone aliases distinct configs
  # sharing a one-second mtime; a divergent key here would silently miss the cache.
  _phash=$(printf '%s' "$_cfg" | cksum | cut -d' ' -f1)
  _cache="${XDG_CACHE_HOME:-$HOME/.cache}/agentmux/config-${_phash}-${_mtime}.json"
  if [ -f "$_cache" ] && [ -s "$_cache" ]; then
    cat "$_cache"
  elif command -v toml2json >/dev/null 2>&1; then
    toml2json < "$_cfg" 2>/dev/null
  else
    return 1
  fi
}

# LLM_CONFIG_SELFTEST=1 — asserts the positional read below survives a [llm]
# block that omits fields. Guards the `// ""` vs `// empty` trap: with `empty`,
# a config setting only some keys shifts the rest into the wrong variables and
# the summary silently dies. Executed, not sourced (see CLAUDE.md "Selftests").
if [ "${LLM_CONFIG_SELFTEST:-}" = "1" ]; then
  _fail=0
  _t() { # _t <toml-body> <expected url> <expected model> <expected timeout>
    _d=$(mktemp -d); printf '[llm]\n%s\n' "$1" > "$_d/amux.toml"
    # LLM_CONFIG_SELFTEST= in the child is LOAD-BEARING, not tidiness: the child
    # re-sources THIS file, so an inherited =1 re-enters this block and forks
    # again — seven cases per level makes it a 7-ary fork bomb that exhausts
    # kern.maxprocperuid within seconds (fork() then fails machine-wide while
    # CPU and RAM sit idle). Same guard as summarise.sh's SUMMARISE_SMOKE.
    _got=$(AGENTMUX_CONFIG="$_d/amux.toml" LLM_CONFIG_SELFTEST='' \
      AGENTMUX_LLM_URL='' AGENTMUX_LLM_MODEL='' AGENTMUX_LLM_TIMEOUT='' \
      sh -c '. "$0"; _amux_load_llm; printf "%s|%s|%s" "$_llm_url" "$_llm_model" "$_llm_timeout"' "$0")
    rm -rf "$_d"
    if [ "$_got" != "$2|$3|$4" ]; then
      echo "selftest FAIL [$1]: want [$2|$3|$4] got [$_got]" >&2; _fail=1
    fi
  }
  _DU=http://localhost:1234/v1/chat/completions
  _DM=qwen2.5-14b-instruct
  # Every partial block must land each key in its OWN variable, missing ones
  # falling back to defaults — not shifting into the next slot.
  _t 'model = "M"'                        "$_DU" "M"  "20"
  _t 'timeout = 99'                       "$_DU" "$_DM" "99"
  _t 'url = "U"'                          "U"    "$_DM" "20"
  _t 'model = "M"
timeout = 99'                             "$_DU" "M"  "99"
  _t 'url = "U"
model = "M"
timeout = 99'                             "U"    "M"  "99"
  # Empty [llm] block -> all defaults.
  _t ''                                   "$_DU" "$_DM" "20"
  # Non-numeric timeout is rejected back to the default.
  _t 'timeout = "abc"'                    "$_DU" "$_DM" "20"
  [ "$_fail" = 0 ] && echo "selftest OK"
  exit "$_fail"
fi

_amux_load_llm() {
  _llm_url=""; _llm_model=""; _llm_timeout=""
  _json=$(_amux_config_json)
  if [ -n "$_json" ] && command -v jq >/dev/null 2>&1; then
    # `// ""` (not `// empty`) is load-bearing: these three are read POSITIONALLY
    # below, and `empty` emits NO line for a missing key — so a config setting
    # only some of them silently shifts every later field into the wrong
    # variable (a [llm] block with model+timeout but no url assigned the model
    # to _llm_url and the timeout to _llm_model, leaving the summary dead).
    # `// ""` always emits exactly three lines, so position always holds.
    _out=$(printf '%s' "$_json" \
      | jq -r '[.llm.url // "", .llm.model // "", .llm.timeout // ""] | .[]' 2>/dev/null)
    _llm_url=$(printf '%s\n' "$_out"     | sed -n '1p')
    _llm_model=$(printf '%s\n' "$_out"   | sed -n '2p')
    _llm_timeout=$(printf '%s\n' "$_out" | sed -n '3p')
  fi
  _llm_url="${AGENTMUX_LLM_URL:-${_llm_url:-http://localhost:1234/v1/chat/completions}}"
  _llm_model="${AGENTMUX_LLM_MODEL:-${_llm_model:-qwen2.5-14b-instruct}}"
  _llm_timeout="${AGENTMUX_LLM_TIMEOUT:-${_llm_timeout:-20}}"
  case "$_llm_timeout" in ''|*[!0-9.]*) _llm_timeout=20 ;; esac
}
