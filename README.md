# agentmux

Configurable tmux agent launcher. Define AI agents (or any CLI) in TOML; sessions auto-launch the correct agent, tabs are colour-coded per agent, and `prefix-m` cycles through the list.

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

## AI summary status lines

The 3-row status bar (subject / done / now / next) is driven by a generic protocol: any agent writes its status to `/tmp/agentmux-status-<pane_key>.txt` (where `pane_key=$(echo $TMUX_PANE | tr -d '%')`), and `summary_rows.sh` renders it. `summarise.sh` (LM Studio backend, `localhost:1234`) generates the done/now/next text from any digest input.

**Claude Code integration:** Claude Code hooks in `~/.claude/hooks/` handle the Claude-specific pipeline (`claude_ctx.sh` + `claude_digest.sh` → `summarise.sh` → status file). Non-Claude agents show blank rows until they implement the write protocol.
