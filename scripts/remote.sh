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

# ---------------------------------------------------------------------------
# Quoting and the remote command
# ---------------------------------------------------------------------------

# _rm_shquote <string> — wrap in single quotes, escaping embedded ones as '\''.
#
# Deliberately POSIX single-quoting rather than bash's `printf %q`: the command
# is first parsed by the REMOTE user's LOGIN shell, which may be fish. bash, zsh
# and fish all treat '…' literally and all accept the '\'' idiom, whereas %q
# emits bash-specific forms ($'…') that fish mis-parses.
_rm_shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# _rm_remote_cmd <dir> <prog> [<arg>...]
# Builds the single string the transport hands to the remote login shell:
#   sh -c 'cd <dir> && exec <prog> <args...>'
#
# <dir> and every <arg> are quoted. <prog> is inserted RAW and by design: the
# default is '"$HOME"/.agentmux/bin/amux', whose $HOME must be expanded by the
# REMOTE sh (the remote home is frequently not the local one), and the config's
# `amux` field is documented as accepting a wrapper or leading env assignments.
# It is config-controlled, never user input from the command line.
#
# `sh -c` rather than trusting the login shell: the remote `amux` we invoke is
# the standalone bin/amux script, so nothing here depends on the remote user
# having sourced agentmux's shell integration.
_rm_remote_cmd() {
  local dir="$1" prog="$2"; shift 2
  local inner a
  inner="cd $(_rm_shquote "$dir") && exec $prog"
  for a in "$@"; do inner="$inner $(_rm_shquote "$a")"; done
  printf 'sh -c %s' "$(_rm_shquote "$inner")"
}

# ---------------------------------------------------------------------------
# Transports
# ---------------------------------------------------------------------------

# Where ssh keeps its multiplexing sockets. Under AGENTMUX_USER_DIR so an
# isolated test run redirects it the same way the tmux overlays are redirected.
_rm_control_dir() {
  printf '%s/ssh' "${AGENTMUX_USER_DIR:-$HOME/.agentmux}"
}

# _rm_transport_for_host <index> — the host's transport, defaulting to ssh.
_rm_transport_for_host() {
  local t; t="$(agentmux_host_field "$1" transport)"
  printf '%s' "${t:-ssh}"
}

# _rm_mosh_warn <host> — one-time-per-run warning that mosh degrades agentmux.
#
# Not a refusal: mosh is genuinely better on a bad enough link, and the choice is
# the user's. But the degradation is SILENT — notifications simply stop — so it
# is stated at use rather than left to be discovered.
_rm_mosh_warn() {
  case "${RM_MOSH_WARNED:-}" in
    *"|$1|"*) return 0 ;;
  esac
  RM_MOSH_WARNED="${RM_MOSH_WARNED:-}|$1|"
  cat >&2 <<EOF
amux: $1 uses the mosh transport — some agentmux features will not work.
      mosh re-emulates the terminal and forwards only escapes it knows, so
      desktop notifications (OSC 777), OSC 52 clipboard and tmux passthrough
      are dropped. Nothing will report an error; they just stop.
      Use transport = "ssh" (or "et") unless the link genuinely needs mosh.
EOF
}

