#!/usr/bin/env bash
# remote_attach.sh — source this; do not execute directly (except for its selftest).
#
# The tty-owning half of `amux @host`: the supervise loop, the holding screen,
# and the project picker. Everything that computes lives in remote.sh — that
# split is what keeps this file's siblings testable offline, and keeps this file
# small enough to reason about.
#
# bash 3.2-clean: no `local -A` / `declare -A`.

RA_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/remote.sh
source "$RA_SCRIPT_DIR/remote.sh"

# ---------------------------------------------------------------------------
# Supervise loop
# ---------------------------------------------------------------------------

# _ra_backoff <attempt> — seconds to wait before attempt N. 1,2,4,8,15,15,…
_ra_backoff() {
  local n="$1" s=1
  while [ "$n" -gt 1 ] && [ "$s" -lt 15 ]; do s=$((s * 2)); n=$((n - 1)); done
  [ "$s" -gt 15 ] && s=15
  printf '%s' "$s"
}

# _ra_sleep <seconds> — sleep, unless a test has disabled waiting.
_ra_sleep() {
  [ "${AGENTMUX_REMOTE_BACKOFF:-1}" = "0" ] && return 0
  sleep "$1"
}

# _ra_run_once <kind> <target> <cmd> — one interactive transport attempt.
# Returns the transport's exit status.
_ra_run_once() {
  local kind="$1" target="$2" cmd="$3"
  if [ -n "${AGENTMUX_REMOTE_TRANSPORT_CMD:-}" ]; then
    "$AGENTMUX_REMOTE_TRANSPORT_CMD" "$target" "$cmd"
    return $?
  fi
  _rm_transport_argv "$kind" "$target" "$cmd" || return 2
  "${RM_ARGV[@]}"
  return $?
}

# _ra_supervise <kind> <target> <cmd> <host> <dir>
# Runs the transport, re-attaching through the holding screen when the link
# drops. Returns 0 on a clean exit, the transport's status on a remote failure,
# 1 if the user gave up or the attempt bound was reached.
#
# The loop is entered ONLY after preflight succeeded, so an unreachable host, a
# refused key or a missing project can never land here — they fail earlier,
# where nothing retries. What reaches this loop is a link that was up and went
# away, which is the one thing worth waiting for.
_ra_supervise() {
  local kind="$1" target="$2" cmd="$3" host="$4" dir="$5"
  local attempt=0 st verdict wait started
  local maxa="${AGENTMUX_REMOTE_MAX_ATTEMPTS:-0}"
  started=$(date +%s)
  while : ; do
    attempt=$((attempt + 1))
    _ra_run_once "$kind" "$target" "$cmd"
    st=$?
    verdict="$(_rm_classify_exit "$kind" "$st")"
    case "$verdict" in
      clean) return 0 ;;
      fail)  return "$st" ;;
    esac
    if [ "$maxa" -gt 0 ] && [ "$attempt" -ge "$maxa" ]; then
      _ra_give_up "$host" "$dir"
      return 1
    fi
    wait="$(_ra_backoff "$attempt")"
    _ra_hold "$host" "$dir" "$attempt" "$started" "$wait" || { _ra_give_up "$host" "$dir"; return 1; }
  done
}

# ---------------------------------------------------------------------------
# Holding screen
# ---------------------------------------------------------------------------

# _ra_elide <string> <max> — shorten from the MIDDLE, keeping the tail.
# A project path's identifying part is its end, so truncating the front would
# leave every long path looking the same.
_ra_elide() {
  local s="$1" max="$2" keep
  [ "${#s}" -le "$max" ] && { printf '%s' "$s"; return 0; }
  keep=$(( (max - 1) / 2 ))
  printf '%s…%s' "${s:0:keep}" "${s: -keep}"
}

