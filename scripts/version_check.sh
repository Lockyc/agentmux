#!/bin/sh
# version_check.sh — opt-in, once-daily check for a newer agentmux on GitHub.
# Standalone (invoked, not sourced). Pure POSIX sh.
#
# When enabled (see _vc_enabled):
#   - Notice (instant): compare cached latest version to local VERSION; if the
#     remote is newer, print a one-line notice to stderr.
#   - Refresh (background, <=1x/day): if the cache is stale (>24h), fork a
#     detached curl of the raw VERSION from GitHub and update the cache.
# Never blocks: the notice is a file read; the network refresh is backgrounded.
#
# Enable:  [update] check = true in amux.toml, or AGENTMUX_VERSION_CHECK=1.
# Disable: AGENTMUX_VERSION_CHECK=0 (overrides config).

VC_RAW_URL="https://raw.githubusercontent.com/lockyc/agentmux/main/VERSION"
VC_VERSION_FILE="${AGENTMUX_VERSION_FILE:-$HOME/.agentmux/VERSION}"
VC_STATE_DIR="${AGENTMUX_VERSION_STATE:-${XDG_CACHE_HOME:-$HOME/.cache}/agentmux}"
VC_LATEST="$VC_STATE_DIR/latest"
VC_STAMP="$VC_STATE_DIR/version-check-stamp"
VC_MAX_AGE=86400   # 24h

_VC_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
. "$_VC_DIR/llm-config.sh"

# Strictly-newer semver compare (numeric, dot-separated). Pure POSIX — avoids
# `sort -V`, which BSD/macOS sort lacks. Returns 0 if REMOTE > LOCAL.
# Usage: _vc_is_newer LOCAL REMOTE
_vc_is_newer() {
  [ "$1" = "$2" ] && return 1
  _l="$1"; _r="$2"
  while [ -n "$_l" ] || [ -n "$_r" ]; do
    _lf="${_l%%.*}"; _rf="${_r%%.*}"
    case "$_lf" in ''|*[!0-9]*) _lf=0 ;; esac
    case "$_rf" in ''|*[!0-9]*) _rf=0 ;; esac
    if [ "$_rf" -gt "$_lf" ]; then return 0; fi
    if [ "$_rf" -lt "$_lf" ]; then return 1; fi
    case "$_l" in *.*) _l="${_l#*.}" ;; *) _l="" ;; esac
    case "$_r" in *.*) _r="${_r#*.}" ;; *) _r="" ;; esac
  done
  return 1
}

# Print the upgrade notice to stderr if the cached latest is newer than local.
_vc_emit_notice() {
  [ -f "$VC_LATEST" ] && [ -f "$VC_VERSION_FILE" ] || return 0
  _local=$(tr -d '[:space:]' < "$VC_VERSION_FILE" 2>/dev/null)
  _remote=$(tr -d '[:space:]' < "$VC_LATEST" 2>/dev/null)
  [ -n "$_local" ] && [ -n "$_remote" ] || return 0
  if _vc_is_newer "$_local" "$_remote"; then
    echo "agentmux v$_remote available (you have $_local) — run 'amux --update'" >&2
  fi
}

# True if the cached version is stale (stamp missing or older than VC_MAX_AGE).
_vc_stale() {
  [ -f "$VC_STAMP" ] || return 0
  # date +%s / stat are universal on our macOS/Linux targets; the `|| echo 0`
  # guards are belt-and-suspenders. If both fell back to 0 the diff reads as
  # "fresh" and the refresh is skipped — acceptable, since that only happens
  # with a broken base toolchain, in which case the curl fetch would fail too.
  _now=$(date +%s 2>/dev/null || echo 0)
  _then=$(stat -c %Y "$VC_STAMP" 2>/dev/null || stat -f %m "$VC_STAMP" 2>/dev/null || echo 0)
  [ "$((_now - _then))" -ge "$VC_MAX_AGE" ]
}

# Fork a detached background refresh of the cache (curl raw VERSION).
_vc_refresh_bg() {
  command -v curl >/dev/null 2>&1 || return 0
  mkdir -p "$VC_STATE_DIR" 2>/dev/null || return 0
  # Stamp now so a slow/failing fetch doesn't re-fork on every invocation today.
  : > "$VC_STAMP" 2>/dev/null
  (
    _tmp="$VC_LATEST.tmp.$$"
    if curl -fsS --max-time 3 "$VC_RAW_URL" 2>/dev/null | tr -d '[:space:]' > "$_tmp" 2>/dev/null \
       && [ -s "$_tmp" ]; then
      mv "$_tmp" "$VC_LATEST" 2>/dev/null
    else
      rm -f "$_tmp" 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
}

# Enabled? AGENTMUX_VERSION_CHECK env (1/0) > [update].check TOML > off.
_vc_enabled() {
  case "${AGENTMUX_VERSION_CHECK:-}" in
    1|true|yes) return 0 ;;
    0|false|no) return 1 ;;
  esac
  _json=$(_amux_config_json) || return 1
  [ -n "$_json" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  [ "$(printf '%s' "$_json" | jq -r '.update.check // false' 2>/dev/null)" = "true" ]
}

_vc_main() {
  _vc_enabled || return 0
  _vc_emit_notice
  _vc_stale && _vc_refresh_bg
  return 0
}

# Selftest: VERSION_CHECK_SELFTEST=1 sh scripts/version_check.sh   (no network)
if [ "${VERSION_CHECK_SELFTEST:-}" = "1" ]; then
  pass=0; fail=0
  _assert() {
    if [ "$3" = "$2" ]; then echo "PASS: $1"; pass=$((pass+1));
    else echo "FAIL: $1 — expected '$2' got '$3'"; fail=$((fail+1)); fi
  }
  _isnew() { if _vc_is_newer "$1" "$2"; then echo yes; else echo no; fi; }

  _assert "0.3.0 < 0.4.0"      yes "$(_isnew 0.3.0 0.4.0)"
  _assert "0.3.0 < 0.3.1"      yes "$(_isnew 0.3.0 0.3.1)"
  _assert "equal not newer"    no  "$(_isnew 0.3.0 0.3.0)"
  _assert "0.4.0 not < 0.3.9"  no  "$(_isnew 0.4.0 0.3.9)"
  _assert "1.0.0 not < 0.9.9"  no  "$(_isnew 1.0.0 0.9.9)"
  _assert "0.9.9 < 1.0.0"      yes "$(_isnew 0.9.9 1.0.0)"
  _assert "0.3 < 0.3.1"        yes "$(_isnew 0.3 0.3.1)"
  _assert "0.3.1 not < 0.3"    no  "$(_isnew 0.3.1 0.3)"

  _td=$(mktemp -d)
  VC_VERSION_FILE="$_td/VERSION"; VC_LATEST="$_td/latest"
  printf '0.3.0\n' > "$VC_VERSION_FILE"; printf '0.4.0\n' > "$VC_LATEST"
  _out=$(_vc_emit_notice 2>&1 >/dev/null)
  case "$_out" in *"v0.4.0 available (you have 0.3.0)"*) _r=ok ;; *) _r="bad:$_out" ;; esac
  _assert "notice when newer" ok "$_r"
  printf '0.4.0\n' > "$VC_VERSION_FILE"
  _out=$(_vc_emit_notice 2>&1 >/dev/null)
  _assert "no notice when current" "" "$_out"
  rm -rf "$_td"

  echo "---"; echo "Passed: $pass  Failed: $fail"
  [ "$fail" -eq 0 ]
  exit $?
fi

_vc_main
