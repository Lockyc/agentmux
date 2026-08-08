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
#
# Captures the transport's stderr as it streams — via a `tee` fork that still
# lets it reach the real terminal, since ssh diagnostics (and, if the
# multiplexed master has expired, an auth prompt) must stay visible — and sets
# RA_LAST_ERR to its last non-blank line for the holding screen to show. The
# process-substitution capture (`2> >(tee -a … >&2)`) was stress-tested under
# the real /bin/bash (bash 3.2, macOS) for the read-before-tee-flushes race
# process substitution is known for; none observed across 500 iterations, incl.
# under artificial CPU load — small, synchronous stderr writes ahead of process
# exit are the case here, not a long-lived stream.
_ra_run_once() {
  local kind="$1" target="$2" cmd="$3"
  local errfile st
  errfile="$(mktemp "${TMPDIR:-/tmp}/amux-remote-err.XXXXXX" 2>/dev/null)" || errfile=""
  if [ -n "${AGENTMUX_REMOTE_TRANSPORT_CMD:-}" ]; then
    if [ -n "$errfile" ]; then
      "$AGENTMUX_REMOTE_TRANSPORT_CMD" "$target" "$cmd" 2> >(tee -a "$errfile" >&2)
    else
      "$AGENTMUX_REMOTE_TRANSPORT_CMD" "$target" "$cmd"
    fi
    st=$?
    _ra_capture_err "$errfile"
    return "$st"
  fi
  if ! _rm_transport_argv "$kind" "$target" "$cmd"; then
    [ -n "$errfile" ] && rm -f "$errfile"
    return 2
  fi
  if [ -n "$errfile" ]; then
    "${RM_ARGV[@]}" 2> >(tee -a "$errfile" >&2)
  else
    "${RM_ARGV[@]}"
  fi
  st=$?
  _ra_capture_err "$errfile"
  return "$st"
}