# _ra_render <host> <dir> <attempt> <elapsed> <error> — the screen body.
# PURE: writes to stdout, reads no globals, touches no terminal state. That is
# what makes the screen assertable without a pty; _ra_hold wraps it with the
# alternate-screen and key handling.
_ra_render() {
  local host="$1" dir="$2" attempt="$3" elapsed="$4" err="$5"
  local mm ss
  mm=$(printf '%02d' $(( elapsed / 60 )))
  ss=$(printf '%02d' $(( elapsed % 60 )))
  printf '\n  agentmux · remote\n\n'
  printf '    %-20s %s\n\n' "$host" "$(_ra_elide "$dir" 48)"
  printf '    ⟳  reconnecting — attempt %s, %s:%s elapsed\n' "$attempt" "$mm" "$ss"
  [ -n "$err" ] && printf '       %s\n' "$(_ra_elide "$err" 66)"
  printf '\n       your session is still running there; nothing is lost\n\n'
  printf '    r  retry now\n'
  printf '    q  give up (session keeps running)\n'
}

# _ra_hold <host> <dir> <attempt> <started-epoch> <wait-seconds>
# Shows the screen for <wait> seconds. Returns 0 to keep retrying, 1 if quit.
#
# Never touches the remote: there is nothing to clean up, because remote tmux
# going on without us is precisely the correct behaviour.
_ra_hold() {
  local host="$1" dir="$2" attempt="$3" started="$4" wait="$5"
  local key left now elapsed
  if [ "${AGENTMUX_REMOTE_BACKOFF:-1}" = "0" ] || [ ! -t 0 ] || [ ! -t 1 ]; then
    return 0
  fi
  tput smcup 2>/dev/null
  left="$wait"
  while [ "$left" -gt 0 ]; do
    now=$(date +%s); elapsed=$(( now - started ))
    tput clear 2>/dev/null
    _ra_render "$host" "$dir" "$attempt" "$elapsed" "${RA_LAST_ERR:-}"
    if read -r -n 1 -t 1 key 2>/dev/null; then
      case "$key" in
        q|Q) tput rmcup 2>/dev/null; return 1 ;;
        r|R) break ;;
      esac
    fi
    left=$(( left - 1 ))
  done
  tput rmcup 2>/dev/null
  return 0
}

# _ra_give_up <host> <dir> — the parting message.
# Names the exact command to get back in, so returning is a paste rather than a
# thing to reconstruct.
_ra_give_up() {
  local host="$1" dir="$2" proj
  proj="$(basename "$dir")"
  printf '\namux: gave up reconnecting to %s.\n' "$host" >&2
  printf '      Your session is still running there — nothing was lost.\n' >&2
  printf '      Get back in with:  amux @%s %s\n\n' "$host" "$proj" >&2
}

# ============================ selftest ============================
# REMOTE_ATTACH_SELFTEST=1 bash scripts/remote_attach.sh
if [ "${REMOTE_ATTACH_SELFTEST:-}" = "1" ]; then
  unset REMOTE_ATTACH_SELFTEST
  pass=0; fail=0
  _assert() { if [ "$3" = "$2" ]; then pass=$((pass+1)); echo "PASS: $1"
              else fail=$((fail+1)); echo "FAIL: $1 — expected '$2' got '$3'"; fi; }

  _ra_t="$(mktemp -d)"
  trap 'rm -rf "$_ra_t"' EXIT
  export AGENTMUX_REMOTE_BACKOFF=0        # no real sleeping in tests
  export AGENTMUX_REMOTE_MAX_ATTEMPTS=5   # bound the loop

  # A stub that fails N times then succeeds, counting its own invocations.
  cat > "$_ra_t/flaky" <<'STUB'
