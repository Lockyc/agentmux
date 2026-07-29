#!/usr/bin/env bash
#
# Aggregate test runner for agentmux — the "run everything" entry point.
#
# Runs, in order:
#   1. shellcheck --severity=warning over the tracked shell scripts
#      (the documented-benign SC2154 for _llm_url/_llm_model/_llm_timeout is
#      filtered out; any other finding fails).
#   2. fish -n syntax check of the fish integration (skipped-with-note if no fish).
#   3. Every built-in selftest (see CLAUDE.md "Selftests"). Several need a real
#      tmux and self-skip if absent — install tmux to make them actually run.
#   4. tests/mouse/run.sh — the status-bar click suite. Needs `expect` + tmux and
#      takes ~1 minute (it drives real pty clients with settle delays), so it is
#      the last check. Skipped-with-note when a dependency is missing, EXCEPT
#      under AGENTMUX_REQUIRE_MOUSE_TESTS=1, where a missing dependency FAILS.
#
# Prints a per-check pass/fail line plus a final summary. Exits non-zero if any
# check fails. Runnable from any cwd (resolves its own directory).
#
# For a targeted run, invoke an individual selftest directly with its VAR=1
# form as documented in CLAUDE.md; this script is the aggregate.

set -u

# Resolve the repo root (this script's own dir) so we run from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit 2

pass=0
fail=0
skip=0
declare -a results=()

