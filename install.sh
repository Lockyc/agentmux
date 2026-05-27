#!/usr/bin/env bash
# install.sh — installs agentmux to ~/.agentmux/
# Usage: bash install.sh

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.agentmux"

VERSION="$(cat "$REPO_DIR/VERSION" 2>/dev/null | tr -d '[:space:]')"
echo "Installing agentmux${VERSION:+ v$VERSION} to $INSTALL_DIR ..."

mkdir -p "$INSTALL_DIR/scripts" "$INSTALL_DIR/shell" "$INSTALL_DIR/tmux"

# Copy all scripts
for f in "$REPO_DIR"/scripts/*.sh; do
  dest="$INSTALL_DIR/scripts/$(basename "$f")"
  [ "$f" -ef "$dest" ] || cp "$f" "$dest"
done
chmod +x "$INSTALL_DIR/scripts/"*.sh

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
echo "Optional — Claude Code AI tab states + summary status lines:"
echo "  Wire the hooks in ~/.claude/settings.json (see README for full snippet):"
echo ""
echo '  "SessionStart":      tmux-status.sh start'
echo '  "UserPromptSubmit":  tmux-status.sh working'
echo '  "PostToolUse":       tmux-status.sh working'
echo '  "Notification":      tmux-status.sh notify'
echo '  "PermissionRequest": tmux-status.sh permission'
echo '  "Stop":              tmux-status.sh done'
echo ""
echo "  Hook command path: ~/.agentmux/scripts/tmux-status.sh <state>"
echo "  Also requires LM Studio running at localhost:1234 for AI summaries."
