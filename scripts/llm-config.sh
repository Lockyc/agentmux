#!/bin/sh
# llm-config.sh — source this; do not execute directly.
# Resolves the [llm] settings into _llm_url / _llm_model / _llm_timeout.
# Precedence: AGENTMUX_LLM_URL / AGENTMUX_LLM_MODEL / AGENTMUX_LLM_TIMEOUT
# env vars > [llm] in agents.toml > built-in defaults.
# Reads the disk cache (config-<mtime>.json under XDG_CACHE_HOME) populated
# by agentmux-config.sh; falls back to live toml2json if cache is cold.
# Pure POSIX sh — safe to source from /bin/sh scripts.

_amux_load_llm() {
  _llm_url=""; _llm_model=""; _llm_timeout=""
  _cfg="${AGENTMUX_CONFIG:-$HOME/.agentmux/agents.toml}"
  if [ -f "$_cfg" ]; then
    _mtime=$(stat -f %m "$_cfg" 2>/dev/null \
          || stat -c %Y "$_cfg" 2>/dev/null \
          || echo 0)
    _cache="${XDG_CACHE_HOME:-$HOME/.cache}/agentmux/config-${_mtime}.json"
    _json=""
    if [ -f "$_cache" ]; then
      _json=$(cat "$_cache")
    elif command -v toml2json >/dev/null 2>&1; then
      _json=$(toml2json < "$_cfg" 2>/dev/null || true)
    fi
    if [ -n "$_json" ] && command -v jq >/dev/null 2>&1; then
      _out=$(printf '%s' "$_json" \
        | jq -r '.llm.url // empty, .llm.model // empty, .llm.timeout // empty' 2>/dev/null)
      _llm_url=$(printf '%s\n' "$_out"     | sed -n '1p')
      _llm_model=$(printf '%s\n' "$_out"   | sed -n '2p')
      _llm_timeout=$(printf '%s\n' "$_out" | sed -n '3p')
    fi
  fi
  _llm_url="${AGENTMUX_LLM_URL:-${_llm_url:-http://localhost:1234/v1/chat/completions}}"
  _llm_model="${AGENTMUX_LLM_MODEL:-${_llm_model:-qwen2.5-14b-instruct}}"
  _llm_timeout="${AGENTMUX_LLM_TIMEOUT:-${_llm_timeout:-20}}"
  case "$_llm_timeout" in ''|*[!0-9.]*) _llm_timeout=20 ;; esac
}
