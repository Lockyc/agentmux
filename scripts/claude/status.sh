#!/bin/sh
# Claude Code hook glue — sets Claude-specific adapter paths + agent name,
# parses Claude Code's working-hook payload (.prompt / .transcript_path),
# then execs the shared tmux-status.sh core.
# Wire this in ~/.claude/settings.json for all Claude Code hook events.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export AGENTMUX_AGENT_NAME="${AGENTMUX_AGENT_NAME:-claude}"
export AGENTMUX_CTX_BIN="${AGENTMUX_CTX_BIN:-$SCRIPT_DIR/ctx.sh}"
export AGENTMUX_DIGEST_BIN="${AGENTMUX_DIGEST_BIN:-$SCRIPT_DIR/digest.sh}"

# Only the working hook receives the payload that drives the summariser.
# Read stdin ONLY on that state — the other hooks don't get a payload, and
# `cat` would block forever waiting on a tty if invoked manually.
if [ "$1" = "working" ] && [ ! -t 0 ] && command -v jq >/dev/null 2>&1; then
  _payload=$(cat)
  AGENTMUX_HOOK_PROMPT=$(printf '%s' "$_payload" | jq -r '.prompt // empty' 2>/dev/null)
  AGENTMUX_HOOK_TRANSCRIPT=$(printf '%s' "$_payload" | jq -r '.transcript_path // empty' 2>/dev/null)
  export AGENTMUX_HOOK_PROMPT AGENTMUX_HOOK_TRANSCRIPT
fi

# Durable session log: contribute Claude's precise-resume hint (uuid = transcript
# basename) and its fork command. The resume subcommand dedups per window, so
# calling on every working hook is cheap. Claude-specific data only; the log core
# stays agent-agnostic — recording fork_cmd here is what declares that THIS agent
# can fork, so amux never composes `--fork-session` for an agent that lacks it.
if [ -n "${AGENTMUX_HOOK_TRANSCRIPT:-}" ]; then
  _uuid=$(basename "$AGENTMUX_HOOK_TRANSCRIPT" .jsonl)
  "$SCRIPT_DIR/../session_log.sh" resume "$_uuid" \
    "claude --resume $_uuid" \
    "claude --resume $_uuid --fork-session" 2>/dev/null || true
fi

exec "$SCRIPT_DIR/../tmux-status.sh" "$@"
