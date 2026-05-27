#!/usr/bin/env bash
# agentmux-config.sh — source this; do not execute directly.
# Provides config reader functions. Requires: toml2json, jq.
# Override config path: export AGENTMUX_CONFIG=<path>

AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/agents.toml}"

_amux_json_cache=""
_amux_json() {
  if [ -n "$_amux_json_cache" ]; then
    printf '%s' "$_amux_json_cache"; return 0
  fi

  # Disk cache in a user-private dir, keyed on config mtime.
  # Avoids toml2json on every hook invocation (in-memory cache only lives per-process).
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentmux"
  local mtime
  mtime=$(stat -f %m "$AGENTMUX_CONFIG" 2>/dev/null \
       || stat -c %Y "$AGENTMUX_CONFIG" 2>/dev/null \
       || echo "0")
  local cache_file="$cache_dir/config-${mtime}.json"

  if [ -f "$cache_file" ]; then
    _amux_json_cache=$(cat "$cache_file")
    printf '%s' "$_amux_json_cache"; return 0
  fi

  local json
  json=$(toml2json < "$AGENTMUX_CONFIG") || {
    echo "agentmux: failed to parse $AGENTMUX_CONFIG" >&2; return 1
  }
  _amux_json_cache="$json"
  mkdir -p "$cache_dir" 2>/dev/null
  find "$cache_dir" -maxdepth 1 -name 'config-*.json' -delete 2>/dev/null
  printf '%s' "$json" > "$cache_file" 2>/dev/null || true
  printf '%s' "$json"
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

# Name of the first agent (default for bare amux).
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

# Newline-separated list of agent names and -<flag> shortcuts for shell completions.
agentmux_list_agent_completions() {
  _amux_json | jq -r '.agents[] | .name, (if .flag then "-" + .flag else empty end)'
}

# Field value from [llm] table. Returns empty string if field absent.
# Usage: agentmux_llm_field <field>
agentmux_llm_field() {
  _amux_json | jq -r ".llm.${1} // empty"
}

# Build the launch command for agent at index, applying keep_alive/reattach wrappers.
# Warns to stderr if reattach=true without keep_alive=true.
agentmux_build_cmd() {
  local idx="$1"
  local cmd keep_alive reattach
  cmd=$(agentmux_agent_field "$idx" cmd)
  keep_alive=$(agentmux_agent_field "$idx" keep_alive)
  reattach=$(agentmux_agent_field "$idx" reattach)

  if [ "$reattach" = "true" ] && [ "$keep_alive" != "true" ]; then
    local name
    name=$(agentmux_agent_field "$idx" name)
    echo "agentmux: agent '$name': reattach=true requires keep_alive=true (reattach ignored)" >&2
  fi

  if [ "$keep_alive" = "true" ]; then
    if [ "$reattach" = "true" ]; then
      cmd="$cmd; exec reattach-to-user-namespace -l \$SHELL"
    else
      cmd="$cmd; exec \$SHELL"
    fi
  fi

  printf '%s' "$cmd"
}

# Self-test: AGENTMUX_CONFIG_SELFTEST=1 bash scripts/agentmux-config.sh
if [ "${AGENTMUX_CONFIG_SELFTEST:-}" = "1" ]; then
  # Run against the example config so assertions are config-independent.
  _selftest_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  AGENTMUX_CONFIG="$_selftest_dir/../config/agents.toml.example"
  _amux_json_cache=""
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
  completions=$(agentmux_list_agent_completions)
  _assert "completions work"    "work"     "$(printf '%s\n' "$completions" | grep '^work$')"
  _assert "completions -w"      "-w"       "$(printf '%s\n' "$completions" | grep '^-w$')"
  _assert "completions ollama"  "ollama"   "$(printf '%s\n' "$completions" | grep '^ollama$')"
  _assert "build_cmd work"      "CLAUDE_CONFIG_DIR=~/.claude-work claude" "$(agentmux_build_cmd 0)"
  _assert "build_cmd ollama"    'ollama run llama3.2; exec reattach-to-user-namespace -l $SHELL' "$(agentmux_build_cmd 2)"
  _assert "llm_field url"       "http://localhost:1234/v1/chat/completions" "$(agentmux_llm_field url)"
  _assert "llm_field model"     "qwen2.5-14b-instruct"                     "$(agentmux_llm_field model)"
  _assert "llm_field timeout"   "20"                                        "$(agentmux_llm_field timeout)"
  _assert "llm_field absent"    ""                                          "$(agentmux_llm_field nonexistent)"
  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]
fi
