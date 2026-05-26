# agentmux

Configurable tmux agent launcher. Define AI agents (or any CLI) in TOML; sessions auto-launch the correct agent, tabs are colour-coded per agent, and `prefix-m` cycles through the list.

## Prerequisites

- tmux
- `toml2json`: `brew install go-toml`
- `jq`: `brew install jq`
- Two Claude Code accounts (optional — configure your own agents in `agents.toml`)

## Install

```bash
git clone https://github.com/Lockyc/agentmux ~/Developer/github.com/Lockyc/agentmux
cd ~/Developer/github.com/Lockyc/agentmux
bash install.sh
```

Edit `~/.agentmux/agents.toml` to define your agents, then add to your shell config and tmux config as directed by the installer output.

## Usage

| Command | Effect |
|---|---|
| `tmc` | New/attach session, default agent (first in list) |
| `tmc -<flag>` | New/attach session, agent matching flag (e.g. `-w` for `flag = "w"`) |
| `tmc <name>` | New/attach session, agent by name |
| `tmc <name> <session>` | New/attach named session with specified agent |
| `tm [name]` | Plain tmux session, no agent |
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
| `flag` | — | Single-letter shorthand for `tmc -<flag>` |
| `keep_alive` | false | Appends `; exec $SHELL` so the tab stays open after the agent exits |
| `reattach` | false | Uses `reattach-to-user-namespace` (macOS clipboard fix); requires `keep_alive = true` |

## AI summary status lines

The 3-row status bar summary (subject / done / now / next) activates automatically for Claude-based agents via Claude Code hooks. Requires LM Studio running locally on `localhost:1234` with a compatible model loaded. Non-Claude agents show blank status lines.