# _rm_transport_argv <kind> <ssh_target> <remote_cmd> [--batch]
# Sets RM_ARGV to the full argv. Returns 2 on an unknown kind.
#
# --batch builds the NON-INTERACTIVE form (preflight, roster, bootstrap): no
# tty, no stdin. It is a flag here rather than a second builder so the ssh
# options below have exactly one home — the two forms differ only in -t vs -n,
# and a separate non-interactive builder would drift the moment one of the
# ControlMaster or keepalive options changed.
#
# ssh options, each load-bearing:
#   -t                     force a tty; tmux cannot attach without one
#   ControlMaster=auto     multiplex — preflight, roster refresh and reconnect
#   ControlPersist=10m     all reuse one authenticated connection, so the second
#                          and later calls to a host skip the handshake entirely
#   ControlPath=<dir>/%C   %C is a FIXED-LENGTH hash. A ControlPath is an
#                          AF_UNIX socket with a 104-char limit, and the obvious
#                          %r@%h:%p form blows it on a long alias under a long
#                          $HOME — the same limit the selftests hit with
#                          TMUX_TMPDIR. Never change %C back to the readable form.
#   ServerAlive*           surface a dead link in ~15s instead of hanging, which
#                          is what lets the supervise loop react at all
_rm_transport_argv() {
  local kind="$1" target="$2" cmd="$3" batch="${4:-}" cdir tty
  RM_ARGV=()
  case "$kind" in
    ssh)
      cdir="$(_rm_control_dir)"
      mkdir -p "$cdir" 2>/dev/null
      tty=-t; [ "$batch" = "--batch" ] && tty=-n
      RM_ARGV=(ssh "$tty"
        -o ControlMaster=auto
        -o ControlPersist=10m
        -o "ControlPath=$cdir/%C"
        -o ServerAliveInterval=5
        -o ServerAliveCountMax=3
        "$target" "$cmd")
      ;;
    et)
      # ET does its own resumption over a transparent TCP stream, so it needs
      # no multiplexing options and no keepalive tuning.
      RM_ARGV=(et "$target" -c "$cmd")
      ;;
    mosh)
      RM_ARGV=(mosh "$target" -- "$cmd")
      ;;
    *)
      return 2
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Exit classification
# ---------------------------------------------------------------------------

# _rm_classify_exit <kind> <status> — clean | retry | fail
#
# THE BIAS IS DELIBERATE AND ASYMMETRIC: anything not positively known to be a
# transport failure classifies as clean/fail, i.e. exit. The two errors are not
# equal. A missed reconnect costs one retyped command; a false retry traps the
# user in a terminal that keeps redialling a session they deliberately left, and
# the remote session is safe in both cases. Never widen `retry` to "non-zero".
#
# ssh reserves 255 for its own failures; every other non-zero status is the
# REMOTE command's (amux couldn't start, the dir vanished) and must not retry —
# reconnecting would reproduce it forever.
#
# 130 (SIGINT) and 143 (SIGTERM) are the user asking to stop. 129 (SIGHUP) and
# 141 (SIGPIPE) are the link dying under us, which is exactly what to retry.
#
# et and mosh reconnect internally, so reaching us at all means they gave up:
# any non-zero is a link they could not restore, and worth another attempt from
# a fresh process.
_rm_classify_exit() {
  local kind="$1" st="$2"
  case "$st" in
    0)       printf 'clean'; return 0 ;;
    127)     printf 'fail'; return 0 ;;
    130|143) printf 'clean'; return 0 ;;
    129|141) printf 'retry'; return 0 ;;
  esac
  # 127 (command not found) is shared because it is never a transport failure —
  # it means the remote program does not exist, and retrying will reproduce it
  # forever. This applies to all transports: ssh, et, and mosh. The per-kind
  # logic below handles failures that *are* transport-specific.
  case "$kind" in
    ssh)
      case "$st" in
        255) printf 'retry' ;;
        *)   printf 'fail' ;;
      esac
      ;;
    *) printf 'retry' ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# The remote amux program for host <index>, or the default.
# Raw-inserted into the remote sh (see _rm_remote_cmd), so $HOME expands there.
_rm_prog_for_host() {
  local p; p="$(agentmux_host_field "$1" amux)"
  printf '%s' "${AGENTMUX_REMOTE_TEST_PROG:-${p:-\"\$HOME\"/.agentmux/bin/amux}}"
}