#!/bin/sh
n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" > "$STUB_COUNT"
[ "$n" -le "$STUB_FAILS" ] && exit "$STUB_CODE"
exit 0
STUB
  chmod +x "$_ra_t/flaky"
  export AGENTMUX_REMOTE_TRANSPORT_CMD="$_ra_t/flaky"
  export STUB_COUNT="$_ra_t/count"

  # ssh 255 twice then success → three invocations, clean return.
  : > "$STUB_COUNT"; STUB_FAILS=2 STUB_CODE=255 \
    _ra_supervise ssh t "sh -c true" buildbox /srv/p >/dev/null 2>&1
  _assert "retries a dropped link then succeeds" "0" "$?"
  _assert "retried exactly twice" "3" "$(cat "$STUB_COUNT")"

  # A REMOTE failure (ssh exit 1) must not retry — retrying reproduces it forever.
  : > "$STUB_COUNT"; STUB_FAILS=9 STUB_CODE=1 \
    _ra_supervise ssh t "sh -c true" buildbox /srv/p >/dev/null 2>&1
  _assert "remote failure returns its status" "1" "$?"
  _assert "remote failure did not retry" "1" "$(cat "$STUB_COUNT")"

  # A clean exit (detach) must not retry.
  : > "$STUB_COUNT"; STUB_FAILS=0 STUB_CODE=0 \
    _ra_supervise ssh t "sh -c true" buildbox /srv/p >/dev/null 2>&1
  _assert "clean exit returns 0" "0" "$?"
  _assert "clean exit ran once" "1" "$(cat "$STUB_COUNT")"

  # Exhausting the attempt bound gives up rather than looping forever.
  : > "$STUB_COUNT"; STUB_FAILS=99 STUB_CODE=255 \
    _ra_supervise ssh t "sh -c true" buildbox /srv/p >/dev/null 2>&1
  _assert "gives up at the attempt bound" "1" "$?"
  _assert "attempted exactly the bound" "5" "$(cat "$STUB_COUNT")"

  # Backoff is bounded and monotonic up to the cap.
  _assert "backoff 1" "1"  "$(_ra_backoff 1)"
  _assert "backoff 2" "2"  "$(_ra_backoff 2)"
  _assert "backoff 3" "4"  "$(_ra_backoff 3)"
  _assert "backoff 4" "8"  "$(_ra_backoff 4)"
  _assert "backoff caps at 15" "15" "$(_ra_backoff 9)"

  # ---- holding screen ----
  # _ra_render is pure so it can be asserted on directly — no pty, no alternate
  # screen, no timing. The terminal control lives in _ra_hold around it.
  _ra_out="$(_ra_render buildbox /srv/projects/warden 3 84 'ssh: connect: Host is down')"
  _assert "render names the host" "1" "$(printf '%s' "$_ra_out" | grep -c 'buildbox')"
  _assert "render names the project dir" "1" \
    "$(printf '%s' "$_ra_out" | grep -c 'warden')"
  _assert "render shows the attempt" "1" "$(printf '%s' "$_ra_out" | grep -c 'attempt 3')"
  _assert "render shows elapsed mm:ss" "1" "$(printf '%s' "$_ra_out" | grep -c '01:24')"
  _assert "render shows the last error" "1" \
    "$(printf '%s' "$_ra_out" | grep -c 'Host is down')"
  # The reassurance line is the point of the screen: the question a dropped
  # remote session actually raises is "did I lose that", and it is answered in
  # place rather than left to be inferred.
  _assert "render reassures about the session" "1" \
    "$(printf '%s' "$_ra_out" | grep -ci 'still running')"
  _assert "render names both keys" "2" \
    "$(printf '%s' "$_ra_out" | grep -Eco '(^|[^a-z])(r|q)  ')"
  # Long dirs must not wrap the layout — the middle is elided, never truncated
  # at the front, because the tail is the identifying part.
  _ra_long="$(_ra_render h /a/very/long/path/that/keeps/going/and/going/and/going/warden 1 5 x)"
  _assert "long dir keeps its tail" "1" "$(printf '%s' "$_ra_long" | grep -c 'warden')"
  _assert "long dir is elided" "1" "$(printf '%s' "$_ra_long" | grep -c '…')"

  # Giving up must name the exact command to get back in — an instruction the
  # user can paste, not a description of one.
  _ra_bye="$(_ra_give_up buildbox /srv/projects/warden 2>&1)"
  _assert "give up names the re-entry command" "1" \
    "$(printf '%s' "$_ra_bye" | grep -c 'amux @buildbox warden')"
  _assert "give up says the session survives" "1" \
    "$(printf '%s' "$_ra_bye" | grep -ci 'still running')"

  unset AGENTMUX_REMOTE_TRANSPORT_CMD STUB_COUNT
  echo "---- $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi
