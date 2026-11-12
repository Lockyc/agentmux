---
type: reference
description: Every key amux.toml reads, the always-on note row, and session colours.
links:
  - rel: part-of
    to: README.md
  - rel: see-also
    to: docs/frame.md
---

# Configuration reference

Every key `~/.agentmux/amux.toml` reads, grouped per level (`AGENTMUX_CONFIG` points agentmux at a different file). `config/amux.toml.example` is the annotated tour; these tables are the complete list. Env overrides are named where one exists.

### `[[agents]]` — one block per agent

| Field | Default | Effect |
|---|---|---|
| `name` | required | Agent name — what `amux <agent>` takes, and the name `prefix m` cycles through |
| `cmd` | required | Command the agent tab runs (env assignments allowed, e.g. `CLAUDE_CONFIG_DIR=~/.claude-work claude`) |
| `flag` | — | Single-letter shorthand for `amux -<flag>` |
| `dirs` | — | List of directories; a bare `amux` run inside one (or any subdirectory) auto-selects this agent. `~` → `$HOME`; longest match wins. See [Directory-based agent selection](../README.md#directory-based-agent-selection) |
| `label` | name | Short display name used in tmux tab labels (e.g. `label = "pers"` for a `name = "personal"` agent) |
| `colour` | — | Tab colour as a curated palette name or 256 code (`"green"`, `"colour82"`, `"82"`); the active/inactive shades are auto-derived. Preview with `amux --colours`. Ignored if the raw pair below is set |
| `colour_inactive` / `colour_active` | — | Escape hatch: full raw tmux styles for total control (e.g. `"fg=black,bg=colour56"` / `"fg=black,bg=colour93,bold"`). Set **both** as a pair — they override `colour`, and setting only one is a misconfiguration (agentmux warns) |
| `keep_alive` | false | Appends `; exec $SHELL` so the tab stays open after the agent exits |
| `reattach` | false | Uses `reattach-to-user-namespace` (macOS clipboard fix); requires `keep_alive = true` |
| `resume` | — | Resume program for this agent's windows, used by both the restore picker (`amux --restore`) and `prefix f` (fork). Overrides just the executable of the recorded resume command (e.g. `resume = "claude-work"` → `claude-work --resume <id>`); omit it to use the program recorded when the tab launched. Set this for any agent launched through a wrapper, or its restored and forked tabs start with the bare program |

### `[amux]` — the agent session

Per-directory overrides: `[amux.dirs."<path>"]` blocks, matched like an agent's `dirs` (longest path wins, `~` → `$HOME`).

| Key | Default | What it does |
|---|---|---|
| `prefix` | tmux's `C-b` (or your `user.agent.tmux.conf` prefix) | Prefix for the amux session only. Must differ from the `[frame]` prefix — a colliding value is ignored with a warning. Can be overridden per directory in `[amux.dirs]` |
| `session_colour` | — (auto-assigned) | Pin this directory's status-bar colour by name (`amux --colours` lists them) and reserve it from the auto-assign pool. Only meaningful inside a `[amux.dirs."<path>"]` block. See [Session colours](#session-colours) |

### `[frame]` — the `--frame` side-terminal layout

Per-directory overrides: `[frame.dirs."<path>"]` blocks, resolved per field. See [frame.md](frame.md).

| Key | Default | What it does |
|---|---|---|
| `left` | `30` | Left (scratch terminal) pane width, percent |
| `prefix` | `C-f` (from `tmux/frame.conf`) | The frame's own prefix for focus/resize/quit. Must differ from the `[amux]` prefix |
| `left_vertical_split` | unset (single left pane) | Percent height (`10`–`90`) of a top region of plain shells above the scratch terminal — shown under `--term` too |
| `left_top_panes` | `1` | Plain shells stacked in that top region (`1`–`6`); needs `left_vertical_split` |
| `focus` | `"agent"` | Pane focused at launch: `"agent"` (right) or `"terminal"` (left column) |
| `status_position` | `"bottom"` | Where the frame's status bar sits: `"bottom"` or `"top"` |
| `default` | `false` | Make a bare `amux` open a frame (`amux --no-frame` for a one-off plain launch). Skipped inside an existing tmux unless `allow_nested` |
| `allow_nested` | `false` | Let `--frame` run inside an existing tmux (stacks prefixes; refused otherwise) |

### `[notes]` — the always-on note row

Per-directory overrides: `[notes.dirs."<path>"]`, same shape as `[frame]`'s. See [The always-on note row](#the-always-on-note-row).

| Key | Default | What it does |
|---|---|---|
| `row` | `false` | Show a fourth, always-visible per-tab note row (five status lines instead of four). Apply a change with `amux --reload` or by re-running `amux` in the project |

### `[log]` — the session ledger

| Key | Default | What it does |
|---|---|---|
| `sessions` | `true` | Record every agent window amux opens, so `amux --restore` (and the offer a bare `amux` makes after a crash) can relaunch them; also carries the session id `prefix f` forks from. Env: `AGENTMUX_SESSION_LOG=1/0` |

### `[update]` — version check

| Key | Default | What it does |
|---|---|---|
| `check` | `false` | Once-daily check for a newer agentmux on GitHub; notify-only (run `amux --update` to apply). Env: `AGENTMUX_VERSION_CHECK=1/0` |

### `[llm]` — the AI summary endpoint

Any OpenAI-compatible `/v1/chat/completions` server (LM Studio, Ollama, llama.cpp). Each request needs ≥ 4096 tokens of context — see the example file's notes and [AI summary status lines](../README.md#ai-summary-status-lines).

| Key | Default | What it does |
|---|---|---|
| `url` | `http://localhost:1234/v1/chat/completions` | Endpoint. Env: `AGENTMUX_LLM_URL` |
| `model` | `qwen2.5-14b-instruct` | Model name sent in the request. Env: `AGENTMUX_LLM_MODEL` |
| `timeout` | `45` (`_AMUX_LLM_TIMEOUT_DEFAULT`) | Maximum seconds to wait for each request. Env: `AGENTMUX_LLM_TIMEOUT` |

### `[[hosts]]` — remote machines for `amux @<name>`

See [Remote sessions](../README.md#remote-sessions).

| Key | Default | What it does |
|---|---|---|
| `name` | required | What you type after `@` |
| `ssh` | required | ssh target (`user@host`) or a `~/.ssh/config` Host alias |
| `roots` | — | Remote directories searched for `<project>` (and listed by the picker); `~` expands on the remote |
| `transport` | `"ssh"` | `ssh` (multiplexed, full escape transparency), `et` (Eternal Terminal, auto-reconnect), or `mosh` (warns: drops the OSC 777/OSC 52/passthrough escapes agentmux relies on) |
| `agent` | — | Agent name passed to the remote `amux` |
| `amux` | `"$HOME"/.agentmux/bin/amux` | Remote amux program; inserted unquoted into a remote `sh -c`, so it may carry env or a wrapper |

## The always-on note row

An optional **fourth status row** is a note line that stays on screen all the time, independent of whichever content rows 1-3 are showing. It's opt-in per project:

```toml
[notes]
row = true
```

(`[notes.dirs."<path>"]` scopes it per directory, the same shape as `[frame]`'s — see `config/amux.toml.example`.) Apply a change to it with **`amux --reload`**, which applies it to every live agent session at once, whether you turned the row on or off, without detaching. Running `amux` in the project again also works (a re-attach is enough; you don't have to kill the session), except under a reused `--frame`, which keeps the previous setting until the frame is rebuilt; `--reload` reaches it regardless.

Click the row — or its empty-state hint, `✎ click to add a note` — to write or edit it, the same prompt rows 1-3 use in notes mode. The prompt opens **on the row you clicked**, so it never covers the tab bar while you type.

The row starts with a small button. While the row holds a note it shows `⧉` — click it to **copy the note and clear the row** in one action; the text goes to your system clipboard *and* the tmux paste buffer (`prefix ]` to paste it into a pane), so it survives even where no clipboard tool is available. The button then becomes `↩`, and one more click **restores the note**. The undo is a single level, not a stack: once restored, the button goes back to `⧉`. Every note row (row 4, and rows 1-3 in notes mode) starts with `✎`, even when empty, so note rows are easy to spot. `prefix N` still only swaps rows 1-3 between the AI summary and notes 1-3; row 4 stays put and stays clickable regardless of that mode.


## Session colours

Each session gets a status-bar colour derived from its name, so the same project usually lands on the same colour with no config. The summary rows use a matching shade of the same hue, and colours update automatically on attach. The colour is frozen for a session's lifetime — it never moves while the session lives, regardless of what else starts or stops.

Two projects can land on the same colour, and then share it on every run. (Several named sessions of one project always get distinct colours.) To give a project a distinct, fixed colour, **pin it**:

```toml
[amux.dirs."~/code/myproject"]
session_colour = "blue"
```

A pinned colour is frozen for that directory and removed from the auto-assign pool entirely — no other project is ever assigned it, even when the pinned project isn't running. Run `amux --colours` for the bar colour names (this is the **session bar** palette, distinct from an agent's tab `colour`).
