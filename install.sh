#!/usr/bin/env bash
# install.sh — installs/updates agentmux at ~/.agentmux/ as a git clone.
# Usage:  bash install.sh
#    or:  curl -fsSL https://raw.githubusercontent.com/lockyc/agentmux/main/install.sh | bash

set -e

REPO_URL="https://github.com/lockyc/agentmux"
INSTALL_DIR="$HOME/.agentmux"

# A dev/symlink install has its bundle dirs symlinked to a working checkout.
_is_symlink_dev() {
  [ -L "$INSTALL_DIR/scripts" ] || [ -L "$INSTALL_DIR/bin" ] \
    || [ -L "$INSTALL_DIR/shell" ] || [ -L "$INSTALL_DIR/tmux" ]
}

if [ ! -e "$INSTALL_DIR" ]; then
  command -v git >/dev/null 2>&1 || { echo "agentmux: git is required to install" >&2; exit 1; }
  echo "Cloning agentmux into $INSTALL_DIR ..."
  git clone "$REPO_URL" "$INSTALL_DIR"
elif [ -d "$INSTALL_DIR/.git" ]; then
  command -v git >/dev/null 2>&1 || { echo "agentmux: git is required to update" >&2; exit 1; }
  echo "Updating agentmux clone in $INSTALL_DIR ..."
  git -C "$INSTALL_DIR" pull --ff-only
elif _is_symlink_dev; then
  echo "Detected dev/symlink install at $INSTALL_DIR — leaving it untouched."
else
  echo "agentmux: existing non-clone install at $INSTALL_DIR." >&2
  echo "Run /agentmux:install to migrate it safely (backs up your current install, preserves agents.toml)." >&2
  exit 1
fi

VERSION="$(tr -d '[:space:]' < "$INSTALL_DIR/VERSION" 2>/dev/null || true)"

# Seed the user's config from the example if they don't have one yet.
if [ -f "$INSTALL_DIR/agents.toml" ]; then
  echo "Config already exists at $INSTALL_DIR/agents.toml — not overwritten."
elif [ -f "$INSTALL_DIR/config/agents.toml.example" ]; then
  cp "$INSTALL_DIR/config/agents.toml.example" "$INSTALL_DIR/agents.toml"
  echo "Created default config at $INSTALL_DIR/agents.toml — edit to suit."
else
  echo "No agents.toml.example found — create $INSTALL_DIR/agents.toml manually."
fi

echo ""
echo "agentmux${VERSION:+ v$VERSION} ready at $INSTALL_DIR."
echo ""
echo "Add the following to your shell config:"
echo ""
echo "  bash/zsh (~/.zshrc or ~/.bashrc):"
echo "    source ~/.agentmux/shell/agentmux.sh"
echo ""
echo "  fish (~/.config/fish/config.fish):"
echo "    source ~/.agentmux/shell/agentmux.fish"
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
echo "  \"PermissionRequest\": claude/status.sh permission --notify 'Claude is waiting for permission'"
echo "  \"Stop\":              claude/status.sh done --notify 'Claude has finished working'"
echo ""
echo "  Hook command path: ~/.agentmux/scripts/claude/status.sh <state>"
echo ""
echo "AI summary status lines require an OpenAI-compatible endpoint (LM Studio,"
echo "Ollama, llama.cpp, etc.). Default: http://localhost:1234/v1/chat/completions."
echo "Configure via [llm] in ~/.agentmux/agents.toml or AGENTMUX_LLM_URL."
echo ""
echo "Optional — enable a once-daily update check: set [update] check = true"
echo "in ~/.agentmux/agents.toml. Update any time with: amux --update"
echo ""
echo "Side-terminal layout: 'amux --frame [agent] [session]' opens a bare terminal"
echo "in the left pane beside amux in the right (a nested tmux on its own socket)."
echo "Set the left-pane width with [frame] left = <percent> in ~/.agentmux/agents.toml;"
echo "optionally split the left column top/bottom with [frame] left_vertical_split = <percent>."
echo "[frame] focus = agent|terminal picks the start pane; status_position = bottom|top"
echo "moves the bar; default = true makes a bare 'amux' open a frame ('amux --no-frame' opts out)."
echo ""
echo "For non-Claude agents: see README 'Adding an agent integration'."
