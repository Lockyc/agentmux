# agentmux

Configurable tmux agent launcher. Define AI agents (or any CLI) in TOML; sessions auto-launch the correct agent, tabs are colour-coded per agent, and `prefix-m` cycles through the list.

![agentmux overview](docs/overview.png)

## Install

### Claude Code (interactive — recommended)

Clone the repo, open it in Claude Code, and run:

```
/agentmux:install
```

The command checks dependencies, runs the installer, and interactively wires your shell config, `~/.tmux.conf`, and Claude Code hooks. It then self-installs to `~/.claude/commands/` so `/agentmux:install` is available globally for future updates from any directory.

### Manual

```bash
curl -fsSL https://raw.githubusercontent.com/lockyc/agentmux/main/install.sh | bash
```

This clones agentmux into `~/.agentmux/` (a git clone — update later with
`amux --update`). You can also clone the repo and run `bash install.sh` directly.

Then complete the setup:

**1. Install dependencies** (if not already present):
```bash
which toml2json || brew install go-toml
which jq        || brew install jq
```

**2. Add to your shell config:**

bash/zsh (`~/.zshrc` or `~/.bashrc`):
```bash
source ~/.agentmux/shell/agentmux.sh
```

fish (`~/.config/fish/config.fish`):
```fish
source ~/.agentmux/shell/agentmux.fish
```

**3. Add to your `~/.tmux.conf`:**
```
source-file ~/.agentmux/tmux/agentmux.conf
```

**4. Edit `~/.agentmux/agents.toml`** to define your agents (created from the example by the installer).

**5. Reload:**
```bash
source ~/.zshrc                  # or restart your shell
tmux source ~/.tmux.conf         # or start a new tmux server
```

**6. Launch your first session:**
```bash
amux
```

## Prerequisites

- tmux
- `toml2json`: `brew install go-toml`
- `jq`: `brew install jq`
- A local OpenAI-compatible LLM endpoint (optional — for AI summary status lines; e.g. LM Studio, Ollama)
- `reattach-to-user-namespace` (optional, macOS — only if using `reattach = true` in agents.toml)
- `osascript` (optional, macOS — only for `--notify` desktop alerts in the Claude Code hooks)

## Usage

| Command | Effect |
|---|---|
| `amux` | New/attach session; agent auto-selected from the current directory (see below), else the first agent in the list |
| `amux -<flag>` | New/attach session, agent matching flag (e.g. `-w` for `flag = "w"`) |
| `amux <name>` | New/attach session, agent by name |
| `amux <name> <session>` | New/attach named session with specified agent |
| `prefix-c` | New tab, auto-launches current `@agent-mode` agent |
| `prefix-m` | Cycle `@agent-mode` through defined agents (agentmux sessions only) |
| `prefix-x` | In agentmux sessions: respawn + relaunch agent (last pane); otherwise kill-pane |
| `amux --update` | Update to the latest agentmux (`git pull --ff-only` of `~/.agentmux`) |
| `amux --frame [agent] [session]` | Side-terminal layout: bare shell (left) + amux (right) as a nested tmux |
| `amux --frames` | List active `--frame` wrappers (they live on a separate tmux socket) |
| `amux --frame-kill [session]` | Tear down a frame (wrapper + its left terminal); the agent keeps running |

Set `[update] check = true` in `~/.agentmux/agents.toml` to enable a once-daily
check that notifies (notify-only) when a newer agentmux is available on GitHub.

Sessions are named after `basename $PWD` (dots → underscores) by default — run `amux` in your project directory and it picks up the name automatically. Pass an explicit name with `amux <agent> <name>` to override. agentmux sessions get a coloured status bar, AI summary rows, and tab-state emojis; plain tmux sessions are left unstyled.

### Directory-based agent selection

Give an agent a `dirs` list and a bare `amux` (no flag, no agent name) auto-selects it based on the current directory — no flag or `prefix-m` toggle needed:

```toml
[[agents]]
name = "work"
cmd  = "CLAUDE_CONFIG_DIR=~/.claude-work claude"
dirs = ["~/work", "~/clients"]
```