# _rm_preflight_script <project> <path> <roots-newline>
# The sh program run on the remote. Prints exactly one line:
#   RM_OK<TAB><abs-dir><TAB><amux-version>
#   RM_ERR<TAB><code><TAB><message>
#
# Runs BEFORE any tty is allocated, and that ordering is what makes the retry
# loop safe: a bad host, a refused key, a missing project or an uninstalled
# agentmux all surface here, where nothing retries. The supervise loop is only
# ever reached once a session was genuinely established.
#
# Resolution is "a directory named <project>, containing .git, under a root".
# Requiring .git is what makes `amux @host <name>` mean the same thing as the
# roster shows; an arbitrary directory is reachable via the explicit
# @host:<path> form, which skips this entirely.
#
# -maxdepth is not POSIX but is universal on GNU and BSD find. `-quit`/-printf
# are NOT — macOS remotes lack them — so this pipes to head instead.
_rm_preflight_script() {
  local project="$1" path="$2" roots="$3" prog="$4"
  # shellcheck disable=SC2016  # $-vars below are for the REMOTE shell, not us
  printf '%s\n' \
    "project=$(_rm_shquote "$project")" \
    "path=$(_rm_shquote "$path")" \
    "roots=$(_rm_shquote "$roots")" \
    'TAB=$(printf "\t")' \
    'err() { printf "RM_ERR%s%s%s%s\n" "$TAB" "$1" "$TAB" "$2"; exit 0; }' \
    'if [ -n "$path" ]; then' \
    '  d=$(eval printf %s "$path")' \
    '  [ -d "$d" ] || err nodir "no such directory on the remote: $path"' \
    '  dir=$(cd "$d" && pwd)' \
    'else' \
    '  [ -n "$project" ] || err notfound "no project given"' \
    '  [ -n "$roots" ]   || err noroots "host has no roots = [...] configured"' \
    '  found=""; n=0' \
    '  IFS="' \
    '"' \
    '  for r in $roots; do' \
    '    r=$(eval printf %s "$r")' \
    '    [ -d "$r" ] || continue' \
    '    for c in $(find "$r" -maxdepth 4 -type d -name "$project" 2>/dev/null); do' \
    '      [ -e "$c/.git" ] || continue' \
    '      n=$((n+1)); found="$found$c' \
    '"' \
    '    done' \
    '  done' \
    '  [ "$n" -eq 0 ] && err notfound "no project named \"$project\" under this host'"'"'s roots"' \
    '  if [ "$n" -gt 1 ]; then' \
    '    err ambiguous "\"$project\" matches $n directories: $(printf %s "$found" | tr "\n" " ")"' \
    '  fi' \
    '  dir=$(printf %s "$found" | head -n1)' \
    'fi' \
    "v=\$($prog --version 2>/dev/null | awk '{print \$NF}')" \
    '[ -n "$v" ] || err noamux "agentmux is not installed on this host"' \
    'printf "RM_OK%s%s%s%s\n" "$TAB" "$dir" "$TAB" "$v"'
}

# _rm_run <kind> <target> <cmd> — a NON-INTERACTIVE transport call.
# Reuses the ControlMaster the interactive session will use, so it is nearly
# free after the first call to a host. Returns the transport's exit status.
#
# AGENTMUX_REMOTE_TRANSPORT_CMD replaces the argv wholesale, with <cmd> appended
# last. That is the offline test seam and the ONLY way the selftests exercise
# this path — never add a second bypass.
_rm_run() {
  local kind="$1" target="$2" cmd="$3"
  if [ -n "${AGENTMUX_REMOTE_TRANSPORT_CMD:-}" ]; then
    "$AGENTMUX_REMOTE_TRANSPORT_CMD" "$target" "$cmd"
    return $?
  fi
  _rm_transport_argv "$kind" "$target" "$cmd" --batch || return 2
  "${RM_ARGV[@]}"
}

