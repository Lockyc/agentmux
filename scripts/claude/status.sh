#!/bin/sh
# Claude Code hook glue — sets Claude-specific adapter paths and agent name,
# then execs the shared tmux-status.sh core.
# Wire this in ~/.claude/settings.json for all Claude Code hook events.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export AGENTMUX_AGENT_NAME="${AGENTMUX_AGENT_NAME:-claude}"
export AGENTMUX_CTX_BIN="${AGENTMUX_CTX_BIN:-$SCRIPT_DIR/ctx.sh}"
export AGENTMUX_DIGEST_BIN="${AGENTMUX_DIGEST_BIN:-$SCRIPT_DIR/digest.sh}"
exec "$SCRIPT_DIR/../tmux-status.sh" "$@"