A pattern matches when `$PWD` is that directory or any subdirectory of it (`~/work` covers `~/work/acme/api`). `~` expands to `$HOME`. When more than one agent matches, the longest (most specific) path wins, so you can nest a specific rule inside a broader one. If nothing matches, `amux` falls back to the first agent in the list. An explicit `-<flag>` or `<agent_name>` argument always overrides directory routing.

Matching uses the logical path — `$PWD` as your shell shows it — and symlinks are **not** resolved. Write patterns the way you actually `cd` into the directory (e.g. via the symlink path, not its target).

### Side-terminal layout (`--frame`)

`amux --frame [agent] [session]` puts a persistent scratch terminal in the left
pane beside amux in the right. It's a nested tmux on its own socket
(`agentmux-frame`, session `<session>-frame`), so amux runs completely unchanged
on the right. There are **three status bars**: a thin full-width outer bar (the
frame, showing the project + clock), and a per-pane bar under each side — the left
terminal's own tab bar and amux's. (Requires tmux ≥ 3.1 for the `-l %` split.)

- The **left pane is its own dedicated tmux** on a separate `agentmux-term` socket
  (config `tmux/term.conf`): its own tab bar, and it **never dies** — exit the
  shell and it respawns. It's a bare tmux (not your `~/.tmux.conf`), kept isolated
  on purpose.
- **Prefixes:** the frame uses `C-f` ("f" for frame — `C-f h`/`l` focus left/right,
  `C-f j`/`k` move within the split left column, `C-f H`/`L` resize, `C-f Q` quit,
  `C-f d` detach), overridable via `[frame] prefix`. Both
  inner tmuxes use `C-b`, which the frame passes through to whichever pane is
  focused: left → the terminal's tabs, right → amux.
