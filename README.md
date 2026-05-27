# agentmux

Configurable tmux agent launcher. Define AI agents (or any CLI) in TOML; sessions auto-launch the correct agent, tabs are colour-coded per agent, and `prefix-m` cycles through the list.

![agentmux overview](docs/overview.png)

## Prerequisites

- tmux
- `toml2json`: `brew install go-toml`
- `jq`: `brew install jq`
- LM Studio on `localhost:1234` (optional — for AI summary status lines)

## Install

```bash
git clone https://github.com/lockyc/agentmux ~/Developer/github.com/lockyc/agentmux
cd ~/Developer/github.com/lockyc/agentmux
bash install.sh
```

Edit `~/.agentmux/agents.toml` to define your agents, then add to your shell config and tmux config as directed by the installer output.

## Usage

| Command | Effect |
|---|---|
| `amux` | New/attach session, default agent (first in list) |
| `amux -<flag>` | New/attach session, agent matching flag (e.g. `-w` for `flag = "w"`) |
| `amux <name>` | New/attach session, agent by name |
| `amux <name> <session>` | New/attach named session with specified agent |
| `tm [name]` | Plain tmux session, no agent |
| `prefix-c` | New tab, auto-launches current `@agent-mode` agent |
| `prefix-m` | Cycle `@agent-mode` through defined agents |
| `prefix-x` | In agentmux sessions: respawn + relaunch agent (last pane); otherwise kill-pane |

## Adding an agent

Add a new `[[agents]]` block to `~/.agentmux/agents.toml`:

```toml
[[agents]]
name = "myagent"
flag = "a"
cmd = "my-ai-cli"
colour_inactive = "fg=black,bg=colour56"
colour_active   = "fg=black,bg=colour93,bold"
```

The new agent appears in the `prefix-m` cycle immediately (no reload needed).

## Optional per-agent fields

| Field | Default | Effect |
|---|---|---|
| `flag` | — | Single-letter shorthand for `amux -<flag>` |
| `label` | name | Short display name used in tmux tab labels (e.g. `label = "pers"` for a `name = "personal"` agent) |
| `keep_alive` | false | Appends `; exec $SHELL` so the tab stays open after the agent exits |
| `reattach` | false | Uses `reattach-to-user-namespace` (macOS clipboard fix); requires `keep_alive = true` |

## AI tab states (Claude Code)

`tmux-status.sh` updates the tmux tab label with an emoji reflecting Claude's current state:

| Emoji | State |
|---|---|
| 🤖 | Session started |
| ⚡ | Working |
| 🔐 | Awaiting permission |
| 📣 | Waiting for input |
| ✅ | Done (unseen) |
| 👀 | Done (window active/seen) |

**Setup:** copy the hook scripts to `~/.claude/hooks/`:

```bash
cp scripts/tmux-status.sh scripts/claude_ctx.sh scripts/claude_digest.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/tmux-status.sh ~/.claude/hooks/claude_ctx.sh ~/.claude/hooks/claude_digest.sh
```

Wire them in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/tmux-status.sh 🤖" }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/tmux-status.sh ⚡" }] }],
    "PostToolUse":       [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/tmux-status.sh ⚡" }] }],
    "Notification":      [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/tmux-status.sh 📣" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/tmux-status.sh 🔐 --notify 'Claude is waiting for permission'" }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "~/.claude/hooks/tmux-status.sh ✅ --notify 'Claude has finished working'" }] }]
  }
}
```

The `--notify` flag triggers a macOS notification via `osascript`. Remove it if you don't want desktop alerts.

## AI summary status lines

The 3-row status bar shows a rolling `done / now / next` summary of the active session. `agentmux.conf` already wires `status-format[1-3]` to `summary_rows.sh`; you just need LM Studio and the Claude Code hooks above.

**Requirements:**
- LM Studio running at `localhost:1234` with a small non-reasoning instruct model loaded (e.g. `qwen2.5-14b-instruct`)
- `agentmux.conf` sourced in `~/.tmux.conf`
- Claude Code hooks wired (above) — the `⚡` hook triggers the summariser

**Pipeline** (runs detached on every `⚡` hook):
1. `claude_ctx.sh` — extracts recent prose turns from the Claude Code transcript
2. `claude_digest.sh` — compacts the session into a chronological digest (prose + mutating tool actions)
3. `summarise.sh stand` — sends the digest to LM Studio; receives `"<subject>. done: …; now: …; next: …"`
4. Result written to `/tmp/agentmux-status-<pane_key>.txt`
5. `summary_rows.sh` (called by tmux `status-format[1-3]`) splits that into three display rows

Override the LM Studio endpoint or model with environment variables:

```bash
export LMSTUDIO_URL=http://localhost:1234/v1/chat/completions
export LMSTUDIO_MODEL=qwen2.5-14b-instruct
export LMSTUDIO_TIMEOUT=20   # seconds
```

**Non-Claude agents:** any agent can participate by writing to `/tmp/agentmux-status-<pane_key>.txt` directly (where `pane_key=$(echo $TMUX_PANE | tr -d '%')`). The format is a single line: `<subject>. done: <text>; now: <text>; next: <text>` — any of the `done`/`now`/`next` labels may be omitted.
