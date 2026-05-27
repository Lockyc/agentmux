#!/usr/bin/env bash
# install.sh — installs agentmux to ~/.agentmux/
# Usage: bash install.sh

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$HOME/.agentmux"

echo "Installing agentmux to $INSTALL_DIR ..."

mkdir -p "$INSTALL_DIR/scripts" "$INSTALL_DIR/shell" "$INSTALL_DIR/tmux"

# Copy scripts (exclude claude_*.sh and tmux-status.sh — those live in ~/.claude/hooks/)
for f in "$REPO_DIR"/scripts/*.sh; do
  case "$(basename "$f")" in
    claude_*.sh|tmux-status.sh) continue ;;
  esac
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
echo "  Copy hook scripts to ~/.claude/hooks/ and wire them in ~/.claude/settings.json."
echo "  See README for the full settings.json snippet."
echo ""
echo "  mkdir -p ~/.claude/hooks"
echo "  cp $REPO_DIR/scripts/tmux-status.sh $REPO_DIR/scripts/claude_ctx.sh $REPO_DIR/scripts/claude_digest.sh ~/.claude/hooks/"
echo "  chmod +x ~/.claude/hooks/tmux-status.sh ~/.claude/hooks/claude_ctx.sh ~/.claude/hooks/claude_digest.sh"
echo ""
echo "  Also requires LM Studio running at localhost:1234 for AI summaries."