# _rm_preflight <host_index> <project> <path>
# Sets RM_DIR, RM_VERSION, RM_ERRCODE, RM_ERRMSG.
# Returns 0 ok, 1 resolved error (RM_ERRCODE set), 3 transport failure.
_rm_preflight() {
  local hi="$1" project="$2" path="$3"
  RM_DIR=""; RM_VERSION=""; RM_ERRCODE=""; RM_ERRMSG=""
  local target kind roots prog script out st TAB; TAB=$(printf '\t')
  target="$(agentmux_host_field "$hi" ssh)"
  kind="$(_rm_transport_for_host "$hi")"
  # Validated HERE, before ever calling _rm_run: an unknown `transport =`
  # value is a config mistake, not a flaky link, so it must resolve as rc 1
  # (RM_ERRCODE=badtransport) rather than fall through to _rm_run/
  # _rm_transport_argv's own `return 2`, which _rm_run turns into rc 3 —
  # "transport failure", the ONE code a caller may ever retry. Retrying a
  # typo'd transport can never succeed; the list mirrors _rm_transport_argv's
  # case statement and must be kept in sync with it.
  case "$kind" in
    ssh|et|mosh) : ;;
    *)
      RM_ERRCODE="badtransport"
      RM_ERRMSG="unknown transport \"$kind\" (must be one of: ssh, et, mosh)"
      return 1
      ;;
  esac
  roots="$(agentmux_host_roots "$hi")"
  prog="$(_rm_prog_for_host "$hi")"
  script="$(_rm_preflight_script "$project" "$path" "$roots" "$prog")"
  out="$(_rm_run "$kind" "$target" "sh -c $(_rm_shquote "$script")" 2>/dev/null)"
  st=$?
  if [ "$st" -ne 0 ] || [ -z "$out" ]; then
    RM_ERRCODE="transport"
    RM_ERRMSG="could not reach $target (transport exited $st)"
    return 3
  fi
  out="$(printf '%s\n' "$out" | grep -E '^RM_(OK|ERR)' | tail -n1)"
  case "$out" in
    RM_OK*)
      RM_DIR="$(printf '%s' "$out" | cut -d"$TAB" -f2)"
      RM_VERSION="$(printf '%s' "$out" | cut -d"$TAB" -f3)"
      return 0
      ;;
    RM_ERR*)
      RM_ERRCODE="$(printf '%s' "$out" | cut -d"$TAB" -f2)"
      RM_ERRMSG="$(printf '%s' "$out" | cut -d"$TAB" -f3)"
      return 1
      ;;
  esac
  RM_ERRCODE="transport"; RM_ERRMSG="unrecognised preflight reply"
  return 3
}

