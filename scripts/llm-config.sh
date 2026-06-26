#!/bin/sh
# llm-config.sh — source this; do not execute directly.
# Resolves the [llm] settings into _llm_url / _llm_model / _llm_timeout.
# Precedence: AGENTMUX_LLM_URL / AGENTMUX_LLM_MODEL / AGENTMUX_LLM_TIMEOUT
# env vars > [llm] in amux.toml > built-in defaults.
# Also exposes _amux_config_json — a shared config-JSON loader used by
# _amux_load_llm and other [section] consumers (e.g. version_check.sh's
# [update] check).
# Reads the disk cache (config-<mtime>.json under XDG_CACHE_HOME) populated
# by agentmux-config.sh; falls back to live toml2json if cache is cold.
# Pure POSIX sh — safe to source from /bin/sh scripts.

# Echo the parsed amux.toml as JSON — disk cache (config-<mtime>.json under
# XDG_CACHE_HOME) if present, else live toml2json. Empty output + non-zero if the
# config is missing or no parser is available. Shared by _amux_load_llm and other
# [section] consumers (e.g. version_check.sh's [update] check).
_amux_config_json() {
  _cfg="${AGENTMUX_CONFIG:-$HOME/.agentmux/amux.toml}"
  [ -f "$_cfg" ] || return 1
  _mtime=$(stat -c %Y "$_cfg" 2>/dev/null || stat -f %m "$_cfg" 2>/dev/null || echo 0)
  _cache="${XDG_CACHE_HOME:-$HOME/.cache}/agentmux/config-${_mtime}.json"
  if [ -f "$_cache" ]; then
    cat "$_cache"
  elif command -v toml2json >/dev/null 2>&1; then
    toml2json < "$_cfg" 2>/dev/null
  else
    return 1
  fi
}

_amux_load_llm() {
  _llm_url=""; _llm_model=""; _llm_timeout=""
  _json=$(_amux_config_json)
  if [ -n "$_json" ] && command -v jq >/dev/null 2>&1; then
    _out=$(printf '%s' "$_json" \
      | jq -r '.llm.url // empty, .llm.model // empty, .llm.timeout // empty' 2>/dev/null)
    _llm_url=$(printf '%s\n' "$_out"     | sed -n '1p')
    _llm_model=$(printf '%s\n' "$_out"   | sed -n '2p')
    _llm_timeout=$(printf '%s\n' "$_out" | sed -n '3p')
  fi
  _llm_url="${AGENTMUX_LLM_URL:-${_llm_url:-http://localhost:1234/v1/chat/completions}}"
  _llm_model="${AGENTMUX_LLM_MODEL:-${_llm_model:-qwen2.5-14b-instruct}}"
  _llm_timeout="${AGENTMUX_LLM_TIMEOUT:-${_llm_timeout:-20}}"
  case "$_llm_timeout" in ''|*[!0-9.]*) _llm_timeout=20 ;; esac
}
