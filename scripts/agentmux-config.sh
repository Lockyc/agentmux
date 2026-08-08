#!/usr/bin/env bash
# agentmux-config.sh — source this; do not execute directly.
# Provides config reader functions. Requires: toml2json, jq.
# Override config path: export AGENTMUX_CONFIG=<path>

AGENTMUX_CONFIG="${AGENTMUX_CONFIG:-$HOME/.agentmux/amux.toml}"

# One-time migration for installs that crossed the agents.toml -> amux.toml rename
# via `git pull` / `amux --update` (neither re-runs install.sh). Runs from the
# freshly-pulled code at config-resolution time — the only place that can self-heal
# the rename it ships. Default location only; a custom AGENTMUX_CONFIG is the user's.
# Race-safe: concurrent tmux-hook consumers may both attempt it; the loser's mv no-ops.
if [ "$AGENTMUX_CONFIG" = "$HOME/.agentmux/amux.toml" ] \
   && [ ! -f "$AGENTMUX_CONFIG" ] && [ -f "$HOME/.agentmux/agents.toml" ]; then
  mv "$HOME/.agentmux/agents.toml" "$AGENTMUX_CONFIG" 2>/dev/null || true
fi

_amux_json_cache=""
_amux_json() {
  if [ -n "$_amux_json_cache" ]; then
    printf '%s' "$_amux_json_cache"; return 0
  fi

  # Disk cache in a user-private dir, keyed on config PATH + mtime.
  # Avoids toml2json on every hook invocation (in-memory cache only lives per-process).
  # The path hash (cksum, no extra dep) is load-bearing: keying on mtime alone
  # aliases two different configs whose mtimes land in the same second, serving
  # one project's agents for another. Must match llm-config.sh's _amux_config_json.
  local cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/agentmux"
  local mtime phash
  mtime=$(stat -c %Y "$AGENTMUX_CONFIG" 2>/dev/null \
       || stat -f %m "$AGENTMUX_CONFIG" 2>/dev/null \
       || echo "0")
  phash=$(printf '%s' "$AGENTMUX_CONFIG" | cksum | cut -d' ' -f1)
  local cache_file="$cache_dir/config-${phash}-${mtime}.json"

  if [ -f "$cache_file" ]; then
    _amux_json_cache=$(cat "$cache_file")
    # A non-empty read only: a concurrent find -delete (below) in the window
    # between [ -f ] and cat yields "", which must NOT be cached as a valid
    # parse — fall through to live toml2json instead.
    if [ -n "$_amux_json_cache" ]; then
      printf '%s' "$_amux_json_cache"; return 0
    fi
  fi

  local json _tmp
  json=$(toml2json < "$AGENTMUX_CONFIG") || {
    echo "agentmux: failed to parse $AGENTMUX_CONFIG" >&2; return 1
  }
  _amux_json_cache="$json"
  mkdir -p "$cache_dir" 2>/dev/null
  # Only prune this config's own stale entries, not every config's.
  find "$cache_dir" -maxdepth 1 -name "config-${phash}-*.json" -delete 2>/dev/null
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

# ---------------------------------------------------------------------------
# [[hosts]] — remote machines reachable with `amux @<name>`.
#
# Auth is deliberately absent from this schema: no user/port/key/password field
# exists or may be added. `ssh` names an ssh target or a ~/.ssh/config Host
# alias, and ssh owns everything about reaching it — one home for those facts,
# and no credential ever lands in amux.toml.
#
# `(.hosts // [])` throughout: a config with no [[hosts]] block is the normal
# case (every install predating this feature), and must read as zero hosts
# rather than a jq null error.
# ---------------------------------------------------------------------------

# Number of remote hosts defined in config.
agentmux_host_count() {
  _amux_json | jq '(.hosts // []) | length'
}

# Field value for host at 0-based index. Empty string if absent.
# Usage: agentmux_host_field <index> <field>
agentmux_host_field() {
  _amux_json | jq -r "(.hosts // [])[$1].${2} // empty"
}

# 0-based index of the host with the given name, or -1 if not found.
agentmux_find_host_by_name() {
  _amux_json | jq -r --arg n "$1" '
    [ (.hosts // []) | to_entries[] | select(.value.name == $n) | .key ]
    | first // -1'
}

# Roots for host at 0-based index, one per line, in config order.
# `~` is NOT expanded here — these paths name directories on the REMOTE box, so
# expanding against the local $HOME would be wrong whenever the two differ.
# The remote sh expands them (see _rm_preflight_script).
agentmux_host_roots() {
  _amux_json | jq -r "((.hosts // [])[$1].roots // [])[]"
}

# All host names, one per line, config order (drives @<TAB> completion).
agentmux_host_names() {
  _amux_json | jq -r '(.hosts // [])[].name // empty'
}

# Name of the agent whose `dirs` matches the given directory, or empty if none.
# A pattern matches when <dir> equals it or is a subdirectory of it; `~` expands
# to $HOME and trailing slashes are ignored. When several patterns match, the
# longest (most specific) wins; ties resolve to the first agent in file order.
# Usage: agentmux_agent_for_dir <dir>
agentmux_agent_for_dir() {
  _amux_json | jq -r --arg dir "$1" --arg home "$HOME" '
    [ (.agents // [])[]
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
  _amux_json | jq -r '(.agents // [])[] | .name, (if .flag then "-" + .flag else empty end)'
}

# Field value from [llm] table. Returns empty string if field absent.
# Usage: agentmux_llm_field <field>
agentmux_llm_field() {
  _amux_json | jq -r ".llm.${1} // empty"
}

# Field value from a directory-scoped config table, optionally directory-scoped.
# Usage: _agentmux_scoped_field <table> <field> [dir]
#
# Shared engine for tables that support a base block plus per-directory override
# sub-blocks (currently [frame], [amux] and [notes]). With <dir>: per-field override
# resolution. Each [<table>.dirs."<path>"] block whose path matches <dir> (same
# rules as agentmux_agent_for_dir: ~→$HOME, trailing slash ignored, equal-or-
# subtree match) is a candidate *for fields it actually sets*; the longest
# matching path wins. A field no block sets falls back to the base
# [<table>].<field>. Cascade is per-field, so a deep block only shadows the
# fields it names; the rest inherit shallower blocks or the base. Without <dir>
# (or empty): plain base read.
#
# Uses an explicit has()/null check rather than `//` so an override that sets a
# field to boolean false wins over a truthy base (jq's // treats false as empty).
_agentmux_scoped_field() {
  _amux_json | jq -r --arg t "$1" --arg f "$2" --arg dir "${3:-}" --arg home "$HOME" '
    (.[$t] // {}) as $tbl
    | [ ($tbl.dirs // {}) | to_entries[]
        | (.key | gsub("^~"; $home) | rtrimstr("/")) as $pat
        | select($dir != "" and ($dir == $pat or ($dir | startswith($pat + "/"))))
        | select(.value | has($f))
        | {len: ($pat | length), val: .value[$f]}
      ] as $cands
    | ($cands | map(.len) | max) as $m
    | ($cands | map(select(.len == $m)) | first) as $hit
    | if   $hit != null   then $hit.val
      elif $tbl | has($f) then $tbl[$f]
      else empty end
  '
}

# Field value from the [frame] table, optionally directory-scoped (see
# _agentmux_scoped_field). Usage: agentmux_frame_field <field> [dir]
agentmux_frame_field() { _agentmux_scoped_field frame "$1" "${2:-}"; }

# Field value from the [amux] table, optionally directory-scoped (see
# _agentmux_scoped_field). Usage: agentmux_amux_field <field> [dir]
agentmux_amux_field() { _agentmux_scoped_field amux "$1" "${2:-}"; }

# Field value from the [notes] table, optionally directory-scoped (see
# _agentmux_scoped_field). Usage: agentmux_notes_field <field> [dir]
agentmux_notes_field() { _agentmux_scoped_field notes "$1" "${2:-}"; }

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
  AGENTMUX_CONFIG="$_selftest_dir/../config/amux.toml.example"
  # Reusable handle on the shipped example config: agents defined, no [[hosts]]
  # block — exactly the "every install predating this feature" shape.
  _selftest_example_cfg="$AGENTMUX_CONFIG"
  # Isolate the disk cache in a throwaway dir so selftest configs never touch or
  # leak into the user's real ~/.cache/agentmux, and it all disappears with one rm
  # at the end. Per-config cleanup can't reclaim these anyway: the cache key is
  # path+mtime-scoped and each selftest config is a unique mktemp path whose phash
  # never recurs, so the live find-prune (keyed on the current config's phash)
  # never matches them.
  _selftest_cache=$(mktemp -d "${TMPDIR:-/tmp}/agentmux-cache-XXXXXX") || exit 1
  export XDG_CACHE_HOME="$_selftest_cache"
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
  _assert "llm_field timeout"   "45"                                        "$(agentmux_llm_field timeout)"
  _assert "llm_field absent"    ""                                          "$(agentmux_llm_field nonexistent)"
  _assert "frame_field left"    "30"                                        "$(agentmux_frame_field left)"
  _assert "frame_field absent"  ""                                          "$(agentmux_frame_field nonexistent)"
  _assert "notes_field row"     "false"                                     "$(agentmux_notes_field row)"
  _assert "notes_field absent"  ""                                          "$(agentmux_notes_field nonexistent)"

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
  rm -f "$_tmpcfg"   # cache entries live in the throwaway $XDG_CACHE_HOME (removed at end)

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
  rm -f "$_dircfg"

  # Directory-scoped [frame] overrides. Same match rules as agentmux_agent_for_dir
  # (longest path wins, subtree match, ~ expansion), but resolved per-field: a
  # deeper block only shadows a field it actually sets, otherwise the field falls
  # back to a shallower block, then to the base [frame] value. A ~ key exercises
  # $HOME expansion; an explicit `false` override exercises the has()-not-// guard.
  _frcfg=$(mktemp /tmp/agentmux-frame-XXXXXX.toml) || exit 1
  cat > "$_frcfg" <<TOML
[frame]
left = 30
left_vertical_split = 50
focus = "agent"
default = true

[frame.dirs."/tmp/amux-frame"]
left_vertical_split = 30

[frame.dirs."/tmp/amux-frame/deep"]
focus = "terminal"
default = false

[frame.dirs."$HOME/amux-fr-home"]
left = 45
TOML
  AGENTMUX_CONFIG="$_frcfg"
  _amux_json_cache=""
  # No dir → plain base read (backward compatible).
  _assert "frame base no-dir lvs"   "50" "$(agentmux_frame_field left_vertical_split)"
  # Longest match wins for a field the deep block sets.
  _assert "frame override focus"    "terminal" "$(agentmux_frame_field focus /tmp/amux-frame/deep/x)"
  # Deep dir inherits a field the deep block doesn't set from the shallower block.
  _assert "frame cascade lvs"       "30" "$(agentmux_frame_field left_vertical_split /tmp/amux-frame/deep/x)"
  # A field no block sets falls back to base.
  _assert "frame fallback left"     "30" "$(agentmux_frame_field left /tmp/amux-frame/deep/x)"
  # Sibling subtree: deep block doesn't match, focus comes from base.
  _assert "frame sibling focus"     "agent" "$(agentmux_frame_field focus /tmp/amux-frame/other)"
  _assert "frame sibling lvs"       "30"    "$(agentmux_frame_field left_vertical_split /tmp/amux-frame/other)"
  # Unmatched dir → base values throughout.
  _assert "frame unmatched lvs"     "50" "$(agentmux_frame_field left_vertical_split /tmp/elsewhere)"
  # Explicit `false` override must win over base `true` (not be swallowed by //).
  _assert "frame override false"    "false" "$(agentmux_frame_field default /tmp/amux-frame/deep/x)"
  _assert "frame base default true" "true"  "$(agentmux_frame_field default /tmp/amux-frame)"
  # ~ key expands to $HOME and matches a subdir.
  _assert "frame tilde key"         "45" "$(agentmux_frame_field left "$HOME/amux-fr-home/proj")"
  rm -f "$_frcfg"

  # [notes] resolves through the same scoped engine as [frame]/[amux], so a
  # per-directory override works without a second mechanism.
  _ntcfg=$(mktemp "${TMPDIR:-/tmp}/amux-notes-XXXXXX.toml") || exit 1
  cat > "$_ntcfg" <<'TOML'
[[agents]]
name = "a"
cmd = "x"

[notes]
row = true

[notes.dirs."/tmp/amux-notes/off"]
row = false
TOML
  AGENTMUX_CONFIG="$_ntcfg"
  _amux_json_cache=""
  _assert "notes base row true"     "true"  "$(agentmux_notes_field row)"
  _assert "notes dir override false" "false" "$(agentmux_notes_field row /tmp/amux-notes/off/x)"
  _assert "notes unmatched dir"      "true"  "$(agentmux_notes_field row /tmp/elsewhere)"
  rm -f "$_ntcfg"

  # [amux] shares the same dir-scoped engine as [frame]. Cover a base read, a
  # per-dir override (longest match), subtree fallback to base, and an unset field.
  _amcfg=$(mktemp /tmp/agentmux-amux-XXXXXX.toml) || exit 1
  cat > "$_amcfg" <<TOML
[amux]
prefix = "C-a"

[amux.dirs."/tmp/amux-pfx"]
prefix = "C-Space"

[amux.dirs."$HOME/amux-pfx-home"]
prefix = "C-o"
TOML
  AGENTMUX_CONFIG="$_amcfg"
  _amux_json_cache=""
  _assert "amux base prefix"      "C-a"     "$(agentmux_amux_field prefix)"
  _assert "amux override prefix"  "C-Space" "$(agentmux_amux_field prefix /tmp/amux-pfx/deep)"
  _assert "amux fallback prefix"  "C-a"     "$(agentmux_amux_field prefix /tmp/elsewhere)"
  _assert "amux tilde prefix"     "C-o"     "$(agentmux_amux_field prefix "$HOME/amux-pfx-home/x")"
  _assert "amux absent field"     ""        "$(agentmux_amux_field nonexistent)"
  rm -f "$_amcfg"

  # ---- [[hosts]] accessors ----
  _hostscfg=$(mktemp "${TMPDIR:-/tmp}/agentmux-hosts-XXXXXX.toml") || exit 1
  cat > "$_hostscfg" <<'TOML'
[[hosts]]
name  = "buildbox"
ssh   = "root@buildbox"
roots = ["~/Developer/work", "~/src"]

[[hosts]]
name      = "bench"
ssh       = "bench"
roots     = ["~/code"]
transport = "et"
TOML
  AGENTMUX_CONFIG="$_hostscfg" _amux_json_cache="" _assert "host count" "2" \
    "$(AGENTMUX_CONFIG="$_hostscfg" _amux_json_cache="" agentmux_host_count)"
  _assert "host field ssh" "root@buildbox" \
    "$(AGENTMUX_CONFIG="$_hostscfg" _amux_json_cache="" agentmux_host_field 0 ssh)"
  _assert "host field transport absent is empty" "" \
    "$(AGENTMUX_CONFIG="$_hostscfg" _amux_json_cache="" agentmux_host_field 0 transport)"
  _assert "host field transport present" "et" \
    "$(AGENTMUX_CONFIG="$_hostscfg" _amux_json_cache="" agentmux_host_field 1 transport)"
  _assert "find host by name" "1" \
    "$(AGENTMUX_CONFIG="$_hostscfg" _amux_json_cache="" agentmux_find_host_by_name bench)"
  _assert "find host by name missing" "-1" \
    "$(AGENTMUX_CONFIG="$_hostscfg" _amux_json_cache="" agentmux_find_host_by_name nope)"
  # shellcheck disable=SC2088 # intentional: agentmux_host_roots must NOT expand ~
  _assert "host roots" "~/Developer/work ~/src" \
    "$(AGENTMUX_CONFIG="$_hostscfg" _amux_json_cache="" agentmux_host_roots 0 | tr '\n' ' ' | sed 's/ $//')"
  _assert "host names" "buildbox bench" \
    "$(AGENTMUX_CONFIG="$_hostscfg" _amux_json_cache="" agentmux_host_names | tr '\n' ' ' | sed 's/ $//')"
  # A config with NO [[hosts]] block must return 0/-1/empty, never a jq null error —
  # every existing user's config is exactly this shape.
  _assert "no hosts block counts 0" "0" \
    "$(AGENTMUX_CONFIG="$_selftest_example_cfg" _amux_json_cache="" agentmux_host_count)"
  _assert "no hosts block finds -1" "-1" \
    "$(AGENTMUX_CONFIG="$_selftest_example_cfg" _amux_json_cache="" agentmux_find_host_by_name buildbox)"
  rm -f "$_hostscfg"

  # A config with NO [[agents]] block (hosts-only) must return empty/0, never a jq null error —
  # this is now a valid and discoverable config shape (remote-only hosts, no local agents).
  _hostsonlycfg=$(mktemp "${TMPDIR:-/tmp}/agentmux-hostsonly-XXXXXX.toml") || exit 1
  cat > "$_hostsonlycfg" <<'TOML'
[[hosts]]
name  = "buildbox"
ssh   = "root@buildbox"
roots = ["~/Developer/work"]
TOML
  _assert "no agents block agent_for_dir" "" \
    "$(AGENTMUX_CONFIG="$_hostsonlycfg" _amux_json_cache="" agentmux_agent_for_dir /tmp/anywhere)"
  completions=$(AGENTMUX_CONFIG="$_hostsonlycfg" _amux_json_cache="" agentmux_list_agent_completions)
  _assert "no agents block completions empty" "" "$completions"
  rm -f "$_hostsonlycfg"

  rm -rf "$_selftest_cache"
  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]
fi