# ============================ selftest ============================
# REMOTE_SELFTEST=1 bash scripts/remote.sh
if [ "${REMOTE_SELFTEST:-}" = "1" ]; then
  unset REMOTE_SELFTEST
  pass=0; fail=0
  _assert() { if [ "$3" = "$2" ]; then pass=$((pass+1)); echo "PASS: $1"
              else fail=$((fail+1)); echo "FAIL: $1 — expected '$2' got '$3'"; fi; }

  # ---- isolation ----
  # _rm_control_dir falls back to $HOME/.agentmux when AGENTMUX_USER_DIR is unset,
  # and _rm_transport_argv's ssh branch unconditionally `mkdir -p`s it — so every
  # assertion below that touches the ssh transport (directly, or via the
  # throwaway hosts.toml fixture further down) must run under a redirected
  # AGENTMUX_USER_DIR, the same seam AGENTMUX_STATE_DIR/TMUX_TMPDIR use elsewhere
  # in this repo's selftests (see CLAUDE.md's Selftests section) — without it this
  # block creates a real directory in the user's actual home. A short LITERAL dir,
  # not `mktemp -d`: a macOS mktemp path plus "/ssh/<hash>" can itself approach
  # the 104-char AF_UNIX limit the tests further below exist to guard, which
  # would fail a correct implementation for an unrelated reason. EXIT-only trap,
  # idempotent — this repo's selftest convention (no INT/TERM; see CLAUDE.md).
  _RM_TEST_DIR="/tmp/rmtest-$$"
  _rm_cleanup_done=""
  _rm_cleanup() {
    [ -n "$_rm_cleanup_done" ] && return 0
    _rm_cleanup_done=1
    rm -rf "$_RM_TEST_DIR"
  }
  trap _rm_cleanup EXIT
  rm -rf "$_RM_TEST_DIR"
  mkdir -p "$_RM_TEST_DIR"
  export AGENTMUX_USER_DIR="$_RM_TEST_DIR/agentmux-user"

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

  # Multi-arg RM_REST with space-containing arg must preserve element count and
  # content — guards against accidental join of array elements (would fail if
  # RM_REST were set to ("$*") instead of ("$@")).
  _rm_parse_target "@buildbox" "--msg" "hello world"
  _assert "rest count with space arg" "2" "${#RM_REST[@]}"
  _assert "rest space-containing element" "hello world" "${RM_REST[1]}"

  # Paths with spaces survive as ONE element (the whole reason RM_REST is an
  # array and not a string).
  _rm_parse_target "@buildbox:~/my docs" "--probe"
  # shellcheck disable=SC2088
  _assert "path with space" "~/my docs" "$RM_PATH"

  _rm_parse_target "@" ; _assert "bare @ rejected" "2" "$?"
  _rm_parse_target "buildbox" ; _assert "no sigil rejected" "2" "$?"
  _rm_parse_target "@:x" ; _assert "empty host rejected" "2" "$?"

  # ---- quoting ----
  _assert "shquote plain" "'abc'" "$(_rm_shquote abc)"
  _assert "shquote space" "'a b'" "$(_rm_shquote 'a b')"
  _assert "shquote single quote" "'it'\\''s'" "$(_rm_shquote "it's")"

  # The escaping must survive a round trip through a REAL, SEPARATE shell
  # process — `_rm_shquote` exists specifically because the remote login shell
  # may be fish, which mis-parses bash's `printf %q` output, so an `eval` inside
  # THIS bash process (the previous version of this test) proves nothing: eval
  # is itself bash and would happily accept bash-only escaping too. Adversarial
  # input covers every character `_rm_shquote`'s single-quoting has to defeat:
  # single quotes, double quotes, backslashes, `$`, and backticks.
  _rm_adv='it'"'"'s "tricky" \slash $var `cmd`'
  _rm_adv_q="$(_rm_shquote "$_rm_adv")"
  _assert "shquote round-trips through sh" "$_rm_adv" \
    "$(sh -c "printf '%s' $_rm_adv_q")"
  if command -v fish >/dev/null 2>&1; then
    _assert "shquote round-trips through fish" "$_rm_adv" \
      "$(fish -c "printf '%s' $_rm_adv_q")"
  else
    echo "SKIP: shquote round-trips through fish — fish not installed"
  fi

  # ---- remote command ----
  _assert "remote cmd cds and execs" \
    "sh -c 'cd '\\''/srv/p'\\'' && exec \"\$HOME\"/.agentmux/bin/amux'" \
    "$(_rm_remote_cmd "/srv/p" '"$HOME"/.agentmux/bin/amux')"
  # $HOME must NOT be expanded locally — the remote home is the one that counts.
  _assert "remote cmd leaves \$HOME for the remote" "1" \
    "$(_rm_remote_cmd "/srv/p" '"$HOME"/.agentmux/bin/amux' | grep -c '\$HOME')"
  _assert "remote cmd quotes forwarded args" "1" \
    "$(_rm_remote_cmd "/srv/p" amux --kill "a b" | grep -c "'a b'")"

  # ---- transport argv ----
  _rm_transport_argv ssh "root@buildbox" "sh -c 'true'"
  _assert "ssh argv starts with ssh -t" "ssh -t" "${RM_ARGV[0]} ${RM_ARGV[1]}"
  _assert "ssh argv has ControlMaster" "1" \
    "$(printf '%s\n' "${RM_ARGV[@]}" | grep -c 'ControlMaster=auto')"
  _assert "ssh argv target present" "1" \
    "$(printf '%s\n' "${RM_ARGV[@]}" | grep -cx 'root@buildbox')"
  _assert "ssh argv ends with the remote command" "sh -c 'true'" \
    "${RM_ARGV[$(( ${#RM_ARGV[@]} - 1 ))]}"
  # --batch swaps ONLY the tty flag; every other option must be identical, which
  # is the property that makes one builder correct instead of two.
  _rm_transport_argv ssh "root@buildbox" "sh -c 'true'" --batch
  _assert "batch argv uses -n not -t" "ssh -n" "${RM_ARGV[0]} ${RM_ARGV[1]}"
  _assert "batch argv keeps ControlMaster" "1" \
    "$(printf '%s\n' "${RM_ARGV[@]}" | grep -c 'ControlMaster=auto')"
  # The ControlPath is an AF_UNIX socket: 104 chars is a hard kernel limit, and
  # %C (a fixed-length hash) is what keeps it bounded regardless of how long the
  # ssh alias or $HOME is. A %r@%h:%p path would blow it on a long alias.
  _rm_cp="$(printf '%s\n' "${RM_ARGV[@]}" | sed -n 's/^ControlPath=//p')"
  _assert "control path uses %C" "1" "$(printf '%s' "$_rm_cp" | grep -c '%C$')"
  # Must measure the EXPANDED length ssh will actually create, not the
  # un-substituted template — the template is always short (it's a literal
  # 2-char "%C"), so comparing ITS length against 104 passes even for the
  # readable %r@%h:%p form this whole design avoids, which is what made the
  # previous version of this assertion close to vacuous. %C is ssh's SHA1 hex
  # digest of user+host+port+localhost: always exactly 40 chars, independent of
  # the alias — the one thing that makes the total length provably bounded. Any
  # other trailing token (%r@%h:%p, or anything else) has NO such bound (%h/%r
  # can be arbitrarily long DNS names or usernames), so it can't be certified
  # safe and this fails on sight rather than measuring a short test fixture that
  # happens to pass — which is what makes it actually fail if someone "improves"
  # %C into the readable form.
  _RM_SHA1_HEX_LEN=40
  case "$_rm_cp" in
    *%C)
      _rm_cp_prefix="${_rm_cp%\%C}"
      _rm_cp_worst=$(( ${#_rm_cp_prefix} + _RM_SHA1_HEX_LEN ))
      _rm_cp_result="$([ "$_rm_cp_worst" -lt 104 ] && echo ok || echo "too long: $_rm_cp_worst")"
      ;;
    *)
      _rm_cp_result="unbounded — not %C-terminated, cannot certify a length bound"
      ;;
  esac
  _assert "control path fits AF_UNIX (expanded worst case)" "ok" "$_rm_cp_result"

  _rm_transport_argv et "bench" "sh -c 'true'"
  _assert "et argv" "et bench -c" "${RM_ARGV[0]} ${RM_ARGV[1]} ${RM_ARGV[2]}"
  _rm_transport_argv mosh "bench" "sh -c 'true'"
  _assert "mosh argv" "mosh bench --" "${RM_ARGV[0]} ${RM_ARGV[1]} ${RM_ARGV[2]}"
  _rm_transport_argv bogus "bench" "x"
  _assert "unknown transport rejected" "2" "$?"

  # ---- transport resolution + the mosh warning ----
  # Reuses the isolated $_RM_TEST_DIR set up at the top of this block (reaped by
  # the same EXIT trap) instead of a second `mktemp -d` — the old `mktemp -d`
  # here was never removed and leaked a throwaway temp dir on every run.
  _rm_cfg="$_RM_TEST_DIR/hosts.toml"
  cat > "$_rm_cfg" <<'TOML'
[[hosts]]
name = "a"
ssh  = "a"
[[hosts]]
name      = "b"
ssh       = "b"
transport = "mosh"
TOML
  export AGENTMUX_CONFIG="$_rm_cfg"; _amux_json_cache=""
  _assert "transport defaults to ssh" "ssh" "$(_rm_transport_for_host 0)"
  _assert "transport honours config"  "mosh" "$(_rm_transport_for_host 1)"
  _assert "mosh warns about notifications" "1" \
    "$(_rm_mosh_warn b 2>&1 >/dev/null | grep -ci 'notification')"

  # ---- exit classification ----
  _assert "ssh 0 is clean"          "clean" "$(_rm_classify_exit ssh 0)"
  _assert "ssh 255 is retry"        "retry" "$(_rm_classify_exit ssh 255)"
  _assert "ssh SIGHUP (129) retry"  "retry" "$(_rm_classify_exit ssh 129)"
  _assert "ssh SIGPIPE (141) retry" "retry" "$(_rm_classify_exit ssh 141)"
  _assert "ssh SIGINT (130) clean"  "clean" "$(_rm_classify_exit ssh 130)"
  _assert "ssh SIGTERM (143) clean" "clean" "$(_rm_classify_exit ssh 143)"
  _assert "ssh 1 is fail"           "fail"  "$(_rm_classify_exit ssh 1)"
  _assert "ssh 127 is fail"         "fail"  "$(_rm_classify_exit ssh 127)"
  # et and mosh reconnect internally, so a non-zero exit from THEM means they
  # gave up — retrying is still right, but 255 carries no special meaning. The
  # shared signal codes (130/143 clean, 129/141 retry) and command-not-found (127
  # fail) apply to all transports.
  _assert "et 0 is clean"           "clean" "$(_rm_classify_exit et 0)"
  _assert "et 1 is retry"           "retry" "$(_rm_classify_exit et 1)"
  _assert "et 127 is fail"          "fail"  "$(_rm_classify_exit et 127)"
  _assert "et 130 is clean"         "clean" "$(_rm_classify_exit et 130)"
  _assert "et 143 is clean"         "clean" "$(_rm_classify_exit et 143)"
  _assert "et 129 is retry"         "retry" "$(_rm_classify_exit et 129)"
  _assert "et 141 is retry"         "retry" "$(_rm_classify_exit et 141)"
  _assert "mosh 0 is clean"         "clean" "$(_rm_classify_exit mosh 0)"
  _assert "mosh 4 is retry"         "retry" "$(_rm_classify_exit mosh 4)"
  _assert "mosh 127 is fail"        "fail"  "$(_rm_classify_exit mosh 127)"
  _assert "mosh 130 is clean"       "clean" "$(_rm_classify_exit mosh 130)"
  _assert "mosh 143 is clean"       "clean" "$(_rm_classify_exit mosh 143)"
  _assert "mosh 129 is retry"       "retry" "$(_rm_classify_exit mosh 129)"
  _assert "mosh 141 is retry"       "retry" "$(_rm_classify_exit mosh 141)"

  # ---- preflight, against a FAKE transport ----
  # AGENTMUX_REMOTE_TRANSPORT_CMD replaces the transport entirely and receives
  # the remote command as its last argument, so the whole preflight path runs
  # with no ssh, no network and no remote box. Same isolation idiom as
  # AGENTMUX_*_SOCKET. The stub runs the remote program under a real `sh`
  # against a real temp tree, so the resolution logic is genuinely exercised
  # rather than mocked away.
  #
  # Lives under $_RM_TEST_DIR (reaped by the EXIT trap above) rather than its
  # own `mktemp -d` — a second, unreaped throwaway dir is exactly the leak this
  # file's ControlPath fixture above was already fixed to stop causing.
  _rm_t="$_RM_TEST_DIR/preflight"
  mkdir -p "$_rm_t/roots/one/warden/.git" "$_rm_t/roots/one/lector/.git" \
           "$_rm_t/roots/two/warden/.git" "$_rm_t/plain"
  cat > "$_rm_t/stub" <<'STUB'
#!/bin/sh
# Last arg is the remote command; run it locally with sh, as a remote box would.
for a in "$@"; do last="$a"; done
exec sh -c "$last"
STUB
  chmod +x "$_rm_t/stub"
  cat > "$_rm_t/hosts.toml" <<TOML
[[hosts]]
name  = "fake"
ssh   = "fake"
roots = ["$_rm_t/roots/one"]

[[hosts]]
name  = "dup"
ssh   = "dup"
roots = ["$_rm_t/roots/one", "$_rm_t/roots/two"]

[[hosts]]
name = "norootshost"
ssh  = "x"

[[hosts]]
name      = "badtransporthost"
ssh       = "bt"
transport = "shh"
TOML
  export AGENTMUX_CONFIG="$_rm_t/hosts.toml"; _amux_json_cache=""
  export AGENTMUX_REMOTE_TRANSPORT_CMD="$_rm_t/stub"
  # A fake remote amux so the "is agentmux installed" check passes.
  printf '#!/bin/sh\necho 9.9.9\n' > "$_rm_t/amux"; chmod +x "$_rm_t/amux"
  export AGENTMUX_REMOTE_TEST_PROG="$_rm_t/amux"

  _rm_preflight 0 warden "" ; _rm_pf=$?
  _assert "preflight resolves a project" "0" "$_rm_pf"
  _assert "preflight dir" "$_rm_t/roots/one/warden" "$RM_DIR"
  _assert "preflight version" "9.9.9" "$RM_VERSION"

  _rm_preflight 0 nosuch "" ; _assert "preflight notfound rc" "1" "$?"
  _assert "preflight notfound code" "notfound" "$RM_ERRCODE"

  # Same project name under two roots must be an ERROR, not a silent first-wins:
  # picking one would launch an agent in the wrong repo, and nothing downstream
  # could tell.
  _rm_preflight 1 warden "" ; _assert "preflight ambiguous rc" "1" "$?"
  _assert "preflight ambiguous code" "ambiguous" "$RM_ERRCODE"
  # Pins what actually matters — the user is told WHICH directories collided
  # — not just a substring count a repeated single path could also satisfy.
  _assert "preflight ambiguous names root one" "1" \
    "$(printf '%s' "$RM_ERRMSG" | grep -Fc "$_rm_t/roots/one/warden")"
  _assert "preflight ambiguous names root two" "1" \
    "$(printf '%s' "$RM_ERRMSG" | grep -Fc "$_rm_t/roots/two/warden")"

  # An explicit path skips root resolution entirely — including for a dir that
  # is not a git repo and could never appear in the roster.
  _rm_preflight 0 "" "$_rm_t/plain" ; _assert "explicit path rc" "0" "$?"
  _assert "explicit path dir" "$_rm_t/plain" "$RM_DIR"
  _rm_preflight 0 "" "$_rm_t/nope" ; _assert "explicit missing path rc" "1" "$?"
  _assert "explicit missing path code" "nodir" "$RM_ERRCODE"

  # A host with no roots and no path cannot resolve anything.
  _rm_preflight 2 warden "" ; _assert "no roots rc" "1" "$?"
  _assert "no roots code" "noroots" "$RM_ERRCODE"

  # No remote amux → a distinct code, because it is the one error with a fix
  # we can offer (Task 7), not just report.
  AGENTMUX_REMOTE_TEST_PROG="$_rm_t/definitely-not-here" _rm_preflight 0 warden ""
  _assert "missing remote amux rc" "1" "$?"
  _assert "missing remote amux code" "noamux" "$RM_ERRCODE"

  # A misconfigured `transport =` value must be caught BEFORE ever touching
  # the transport layer and reported as a RESOLVED error (rc 1) — never rc 3
  # (transport failure), because only rc 3 may ever be retried by a caller,
  # and no amount of retrying fixes a typo'd transport kind.
  _rm_preflight 3 warden "" ; _assert "bad transport rc" "1" "$?"
  _assert "bad transport code" "badtransport" "$RM_ERRCODE"
  _assert "bad transport message names the bad value" "1" \
    "$(printf '%s' "$RM_ERRMSG" | grep -c 'shh')"

  # Transport failure (stub exits non-zero without running anything) must be
  # rc 3 — distinct from a resolved error, because only rc 3 may ever retry.
  printf '#!/bin/sh\nexit 255\n' > "$_rm_t/deadstub"; chmod +x "$_rm_t/deadstub"
  AGENTMUX_REMOTE_TRANSPORT_CMD="$_rm_t/deadstub" _rm_preflight 0 warden ""
  _assert "transport failure rc" "3" "$?"

  unset AGENTMUX_REMOTE_TRANSPORT_CMD AGENTMUX_REMOTE_TEST_PROG

  echo "---- $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi
