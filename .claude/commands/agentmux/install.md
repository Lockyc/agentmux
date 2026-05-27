You are installing or updating **agentmux** — a configurable tmux agent launcher for Claude Code and other AI CLIs.

GitHub: `https://github.com/lockyc/agentmux`

---

## Steps

### 1. Detect repo location

Check whether the current working directory is the agentmux repo:

```bash
[ -f install.sh ] && [ -f VERSION ] && [ -f scripts/agentmux-config.sh ] && echo "IN_REPO" || echo "NOT_IN_REPO"
```

**If in repo:** set `REPO_DIR` to the current working directory.

**If not in repo:** clone from GitHub into a temp directory:

```bash
CLONE_DIR=$(mktemp -d) && git clone --depth 1 https://github.com/lockyc/agentmux "$CLONE_DIR/agentmux" 2>&1 && echo "$CLONE_DIR/agentmux"
```

Set `REPO_DIR` to the cloned path. If the clone fails, report the error and stop.

### 2. Check dependencies

```bash
which toml2json >/dev/null 2>&1 && echo "toml2json: ok" || echo "toml2json: MISSING"
which jq        >/dev/null 2>&1 && echo "jq: ok"        || echo "jq: MISSING"
```

If either is missing, offer to install via Homebrew:

```bash
brew install go-toml   # provides toml2json
brew install jq
```

If Homebrew is unavailable and deps are missing, warn the user and continue — `install.sh` will succeed but agentmux won't function until deps are present.

### 3. Check current install state

Detect what is already wired so question defaults are smart:

```bash
[ -d ~/.agentmux ] && echo "installed" || echo "fresh"
grep -qs "agentmux" ~/.zshrc            && echo "zshrc:wired"   || echo "zshrc:missing"
grep -qs "agentmux" ~/.bashrc           && echo "bashrc:wired"  || echo "bashrc:missing"
grep -qs "agentmux" ~/.tmux.conf        && echo "tmux:wired"    || echo "tmux:missing"
grep -qs "agentmux" ~/.claude/settings.json && echo "hooks:wired" || echo "hooks:missing"
```

### 4. Run core install

```bash
bash "$REPO_DIR/install.sh"
```

If this fails, show the full output and stop.

### 5. Ask what additional wiring to apply

Use AskUserQuestion with a **multi-select** question:

**"What should I wire up for you?"**

Options — mark as "Recommended" those not already detected as wired:

- **Shell config** — appends `source ~/.agentmux/shell/agentmux.sh` to `~/.zshrc` (or `~/.bashrc`)
- **tmux config** — appends `source-file ~/.agentmux/tmux/agentmux.conf` to `~/.tmux.conf`
- **Claude Code hooks** — wires tab-state emojis and AI summary status lines into `~/.claude/settings.json`

### 6. Wire shell config (if selected)

Use `~/.zshrc` if it exists; otherwise `~/.bashrc`. Read the file — if `source ~/.agentmux/shell/agentmux.sh` is not already present, append:

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

The six hooks to wire:

```json
"SessionStart":      [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh start" }] }]
"UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh working" }] }]
"PostToolUse":       [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh working" }] }]
"Notification":      [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh notify" }] }]
"PermissionRequest": [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh permission --notify 'Claude is waiting for permission'" }] }]
"Stop":              [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh done --notify 'Claude has finished working'" }] }]
```

**Merge rules — never remove or overwrite hooks belonging to other tools:**

1. Read `~/.claude/settings.json` (treat as `{}` if the file does not exist).
2. For each of the six event names above, check whether any entry in the current array for that event already contains `agentmux` in its `command` string. Skip the event if already wired.
3. Append our entry to each un-wired event array (create the array if the key is absent).
4. Write the merged JSON back with `jq`:

```bash
# Example for one event — repeat pattern for all six
jq '.hooks.SessionStart += [{"hooks":[{"type":"command","command":"~/.agentmux/scripts/claude/status.sh start"}]}]' \
  ~/.claude/settings.json > /tmp/settings-merged.json && mv /tmp/settings-merged.json ~/.claude/settings.json
```

Use a single `jq` pipeline that adds only the missing events in one pass. If `~/.claude/settings.json` does not exist, seed it with `echo '{}' | jq ...` rather than writing raw JSON.

### 9. Self-install this command

So `/agentmux:install` is available globally in future Claude Code sessions:

```bash
mkdir -p ~/.claude/commands/agentmux
```

Read `$REPO_DIR/.claude/commands/agentmux/install.md` and write it verbatim to `~/.claude/commands/agentmux/install.md`.

### 10. Summary

Print a concise summary: what was installed, what was already present, what was skipped. Include applicable reload commands:

```bash
source ~/.zshrc            # if shell config was wired
tmux source ~/.tmux.conf   # if tmux config was wired (or start a new tmux server)
```

Remind the user to:
- Edit `~/.agentmux/agents.toml` to define their agents (created from the example by `install.sh`)
- Run `amux` to launch their first session
- Restart Claude Code if hooks were wired — hooks take effect on the next session start
- The `--notify` flags in `PermissionRequest`/`Stop` trigger macOS desktop alerts via `osascript`; remove them if unwanted
