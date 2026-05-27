#!/usr/bin/env bash
# install.sh — installs agentmux to ~/.agentmux/
# Usage: bash install.sh

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.agentmux"

VERSION="$(cat "$REPO_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
echo "Installing agentmux${VERSION:+ v$VERSION} to $INSTALL_DIR ..."

mkdir -p "$INSTALL_DIR/scripts" "$INSTALL_DIR/shell" "$INSTALL_DIR/tmux"

# Copy top-level scripts
for f in "$REPO_DIR"/scripts/*.sh; do
  dest="$INSTALL_DIR/scripts/$(basename "$f")"
  [ "$f" -ef "$dest" ] || cp "$f" "$dest"
done
chmod +x "$INSTALL_DIR/scripts/"*.sh

# Copy agent-specific script subdirectories (scripts/claude/, scripts/gemini/, …)
for dir in "$REPO_DIR"/scripts/*/; do
  [ -d "$dir" ] || continue
  sub=$(basename "$dir")
  mkdir -p "$INSTALL_DIR/scripts/$sub"
  for f in "$dir"*.sh; do
    [ -f "$f" ] || continue
    dest="$INSTALL_DIR/scripts/$sub/$(basename "$f")"
    [ "$f" -ef "$dest" ] || cp "$f" "$dest"
  done
  for _f in "$INSTALL_DIR/scripts/$sub/"*.sh; do [ -f "$_f" ] && chmod +x "$_f"; done
done

# Copy shell functions
src="$REPO_DIR/shell/agentmux.sh"; dest="$INSTALL_DIR/shell/agentmux.sh"
[ "$src" -ef "$dest" ] || cp "$src" "$dest"

# Copy tmux snippet
src="$REPO_DIR/tmux/agentmux.conf"; dest="$INSTALL_DIR/tmux/agentmux.conf"
[ "$src" -ef "$dest" ] || cp "$src" "$dest"

# Copy VERSION
[ -f "$REPO_DIR/VERSION" ] && cp "$REPO_DIR/VERSION" "$INSTALL_DIR/VERSION"

# Create default config if none exists
if [ ! -f "$INSTALL_DIR/agents.toml" ]; then
  cp "$REPO_DIR/config/agents.toml.example" "$INSTALL_DIR/agents.toml"
  echo "Created default config at $INSTALL_DIR/agents.toml — edit to suit."
else
  echo "Config already exists at $INSTALL_DIR/agents.toml — not overwritten."
fi

echo ""
echo "Done. Add the following to your shell config (~/.zshrc or ~/.bashrc):"
echo ""
echo "  source ~/.agentmux/shell/agentmux.sh"
echo ""
echo "Add the following to your ~/.tmux.conf:"
echo ""
echo "  source-file ~/.agentmux/tmux/agentmux.conf"
echo ""
echo "Check dependencies:"
echo "  which toml2json || brew install go-toml"
echo "  which jq        || brew install jq"
echo ""
echo "Optional — Claude Code adapter (tab states + AI summary status lines):"
echo "  Wire the hooks in ~/.claude/settings.json (see README for full snippet):"
echo ""
echo '  "SessionStart":      claude/status.sh start'
echo '  "UserPromptSubmit":  claude/status.sh working'
echo '  "PostToolUse":       claude/status.sh working'
echo '  "Notification":      claude/status.sh notify'
echo '  "PermissionRequest": claude/status.sh permission'
echo '  "Stop":              claude/status.sh done'
echo ""
echo "  Hook command path: ~/.agentmux/scripts/claude/status.sh <state>"
echo ""
echo "AI summary status lines require an OpenAI-compatible endpoint (LM Studio,"
echo "Ollama, llama.cpp, etc.). Default: http://localhost:1234/v1/chat/completions."
echo "Configure via [llm] in ~/.agentmux/agents.toml or AGENTMUX_LLM_URL."
echo ""
echo "For non-Claude agents: see README 'Adding an agent integration'."
