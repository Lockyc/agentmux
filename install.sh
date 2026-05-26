#!/usr/bin/env bash
# install.sh — installs agentmux to ~/.agentmux/
# Usage: bash install.sh

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.agentmux"

echo "Installing agentmux to $INSTALL_DIR ..."

mkdir -p "$INSTALL_DIR/scripts" "$INSTALL_DIR/shell" "$INSTALL_DIR/tmux"

# Copy scripts
cp "$REPO_DIR"/scripts/*.sh "$INSTALL_DIR/scripts/"
chmod +x "$INSTALL_DIR/scripts/"*.sh

# Copy shell functions
cp "$REPO_DIR/shell/agentmux.sh" "$INSTALL_DIR/shell/agentmux.sh"

# Copy tmux snippet
cp "$REPO_DIR/tmux/agentmux.conf" "$INSTALL_DIR/tmux/agentmux.conf"

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
