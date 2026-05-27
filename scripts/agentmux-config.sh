#!/usr/bin/env bash
# agentmux-config.sh — source this; do not execute directly.
# Provides config reader functions. Requires: toml2json, jq.
# Override config path: export AGENTMUX_CONFIG=<path>

AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/agents.toml}"

_amux_json_cache=""
_amux_json() {
  if [ -z "$_amux_json_cache" ]; then
    _amux_json_cache=$(toml2json < "$AGENTMUX_CONFIG") || {
      echo "agentmux: failed to parse $AGENTMUX_CONFIG" >&2; return 1
    }
  fi
  printf '%s' "$_amux_json_cache"
}

# Number of agents defined in config.
agentmux_agent_count() {
  _amux_json | jq '.agents | length'
}

# Field value for agent at 0-based index. Returns empty string if field absent.
# Usage: agentmux_agent_field <index> <field>
agentmux_agent_field() {
  _amux_json | jq -r ".agents[$1].${2} // empty"
}

# Name of the first agent (default for bare tmc).
agentmux_first_agent() {
  agentmux_agent_field 0 name
}

# 0-based index of agent with given name, or -1 if not found.
agentmux_find_by_name() {
  local name="$1" count i
  count=$(agentmux_agent_count)
  for i in $(seq 0 $((count - 1))); do
    [ "$(agentmux_agent_field "$i" name)" = "$name" ] && echo "$i" && return 0
  done
  echo "-1"
}

# 0-based index of agent with given flag, or -1 if not found.
agentmux_find_by_flag() {
  local flag="$1" count i
  count=$(agentmux_agent_count)
  for i in $(seq 0 $((count - 1))); do
    [ "$(agentmux_agent_field "$i" flag)" = "$flag" ] && echo "$i" && return 0
  done
  echo "-1"
}

# Name of the agent that follows the given agent name in the list (wraps around).
# Usage: agentmux_next_agent <current_name>
agentmux_next_agent() {
  local current="$1" count idx next_idx
  count=$(agentmux_agent_count)
  idx=$(agentmux_find_by_name "$current")
  if [ "$idx" = "-1" ]; then
    agentmux_first_agent; return 0
  fi
  next_idx=$(( (idx + 1) % count ))
  agentmux_agent_field "$next_idx" name
}

# Self-test: AGENTMUX_CONFIG_SELFTEST=1 bash scripts/agentmux-config.sh
if [ "${AGENTMUX_CONFIG_SELFTEST:-}" = "1" ]; then
  pass=0; fail=0
  _assert() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
      echo "PASS: $desc"; pass=$((pass+1))
    else
      echo "FAIL: $desc — expected '$expected' got '$actual'"; fail=$((fail+1))
    fi
  }
  _assert "agent_count"         "3"        "$(agentmux_agent_count)"
  _assert "first_agent"         "work"     "$(agentmux_first_agent)"
  _assert "field name[0]"       "work"     "$(agentmux_agent_field 0 name)"
  _assert "field flag[1]"       "p"        "$(agentmux_agent_field 1 flag)"
  _assert "field keep_alive[2]" "true"     "$(agentmux_agent_field 2 keep_alive)"
  _assert "field absent"        ""         "$(agentmux_agent_field 0 keep_alive)"
  _assert "find_by_name work"   "0"        "$(agentmux_find_by_name work)"
  _assert "find_by_name miss"   "-1"       "$(agentmux_find_by_name doesnotexist)"
  _assert "find_by_flag w"      "0"        "$(agentmux_find_by_flag w)"
  _assert "find_by_flag miss"   "-1"       "$(agentmux_find_by_flag z)"
  _assert "next_agent work"     "personal" "$(agentmux_next_agent work)"
  _assert "next_agent wraps"    "work"     "$(agentmux_next_agent ollama)"
  _assert "next_agent unknown"  "work"     "$(agentmux_next_agent unknown)"
  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]
fi