- Set the left-pane width with `[frame] left = <percent>` (default `30`).
  Optionally split the left column top/bottom with `[frame] left_vertical_split =
  <percent>` (the top sub-pane's height, `10`–`90`; unset = single left pane). The
  bottom sub-pane is a plain shell — reach it with the mouse. Frame
  config applies when the frame is **created** — a persistent frame keeps its
  layout, so after changing it, tear the frame down (`C-f Q` or
  `amux --frame-kill <session>`) and relaunch. Killing only the agent session
  leaves the wrapper, which reattaches at the old size.
- Run it from a plain terminal, not from inside tmux. Reattach with the same
  `amux --frame <session>` (a closed pane is rebuilt).
- **Three sessions across three sockets.** `<session>` — your agent, on the
  **default** socket (what plain `tmux ls` shows). `<session>-frame` — the wrapper,
  on `agentmux-frame`. `<session>-term` — the left terminal, on `agentmux-term`.
  The frame is the *outer* layer in the nesting sense, but each lives on its own
  socket so their stripped configs never bleed into your normal tmux — which is
  also why a base-terminal `tmux ls` (default socket) only shows the agent.
- **Managing it from the base terminal:**
  - Leave the frame from inside: `C-f d` (detach, all kept) or `C-f Q` (quit the
    wrapper; the agent survives, reattach later).
  - `amux --frames` — list active frames (no need to remember the socket).
  - `amux --frame-kill [session]` — tear down a frame: both the wrapper and its
    left terminal (default: current dir's). The agent session keeps running.
  - `tmux kill-session -t <session>` — kill the **agent** like any amux session;
    the frame's right pane then just closes (it won't respawn).

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
| `dirs` | — | List of directories; a bare `amux` run inside one (or any subdirectory) auto-selects this agent. `~` → `$HOME`; longest match wins. See [Directory-based agent selection](#directory-based-agent-selection) |
| `label` | name | Short display name used in tmux tab labels (e.g. `label = "pers"` for a `name = "personal"` agent) |
| `keep_alive` | false | Appends `; exec $SHELL` so the tab stays open after the agent exits |
| `reattach` | false | Uses `reattach-to-user-namespace` (macOS clipboard fix); requires `keep_alive = true` |

## Adding an agent integration

`amux` and friends launch any CLI from `agents.toml`. The richer integration — tab-state emojis and the AI summary status lines — runs through a per-agent **adapter** that lives at `scripts/<agent>/status.sh`. The shipped Claude Code adapter (`scripts/claude/`) is the reference implementation.

An adapter is a thin shim that:

1. Exports three env vars and execs the shared core (`scripts/tmux-status.sh`):

   | Env var | Purpose |
   |---|---|
   | `AGENTMUX_AGENT_NAME` | Label used in tab and temp-file names (e.g. `claude`, `gemini`) |
   | `AGENTMUX_CTX_BIN` | Path to a transcript context extractor (see below) |
   | `AGENTMUX_DIGEST_BIN` | Path to a transcript digest builder (see below) |

2. Parses whatever hook payload its agent sends and re-exports:

   | Env var | Purpose |
   |---|---|
   | `AGENTMUX_HOOK_PROMPT` | Latest user prompt (working state only) |
   | `AGENTMUX_HOOK_TRANSCRIPT` | Filesystem path to the agent's session transcript (working state only) |

The shared core is hook-schema-agnostic — it consumes only those env vars, never stdin. Hook-payload parsing belongs in the adapter because every agent has a different schema.

Two optional overrides let an adapter swap in custom helpers; defaults work for everyone:

| Env var | Default | Purpose |
|---|---|---|
| `AGENTMUX_TAB_LABEL_BIN` | `~/.agentmux/scripts/tab_label.sh` | Resolves the tab-label suffix from `@window-agent`. Override to render labels differently. |
| `AGENTMUX_SUMMARISE_BIN` | `~/.agentmux/scripts/summarise.sh` | LLM-summary entry point. Override to point at a different summariser. |

**Contracts for `ctx.sh` and `digest.sh`** (both read the transcript path as `$1`):

- `ctx.sh <transcript> <max_msgs> [percap] [head|tail]` — prints prose-only turns joined by ` / `; used to derive the stable subject and to anchor recent activity. Filters out tool noise and pasted dumps.
- `digest.sh <transcript> [start_line] [char_budget]` — prints a chronological digest (prose + mutating tool one-liners) for the done/now/next summariser. Drops oldest prose first when over budget; keeps tool lines.

Both must print nothing and exit 0 on any error — the shared core treats them as cosmetic.

To add e.g. a Gemini CLI adapter: create `scripts/gemini/{status,ctx,digest}.sh` following the Claude versions, wire your agent's hook system to call `~/.agentmux/scripts/gemini/status.sh <state>` with `state` ∈ `start|working|notify|permission|done`, and `install.sh` will pick the directory up automatically.

**Keep custom adapters outside the shipped tree.** `~/.agentmux/` is a git clone and `amux --update` runs `git pull --ff-only`. Because adapters are referenced by absolute path — the hook command plus the `AGENTMUX_CTX_BIN`/`AGENTMUX_DIGEST_BIN` (and other `AGENTMUX_*_BIN`) overrides — they can live anywhere on your filesystem. Put your own under e.g. `~/.agentmux-local/<agent>/` and point your hook command and env-var overrides at those paths. Avoid authoring an adapter under `~/.agentmux/scripts/<name>/` using a name agentmux might later ship: if a future release adds a tracked `scripts/<name>/`, `amux --update` will refuse to proceed rather than overwrite your file, blocking updates until you relocate it.

## Shell support

`amux` works in **bash**, **zsh**, and **fish**. All of the launcher logic lives in a single standalone bash executable — `bin/amux`, the one source of truth — and each interactive shell just sources a thin wrapper that defines the `amux` command and wires tab-completion. The launcher runs as a subprocess, so **bash must be installed**, but it does not have to be your interactive shell.

| Shell | `amux` command | Tab-completion | Integration file | Source from |
|---|---|---|---|---|
| bash | ✓ | — | `shell/agentmux.sh` | `~/.bashrc` |
| zsh | ✓ | ✓ | `shell/agentmux.sh` | `~/.zshrc` |
| fish | ✓ | ✓ | `shell/agentmux.fish` | `~/.config/fish/config.fish` |

Where completion is wired, it's backed by `amux --complete` — which prints the agent names and `-<flag>` shortcuts, one per line — and offered for the first argument only. (bash gets the command without completion; nothing stops you adding a `complete` script for it.)

### Adding another shell

To support a shell that isn't listed (e.g. nushell, elvish, xonsh):

1. Create `shell/agentmux.<shell>` — a thin wrapper, in that shell's own syntax, that:
   - resolves the launcher path (default `~/.agentmux/bin/amux`, overridable via the `AGENTMUX_BIN` env var) and defines an `amux` command forwarding all arguments to it;
   - optionally registers a first-argument completion populated from `<launcher> --complete`.

   `shell/agentmux.sh` (bash/zsh) and `shell/agentmux.fish` (fish) are the reference implementations — both are only a few lines.
2. Update **both** installers so the file ships and gets wired: `install.sh` (it's carried by the clone; add its source line to the printed instructions) and `.claude/commands/agentmux/install.md` (detection + wiring). They must stay in sync.
3. Source `~/.agentmux/shell/agentmux.<shell>` from your shell's startup config.

No other agentmux code needs to change — `bin/amux` and every `scripts/` helper are shell-agnostic subprocesses.

## AI tab states (Claude Code)

`claude/status.sh` updates the tmux tab label with an emoji reflecting Claude's current state:

| Emoji | State |
|---|---|
| 🤖 | Session started |
| ⚡ | Working |
| 🔐 | Awaiting permission |
| 📣 | Waiting for input |
| ✅ | Done (unseen) |
| 👀 | Done (window active/seen) |

**Setup:** the clone includes `scripts/claude/`; wire the hooks in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "SessionStart":      [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh start" }] }],
    "UserPromptSubmit":  [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh working" }] }],
    "PostToolUse":       [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh working" }] }],
    "Notification":      [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh notify" }] }],
    "PermissionRequest": [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh permission --notify 'Claude is waiting for permission'" }] }],
    "Stop":              [{ "hooks": [{ "type": "command", "command": "~/.agentmux/scripts/claude/status.sh done --notify 'Claude has finished working'" }] }]
  }
}
```

The `--notify` flag triggers a macOS notification via `osascript`. Remove it if you don't want desktop alerts.

## AI summary status lines

The 3-row status bar shows a rolling `done / now / next` summary of the active session. `agentmux.conf` already wires `status-format[1-3]` to `summary_rows.sh`; you just need a local LLM endpoint and the Claude Code hooks above.

**Requirements:**
- A local OpenAI-compatible LLM endpoint with a small non-reasoning instruct model loaded (e.g. LM Studio at `localhost:1234` with `qwen2.5-14b-instruct`, or Ollama at `localhost:11434`)
- `agentmux.conf` sourced in `~/.tmux.conf`
- Claude Code hooks wired (above) — the `working` hook triggers the summariser

The coloured status bar and 3 extra summary rows only appear in `amux` sessions (`@autoagent=1`). Plain tmux sessions are left unstyled with a single status line.

**Pipeline** (runs detached on every `working` hook):
1. `claude/ctx.sh` — extracts recent prose turns from the Claude Code transcript
2. `claude/digest.sh` — compacts the session into a chronological digest (prose + mutating tool actions)
3. `summarise.sh stand` — sends the digest to a local OpenAI-compatible endpoint; receives `"<subject>. done: …; now: …; next: …"`
4. Result written to `/tmp/agentmux-status-<pane_key>.txt`
5. `summary_rows.sh` (called by tmux `status-format[1-3]`) splits that into three display rows

Override the endpoint or model with environment variables:

```bash
export AGENTMUX_LLM_URL=http://localhost:1234/v1/chat/completions
export AGENTMUX_LLM_MODEL=qwen2.5-14b-instruct
export AGENTMUX_LLM_TIMEOUT=20   # seconds
```

**Non-Claude agents:** any agent can participate by writing to `/tmp/agentmux-status-<pane_key>.txt` directly (where `pane_key=$(echo $TMUX_PANE | tr -d '%')`). The format is a single line: `<subject>. done: <text>; now: <text>; next: <text>` — any of the `done`/`now`/`next` labels may be omitted.

## Session colours

Each session gets a colour derived deterministically from its name — same directory, same colour, on every machine. The summary rows use a matching shade of the same hue. Colours update automatically on attach; no config needed.
