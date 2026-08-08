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
  # The escaping must survive a round trip through a REAL shell — that, not the
  # literal output above, is the property that matters.
  _assert "shquote round-trips through sh" "wei'rd \$name \`x\` \"q\"" \
    "$(eval "printf '%s' $(_rm_shquote 'wei'"'"'rd $name `x` "q"')")"

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
  _assert "control path fits AF_UNIX" "ok" \
    "$([ "${#_rm_cp}" -lt 104 ] && echo ok || echo "too long: ${#_rm_cp}")"

  _rm_transport_argv et "bench" "sh -c 'true'"
  _assert "et argv" "et bench -c" "${RM_ARGV[0]} ${RM_ARGV[1]} ${RM_ARGV[2]}"
  _rm_transport_argv mosh "bench" "sh -c 'true'"
  _assert "mosh argv" "mosh bench --" "${RM_ARGV[0]} ${RM_ARGV[1]} ${RM_ARGV[2]}"
  _rm_transport_argv bogus "bench" "x"
  _assert "unknown transport rejected" "2" "$?"

  # ---- transport resolution + the mosh warning ----
  _rm_cfg="$(mktemp -d)/hosts.toml"; mkdir -p "$(dirname "$_rm_cfg")"
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

  echo "---- $pass passed, $fail failed"
  [ "$fail" -eq 0 ] || exit 1
  exit 0
fi