pass() { results+=("PASS  $1"); pass=$((pass + 1)); printf 'PASS  %s\n' "$1"; }
failed() { results+=("FAIL  $1"); fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"; }
skipped() { results+=("SKIP  $1"); skip=$((skip + 1)); printf 'SKIP  %s\n' "$1"; }

# --- 1. shellcheck ---------------------------------------------------------
# Files matching the Linting section of CLAUDE.md.
SHELLCHECK_TARGETS=(scripts/*.sh scripts/claude/*.sh shell/agentmux.sh bin/amux install.sh
                    tests/mouse/run.sh)

if command -v shellcheck >/dev/null 2>&1; then
  # gcc format = one finding per line (file:line:col: sev: msg [SCxxxx]), so we
  # can filter cleanly. The three documented-benign SC2154 globals
  # (_llm_url/_llm_model/_llm_timeout) are set by _amux_load_llm inside
  # llm-config.sh — shellcheck can't trace function-set globals across a sourced
  # file. Filter those out; ANY other finding (any remaining [SCxxxx]) fails.
  sc_out="$(shellcheck --severity=warning -f gcc "${SHELLCHECK_TARGETS[@]}" 2>&1)"
  sc_rc=$?
  sc_filtered="$(printf '%s\n' "$sc_out" \
    | grep -vE '(_llm_url|_llm_model|_llm_timeout) is referenced but not assigned.*\[SC2154\]')"
  if printf '%s\n' "$sc_filtered" | grep -q -E '\[SC[0-9]{4}\]'; then
    failed "shellcheck (real findings remain)"
    printf '%s\n' "$sc_filtered" | grep -E '\[SC[0-9]{4}\]'
  elif [ "$sc_rc" -gt 1 ]; then
    # non-finding error (exit > 1), e.g. a missing target file.
    failed "shellcheck (exited $sc_rc)"
    printf '%s\n' "$sc_out"
  else
    pass "shellcheck --severity=warning"
  fi
else
  skipped "shellcheck (not installed)"
fi

# --- 2. fish syntax check --------------------------------------------------
if command -v fish >/dev/null 2>&1; then
  if fish -n shell/agentmux.fish; then
    pass "fish -n shell/agentmux.fish"
  else
    failed "fish -n shell/agentmux.fish"
  fi
else
  skipped "fish -n shell/agentmux.fish (fish not installed)"
fi

# --- 3. built-in selftests -------------------------------------------------
# run_selftest <label> <cmd...>. The command carries its own SELFTEST env var
# via `env VAR=1 …` so it is exported to the (external) script process — a bare
# `VAR=1 run_selftest …` prefix would set the var only in this shell, not in the
# child. Runner + env mirror the invocation forms in CLAUDE.md's Selftests list.
run_selftest() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass "selftest: $label"
  else
    failed "selftest: $label"
    printf '  --- output of failing selftest %s ---\n' "$label"
    "$@" 2>&1 | sed 's/^/  /'
    printf '  --- end ---\n'
  fi
}

run_selftest llm-config          env LLM_CONFIG_SELFTEST=1          sh scripts/llm-config.sh
run_selftest summarise           env SUMMARISE_SELFTEST=1            scripts/summarise.sh
run_selftest strip_unbacked_done env STRIP_UNBACKED_DONE_SELFTEST=1 scripts/strip_unbacked_done.sh
run_selftest summary_rows        env SUMMARY_ROWS_SELFTEST=1        scripts/summary_rows.sh
run_selftest claude/ctx          env CLAUDE_CTX_SELFTEST=1          scripts/claude/ctx.sh
run_selftest claude/goal         env CLAUDE_GOAL_SELFTEST=1         scripts/claude/goal.sh
run_selftest claude/digest       env CLAUDE_DIGEST_SELFTEST=1       scripts/claude/digest.sh
run_selftest agentmux-config     env AGENTMUX_CONFIG_SELFTEST=1     bash scripts/agentmux-config.sh
run_selftest agent_window_style  env AGENTMUX_STYLE_SELFTEST=1      bash scripts/agent_window_style.sh
run_selftest session_log         env SESSION_LOG_SELFTEST=1         sh scripts/session_log.sh
run_selftest amux                env AMUX_SELFTEST=1                bash bin/amux
run_selftest clear_icon          env CLEAR_ICON_SELFTEST=1          sh scripts/clear_icon.sh
run_selftest version_check       env VERSION_CHECK_SELFTEST=1       sh scripts/version_check.sh
run_selftest colours             env COLOURS_SELFTEST=1             sh scripts/colours.sh
run_selftest update_colors       env UPDATE_COLORS_SELFTEST=1       sh scripts/update_colors.sh
run_selftest frame_reattach      env FRAME_REATTACH_SELFTEST=1      sh scripts/frame_reattach.sh
run_selftest fork_session        env FORK_SESSION_SELFTEST=1        bash scripts/fork_session.sh
run_selftest relaunch            env RELAUNCH_SELFTEST=1            bash scripts/relaunch.sh
run_selftest notes               env NOTES_SELFTEST=1               sh scripts/notes.sh

# --- 4. mouse-click suite (tests/mouse) ------------------------------------
# NOTES_SELFTEST covers scripts/notes.sh except the click itself (it invokes
# `click` with a /dev/null client tty so command-prompt fails fast instead of
# hanging a headless run), so this suite is the only thing exercising the path a
# real click takes. Slow by nature — ~1 minute, driving real pty clients with
# settle delays — hence last.
#
# A self-skipping REGRESSION test stops protecting you wherever it skips, unlike
# an advisory linter, so AGENTMUX_REQUIRE_MOUSE_TESTS=1 (set in CI) turns a
# missing dependency into a failure rather than a skip.
mouse_missing=""
command -v expect >/dev/null 2>&1 || mouse_missing="expect"
command -v tmux   >/dev/null 2>&1 || mouse_missing="${mouse_missing:+$mouse_missing, }tmux"

if [ -n "$mouse_missing" ]; then
  if [ "${AGENTMUX_REQUIRE_MOUSE_TESTS:-}" = 1 ]; then
    failed "tests/mouse (required by AGENTMUX_REQUIRE_MOUSE_TESTS=1, but missing: $mouse_missing)"
  else
    skipped "tests/mouse (not installed: $mouse_missing)"
  fi
else
  # Captured, not re-run on failure: one run costs ~1 minute.
  if mouse_out="$(bash tests/mouse/run.sh 2>&1)"; then
    pass "tests/mouse (status-bar click suite)"
  else
    failed "tests/mouse (status-bar click suite)"
    printf '  --- output of failing tests/mouse/run.sh ---\n'
    printf '%s\n' "$mouse_out" | sed 's/^/  /'
    printf '  --- end ---\n'
  fi
fi

# --- summary ---------------------------------------------------------------
echo
echo "==================== summary ===================="
printf '%s\n' "${results[@]}"
echo "-------------------------------------------------"
printf 'pass=%d  fail=%d  skip=%d\n' "$pass" "$fail" "$skip"

[ "$fail" -eq 0 ]