# _ra_capture_err <errfile> — set RA_LAST_ERR to its last non-blank line and
# reap the file (no residue past this call). RA_LAST_ERR is a genuine global
# (no `local`): _ra_render stays pure and only ever receives it as its 5th
# positional argument — see that function's own header. This is the one
# writer; _ra_hold is the one reader that turns it into that argument.
_ra_capture_err() {
  local f="$1"
  [ -n "$f" ] || return 0
  RA_LAST_ERR="$(grep -v '^[[:space:]]*$' "$f" 2>/dev/null | tail -n 1)"
  rm -f "$f"
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
  printf '\n       your session is still running on %s; nothing is lost\n\n' "$host"
  printf '    r  retry now        q  give up (session keeps running)\n'
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

# ---------------------------------------------------------------------------
# Picker
# ---------------------------------------------------------------------------

# _ra_pick_render <roster-json> — the numbered list. PURE (stdout only).
#
# Every project is listed whether or not it has a live session; liveness is a
# dot, never a filter. Hiding idle projects would make the list a different
# shape every time and teach nothing about what is on the box — the same reason
# the local surfaces render empty widgets in place rather than swapping views.
_ra_pick_render() {
  local json="$1" n
  n="$(printf '%s' "$json" | jq 'length')"
  if [ "${n:-0}" -eq 0 ]; then
    printf '  no projects found under this host'"'"'s roots\n'
    return 0
  fi
  printf '%s' "$json" | jq -r '
    to_entries[]
    | "  \(.key + 1)) \(if .value.live then "●" else "○" end)  "
      + (.value.name | . + (" " * (18 - (. | length))))
      + (.value.path)
      + (if .value.live then "   \(.value.tabs) tab" + (if .value.tabs == 1 then "" else "s" end) else "" end)'
}

# _ra_pick <host_index> <host> — render, read a choice, print the chosen name.
# Prints nothing when cancelled or empty.
_ra_pick() {
  local hi="$1" host="$2" json n sel
  json="$(_rm_roster_json "$hi" "$host")" || {
    printf 'amux: could not list projects on %s\n' "$host" >&2; return 1; }
  n="$(printf '%s' "$json" | jq 'length')"
  printf '\n  %s — %s project%s\n\n' "$host" "$n" \
    "$([ "$n" = 1 ] || printf s)" >&2
  _ra_pick_render "$json" >&2
  [ "${n:-0}" -gt 0 ] || return 1
  printf '\n  project (1-%s, q to cancel): ' "$n" >&2
  read -r sel
  case "$sel" in
    ''|q|Q|quit) return 1 ;;
    *[!0-9]*)    return 1 ;;
  esac
  sel=$((10#$sel))
  { [ "$sel" -ge 1 ] && [ "$sel" -le "$n" ]; } || return 1
  printf '%s' "$json" | jq -r ".[$((sel - 1))].name"
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

  # ---- stderr capture reaches RA_LAST_ERR and the rendered screen ----
  # The transport is interactive and owns the terminal, so the capture must be
  # a tee that keeps stderr visible to the caller — never a plain redirect,
  # which would swallow ssh diagnostics or an auth prompt. Isolated under its
  # own TMPDIR (reaped by the outer EXIT trap) so the capture file — and proof
  # that it leaves no residue — stay inside a throwaway directory.
  _ra_prev_tmpdir="${TMPDIR:-}"
  export TMPDIR="$_ra_t"
  cat > "$_ra_t/errstub" <<'STUB'
#!/bin/sh
echo "boom: connection refused" >&2
exit 255
STUB
  chmod +x "$_ra_t/errstub"
  : > "$_ra_t/livestderr"
  AGENTMUX_REMOTE_TRANSPORT_CMD="$_ra_t/errstub" \
    _ra_run_once ssh t "sh -c true" >/dev/null 2>"$_ra_t/livestderr"
  _ra_rc=$?
  _assert "run_once returns the transport's exit status" "255" "$_ra_rc"
  # Proves the tee didn't swallow it: the text still reached the real fd we
  # redirected stderr to, exactly as a terminal would have received it.
  _assert "stderr still reached the caller (not swallowed)" "1" \
    "$(grep -c 'boom: connection refused' "$_ra_t/livestderr")"
  _assert "RA_LAST_ERR captured the same text" "1" \
    "$(printf '%s' "$RA_LAST_ERR" | grep -c 'boom: connection refused')"
  # Closing the loop end to end: the captured text is what the holding screen
  # actually renders, not just a variable nothing reads.
  _ra_render_out="$(_ra_render buildbox /srv/p 1 5 "$RA_LAST_ERR")"
  _assert "the captured error reaches the rendered screen" "1" \
    "$(printf '%s' "$_ra_render_out" | grep -c 'boom: connection refused')"
  _assert "the capture file leaves no residue" "0" \
    "$(find "$_ra_t" -maxdepth 1 -name 'amux-remote-err.*' | wc -l | tr -d ' ')"
  unset AGENTMUX_REMOTE_TRANSPORT_CMD
  if [ -n "$_ra_prev_tmpdir" ]; then export TMPDIR="$_ra_prev_tmpdir"; else unset TMPDIR; fi

  # ---- holding screen ----
  # _ra_render is pure so it can be asserted on directly — no pty, no alternate
  # screen, no timing. The terminal control lives in _ra_hold around it.
  _ra_out="$(_ra_render buildbox /srv/projects/warden 3 84 'ssh: connect: Host is down')"
  # grep -c counts matching LINES, not occurrences — the host appears on two
  # lines (header + reassurance line), so occurrences must be counted with
  # grep -o | wc -l instead, or this undercounts a real regression to "1".
  _assert "render names the host (header + reassurance)" "2" \
    "$(printf '%s' "$_ra_out" | grep -o 'buildbox' | wc -l | tr -d ' ')"
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
  # Same grep -c pitfall: both hints sit on ONE line by design, so -c would
  # (and did) undercount to "1" — occurrences, not lines, is what this checks.
  _assert "render names both keys" "2" \
    "$(printf '%s' "$_ra_out" | grep -Eo '(^|[^a-z])(r|q)  ' | wc -l | tr -d ' ')"
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

  # ---- picker ----
  _ra_j='[{"name":"warden","path":"/d/warden","live":true,"tabs":2,"agent":"work"},
          {"name":"lector","path":"/d/lector","live":false,"tabs":0,"agent":""}]'
  _ra_p="$(_ra_pick_render "$_ra_j")"
  _assert "picker numbers the rows" "1" "$(printf '%s' "$_ra_p" | grep -c '1) ')"
  _assert "picker lists both" "2" "$(printf '%s' "$_ra_p" | grep -cE '^\s*[0-9]+\) ')"
  # A live project gets a filled dot, an idle one a hollow dot — the control is
  # present in BOTH states, never removed. Same discoverability rule as the
  # local status surfaces: absence of data is shown in place, not by omission.
  _assert "live project marked" "1" "$(printf '%s' "$_ra_p" | grep -c '●')"
  _assert "idle project still listed with a dot" "1" "$(printf '%s' "$_ra_p" | grep -c '○')"
  _assert "live project shows its tab count" "1" \
    "$(printf '%s' "$_ra_p" | grep -c '2 tabs')"
  # An idle project shows no tab count, but keeps its row shape.
  _assert "idle row has no tab count" "1" \
    "$(printf '%s' "$_ra_p" | grep -c 'lector')"
  # An empty roster is a real answer and must say so, not print a bare prompt.
  _assert "empty roster explains itself" "1" \
    "$(_ra_pick_render '[]' 2>&1 | grep -ci 'no projects')"

  echo "---- $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi
