#!/usr/bin/env bash
# remote.sh — source this; do not execute directly (except for its selftest).
#
# The non-tty half of `amux @host`: host config, target parsing, transport argv,
# preflight, roster, and exit classification. Everything here computes; nothing
# here owns the terminal. The terminal half lives in remote_attach.sh — that
# split is what lets every function below be tested offline, with no ssh, no
# network and no remote box.
#
# bash 3.2-clean (macOS /bin/bash): no `local -A` / `declare -A`. bin/amux
# sources this at launch and carries a selftest guard for it.

RM_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/agentmux-config.sh
source "$RM_SCRIPT_DIR/agentmux-config.sh"

# ---------------------------------------------------------------------------
# Target parsing
# ---------------------------------------------------------------------------

# _rm_parse_target <arg>...
# Parses a leading `@…` target and the args that follow it.
# Sets: RM_HOST, RM_PROJECT, RM_PATH (strings) and RM_REST (array).
# Returns 2 if arg 1 is not a well-formed @target.
#
# RM_REST is an ARRAY, not a string: it is forwarded verbatim to the remote
# amux, and a remote path or session name containing a space must arrive as one
# argument. Joining and re-splitting would corrupt exactly the case the explicit
# `@host:<path>` escape hatch exists for.
_rm_parse_target() {
  RM_HOST=""; RM_PROJECT=""; RM_PATH=""; RM_REST=()
  local first="${1:-}"
  case "$first" in
    @?*) : ;;
    *)   return 2 ;;
  esac
  shift
  first="${first#@}"
  case "$first" in
    :*)  return 2 ;;             # "@:x" — no host
    *:*) RM_HOST="${first%%:*}"; RM_PATH="${first#*:}" ;;
    *)   RM_HOST="$first" ;;
  esac
  [ -n "$RM_HOST" ] || return 2

  # A bare word right after the target is the PROJECT — unless an explicit path
  # already named the directory, in which case there is nothing left for it to
  # select and it forwards instead.
  if [ $# -gt 0 ] && [ -z "$RM_PATH" ]; then
    case "$1" in
      -*) : ;;
      *)  RM_PROJECT="$1"; shift ;;
    esac
  fi
  RM_REST=("$@")
  return 0
}

# ============================ selftest ============================
# REMOTE_SELFTEST=1 bash scripts/remote.sh
if [ "${REMOTE_SELFTEST:-}" = "1" ]; then
  unset REMOTE_SELFTEST
  pass=0; fail=0
  _assert() { if [ "$3" = "$2" ]; then pass=$((pass+1)); echo "PASS: $1"
              else fail=$((fail+1)); echo "FAIL: $1 — expected '$2' got '$3'"; fi; }

  # ---- target parsing ----
  _rm_parse_target "@buildbox"
  _assert "bare host" "buildbox||" "$RM_HOST|$RM_PROJECT|$RM_PATH"
  _assert "bare host no rest" "0" "${#RM_REST[@]}"

  _rm_parse_target "@buildbox" "warden"
  _assert "host + project" "buildbox|warden|" "$RM_HOST|$RM_PROJECT|$RM_PATH"
  _assert "host + project no rest" "0" "${#RM_REST[@]}"

  _rm_parse_target "@buildbox:~/tmp/x"
  _assert "host + path" "buildbox||~/tmp/x" "$RM_HOST|$RM_PROJECT|$RM_PATH"

  _rm_parse_target "@buildbox" "--kill"
  _assert "host + flag" "buildbox||" "$RM_HOST|$RM_PROJECT|$RM_PATH"
  _assert "host + flag rest" "--kill" "${RM_REST[*]}"

  _rm_parse_target "@buildbox" "warden" "--kill"
  _assert "host + project + flag" "buildbox|warden|" "$RM_HOST|$RM_PROJECT|$RM_PATH"
  _assert "host + project + flag rest" "--kill" "${RM_REST[*]}"

  # An explicit path already answers "which dir", so a following bare word is
  # NOT a project — it forwards, where remote amux reads it as a session name.
  _rm_parse_target "@buildbox:~/x" "warden"
  _assert "path wins over project" "buildbox||~/x" "$RM_HOST|$RM_PROJECT|$RM_PATH"
  _assert "path then bare word forwards" "warden" "${RM_REST[*]}"

  # Paths with spaces survive as ONE element (the whole reason RM_REST is an
  # array and not a string).
  _rm_parse_target "@buildbox:~/my docs" "--probe"
  # shellcheck disable=SC2088
  _assert "path with space" "~/my docs" "$RM_PATH"

  _rm_parse_target "@" ; _assert "bare @ rejected" "2" "$?"
  _rm_parse_target "buildbox" ; _assert "no sigil rejected" "2" "$?"
  _rm_parse_target "@:x" ; _assert "empty host rejected" "2" "$?"

  echo "---- $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi
