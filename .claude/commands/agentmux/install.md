You are installing or updating **agentmux** — a configurable tmux agent launcher for Claude Code and other AI CLIs.

GitHub: `https://github.com/lockyc/agentmux`

---

## Steps

### 1. Detect repo location

Check whether the current working directory is the agentmux repo:

```bash
[ -f install.sh ] && [ -f VERSION ] && grep -q agentmux VERSION 2>/dev/null && echo "IN_REPO" || echo "NOT_IN_REPO"
```

**If in repo:** set `REPO_DIR` to the current working directory.

**If not in repo:** clone from GitHub into a temp directory:

```bash
CLONE_DIR=$(mktemp -d) && git clone --depth 1 https://github.com/lockyc/agentmux "$CLONE_DIR/agentmux" 2>&1 && echo "$CLONE_DIR/agentmux"
```

Set `REPO_DIR` to the cloned path.

### 2. Check dependencies

```bash
which toml2json >/dev/null 2>&1 && echo "toml2json: ok" || echo "toml2json: MISSING"
which jq        >/dev/null 2>&1 && echo "jq: ok"        || echo "jq: MISSING"
```

If either is missing, offer to install via Homebrew:

```bash
brew install go-toml   # for toml2json
brew install jq
```

If Homebrew is not available and deps are missing, warn the user and continue — install.sh will succeed but agentmux won't function until deps are present.

### 3. Check current install state

Determine what is already wired so defaults are smart:

```bash
[ -d ~/.agentmux ] && echo "installed" || echo "fresh"
grep -q "agentmux" ~/.zshrc 2>/dev/null   && echo "zshrc:wired"   || echo "zshrc:missing"
grep -q "agentmux" ~/.tmux.conf 2>/dev/null && echo "tmux:wired"    || echo "tmux:missing"
grep -q "agentmux" ~/.claude/settings.json 2>/dev/null && echo "hooks:wired" || echo "hooks:missing"
```

### 4. Run core install

```bash
bash "$REPO_DIR/install.sh"
```

If this fails, show the full error output and stop.

### 5. Ask what additional wiring to apply

Use AskUserQuestion with a **multi-select** question:

**"What should I wire up for you?"**

Options — mark as "Recommended" any that are not already detected as wired above:

- **Shell config** — adds `source ~/.agentmux/shell/agentmux.sh` to `~/.zshrc` (or `~/.bashrc`)
- **tmux config** — adds `source-file ~/.agentmux/tmux/agentmux.conf` to `~/.tmux.conf`
- **Claude Code hooks** — wires tab-state emojis and AI summary status lines into `~/.claude/settings.json`

### 6. Wire shell config (if selected)

Determine which shell config file to use: `~/.zshrc` if it exists, otherwise `~/.bashrc`.

Read the file. If `source ~/.agentmux/shell/agentmux.sh` is not already present, append:

```
# agentmux
source ~/.agentmux/shell/agentmux.sh
```

Report whether the line was already present or newly added.

### 7. Wire tmux config (if selected)

Read `~/.tmux.conf` (create it if it doesn't exist). If `source-file ~/.agentmux/tmux/agentmux.conf` is not already present, append:

```
# agentmux
source-file ~/.agentmux/tmux/agentmux.conf
```

Report whether the line was already present or newly added.

### 8. Wire Claude Code hooks (if selected)

The hooks to wire:

```json
{
  "SessionStart":      [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh start" }] }],
  "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh working" }] }],
  "PostToolUse":       [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh working" }] }],
  "Notification":      [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh notify" }] }],
  "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh permission --notify 'Claude is waiting for permission'" }] }],
  "Stop":              [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh done --notify 'Claude has finished working'" }] }]
}
```

**Merge rules — never remove or overwrite existing hooks from other tools:**

- If `~/.claude/settings.json` does not exist: write `{ "hooks": { <above> } }`.
- If it exists but has no `hooks` key: add the `hooks` key with the above content.
- If it exists with a `hooks` key: for each event name, check whether any entry in that event's array already has a `command` containing `agentmux`. If not, append our hook entry. Create the event array if absent.

Use `jq` to do the merge safely rather than editing JSON by hand.

### 9. Self-install this command

Write this command to `~/.claude/commands/agentmux/install.md` so `/agentmux:install` is available globally from any directory in future Claude Code sessions.

```bash
mkdir -p ~/.claude/commands/agentmux
```

Read this file from `$REPO_DIR/.claude/commands/agentmux/install.md` and write it verbatim to `~/.claude/commands/agentmux/install.md`.

### 10. Summary

Print a concise summary of each step: what was installed, what was already present, what was skipped.

Include relevant reload commands:

```bash
source ~/.zshrc           # reload shell (if shell config was wired)
tmux source ~/.tmux.conf  # reload tmux config (if tmux was wired) — or start a new tmux server
```

Remind the user to:
- Edit `~/.agentmux/agents.toml` to define their agents (the file was created from the example by the installer)
- Run `amux` to launch their first session
- Restart Claude Code if hooks were wired (hooks take effect on next session start)
