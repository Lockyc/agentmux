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

  local json _tmp
  json=$(toml2json < "$AGENTMUX_CONFIG") || {
    echo "agentmux: failed to parse $AGENTMUX_CONFIG" >&2; return 1
  }
  _amux_json_cache="$json"
  mkdir -p "$cache_dir" 2>/dev/null
  find "$cache_dir" -maxdepth 1 -name 'config-*.json' -delete 2>/dev/null
  # Write via tmp + rename so concurrent readers see either no file (and
  # fall through to live toml2json) or the complete new one, never a partial.
  _tmp="$cache_file.tmp.$$"
  printf '%s' "$json" > "$_tmp" 2>/dev/null && mv "$_tmp" "$cache_file" 2>/dev/null
  rm -f "$_tmp" 2>/dev/null
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

# Name of the agent whose `dirs` matches the given directory, or empty if none.
# A pattern matches when <dir> equals it or is a subdirectory of it; `~` expands
# to $HOME and trailing slashes are ignored. When several patterns match, the
# longest (most specific) wins; ties resolve to the first agent in file order.
# Usage: agentmux_agent_for_dir <dir>
agentmux_agent_for_dir() {
  _amux_json | jq -r --arg dir "$1" --arg home "$HOME" '
    [ .agents[]
      | .name as $name
      | (.dirs // [])[]
      | (gsub("^~"; $home) | rtrimstr("/")) as $pat
      | select($dir == $pat or ($dir | startswith($pat + "/")))
      | {name: $name, len: ($pat | length)}
    ]
    | (map(.len) | max) as $m
    | map(select(.len == $m)) | first | .name // empty
  '
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

# Field value from [frame] table. Returns empty string if field absent.
# Usage: agentmux_frame_field <field>
agentmux_frame_field() {
  _amux_json | jq -r ".frame.${1} // empty"
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
  # First phase asserts against the shipped example config (pinned values);
  # second phase (line ~170 onward) uses a synthetic config to cover every
  # keep_alive/reattach branch independent of what the example ships with.
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
  _assert "agent_count"         "4"        "$(agentmux_agent_count)"
  _assert "first_agent"         "personal" "$(agentmux_first_agent)"
  _assert "field name[0]"       "personal" "$(agentmux_agent_field 0 name)"
  _assert "field flag[0]"       "p"        "$(agentmux_agent_field 0 flag)"
  _assert "field absent"        ""         "$(agentmux_agent_field 0 keep_alive)"
  _assert "find_by_name work"   "1"        "$(agentmux_find_by_name work)"
  _assert "find_by_name miss"   "-1"       "$(agentmux_find_by_name doesnotexist)"
  _assert "find_by_flag w"      "1"        "$(agentmux_find_by_flag w)"
  _assert "find_by_flag o"      "3"        "$(agentmux_find_by_flag o)"
  _assert "find_by_flag miss"   "-1"       "$(agentmux_find_by_flag z)"
  _assert "next_agent work"     "ollama"   "$(agentmux_next_agent work)"
  _assert "next_agent ollama"   "opencode" "$(agentmux_next_agent ollama)"
  _assert "next_agent wraps"    "personal" "$(agentmux_next_agent opencode)"
  _assert "next_agent unknown"  "personal" "$(agentmux_next_agent unknown)"
  _assert "dir exact match"     "work"     "$(agentmux_agent_for_dir "$HOME/work")"
  _assert "dir subtree match"   "work"     "$(agentmux_agent_for_dir "$HOME/work/sub/x")"
  _assert "dir second pattern"  "work"     "$(agentmux_agent_for_dir "$HOME/clients/acme")"
  _assert "dir other agent"     "personal" "$(agentmux_agent_for_dir "$HOME/personal/proj")"
  _assert "dir no match"        ""         "$(agentmux_agent_for_dir "$HOME/nowhere")"
  _assert "dir prefix not partial" "" "$(agentmux_agent_for_dir "$HOME/workspace")"
  completions=$(agentmux_list_agent_completions)
  _assert "completions work"    "work"     "$(printf '%s\n' "$completions" | grep '^work$')"
  _assert "completions -w"      "-w"       "$(printf '%s\n' "$completions" | grep '^-w$')"
  _assert "completions ollama"  "ollama"   "$(printf '%s\n' "$completions" | grep '^ollama$')"
  _assert "completions opencode" "opencode" "$(printf '%s\n' "$completions" | grep '^opencode$')"
  _assert "build_cmd work"      "CLAUDE_CONFIG_DIR=~/.claude-work claude" "$(agentmux_build_cmd 1)"
  _assert "build_cmd ollama"    'ollama launch claude --model kimi-k2.6:cloud' "$(agentmux_build_cmd 2)"
  _assert "build_cmd opencode"  "opencode" "$(agentmux_build_cmd 3)"
  _assert "llm_field url"       "http://localhost:1234/v1/chat/completions" "$(agentmux_llm_field url)"
  _assert "llm_field model"     "qwen2.5-14b-instruct"                     "$(agentmux_llm_field model)"
  _assert "llm_field timeout"   "20"                                        "$(agentmux_llm_field timeout)"
  _assert "llm_field absent"    ""                                          "$(agentmux_llm_field nonexistent)"
  _assert "frame_field left"    "30"                                        "$(agentmux_frame_field left)"
  _assert "frame_field absent"  ""                                          "$(agentmux_frame_field nonexistent)"

  # Self-contained coverage for agentmux_build_cmd's keep_alive/reattach
  # wrapping — exercises every branch without depending on the example
  # config carrying those optional fields.
  _tmpcfg=$(mktemp /tmp/agentmux-selftest-XXXXXX.toml) || exit 1
  cat > "$_tmpcfg" <<'TOML'
[[agents]]
name = "wrapped"
cmd = "myagent run"
keep_alive = true
reattach = true

[[agents]]
name = "keep"
cmd = "myagent serve"
keep_alive = true

[[agents]]
name = "warn"
cmd = "myagent oops"
reattach = true

[[agents]]
name = "bare"
cmd = "myagent"
TOML
  AGENTMUX_CONFIG="$_tmpcfg"
  _amux_json_cache=""
  _assert "build_cmd keep_alive+reattach"  'myagent run; exec reattach-to-user-namespace -l $SHELL' "$(agentmux_build_cmd 0)"
  _assert "build_cmd keep_alive only"      'myagent serve; exec $SHELL'                              "$(agentmux_build_cmd 1)"
  _assert "build_cmd reattach-only stdout" 'myagent oops'                                            "$(agentmux_build_cmd 2 2>/dev/null)"
  _err=$(agentmux_build_cmd 2 2>&1 >/dev/null)
  case "$_err" in *"reattach=true requires keep_alive=true"*) _got="warns" ;; *) _got="silent" ;; esac
  _assert "build_cmd reattach-only warns"  "warns"                                                   "$_got"
  _assert "build_cmd bare"                 'myagent'                                                 "$(agentmux_build_cmd 3)"
  # Tidy: mktemp file + the disk cache entry it produced. The mtime-keyed
  # cache cleanup runs on next access anyway, but explicit is friendlier.
  _tmp_mtime=$(stat -f %m "$_tmpcfg" 2>/dev/null || stat -c %Y "$_tmpcfg" 2>/dev/null || echo 0)
  rm -f "$_tmpcfg" "${XDG_CACHE_HOME:-$HOME/.cache}/agentmux/config-${_tmp_mtime}.json"

  # Self-contained coverage for agentmux_agent_for_dir's resolution rules —
  # absolute paths (no ~) so it doesn't depend on $HOME. Covers longest-prefix
  # precedence, subtree fallback to a broader rule, and same-length ties
  # resolving to the first agent in file order.
  _dircfg=$(mktemp /tmp/agentmux-dir-XXXXXX.toml) || exit 1
  cat > "$_dircfg" <<'TOML'
[[agents]]
name = "broad"
cmd = "x"
dirs = ["/tmp/amux-route"]

[[agents]]
name = "narrow"
cmd = "x"
dirs = ["/tmp/amux-route/deep"]

[[agents]]
name = "tieA"
cmd = "x"
dirs = ["/tmp/amux-tie"]

[[agents]]
name = "tieB"
cmd = "x"
dirs = ["/tmp/amux-tie"]
TOML
  AGENTMUX_CONFIG="$_dircfg"
  _amux_json_cache=""
  _assert "dir longest prefix wins" "narrow" "$(agentmux_agent_for_dir /tmp/amux-route/deep/x)"
  _assert "dir broad subtree"       "broad"  "$(agentmux_agent_for_dir /tmp/amux-route/other)"
  _assert "dir tie first in file"   "tieA"   "$(agentmux_agent_for_dir /tmp/amux-tie/z)"
  _assert "dir routing no match"    ""       "$(agentmux_agent_for_dir /tmp/elsewhere)"
  _dir_mtime=$(stat -f %m "$_dircfg" 2>/dev/null || stat -c %Y "$_dircfg" 2>/dev/null || echo 0)
  rm -f "$_dircfg" "${XDG_CACHE_HOME:-$HOME/.cache}/agentmux/config-${_dir_mtime}.json"

  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]
fi
