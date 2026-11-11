---
type: guide
description: Extending agentmux — the per-agent adapter contract behind tab states and AI summaries, and adding support for another shell.
links:
  - rel: part-of
    to: README.md
  - rel: see-also
    to: docs/ai-summary.md
---

# Extending agentmux

## Adding an agent integration

`amux` and friends launch any CLI from `amux.toml`. The richer integration — tab-state emojis and the AI summary status lines — runs through a per-agent **adapter** that lives at `scripts/<agent>/status.sh`. The shipped Claude Code adapter (`scripts/claude/`) is the reference implementation.

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

The shared core reads only those env vars, never stdin — parse the hook payload in the adapter.

Two optional overrides let an adapter swap in custom helpers; defaults work for everyone:

| Env var | Default | Purpose |
|---|---|---|
| `AGENTMUX_TAB_LABEL_BIN` | `tab_label.sh` beside `tmux-status.sh` | Resolves the tab-label suffix from `@window-agent`. Override to render labels differently. |
| `AGENTMUX_SUMMARISE_BIN` | `summarise.sh` beside `tmux-status.sh` | LLM-summary entry point. Override to point at a different summariser. |

**Contracts for the context extractor (`ctx.sh`, `AGENTMUX_CTX_BIN`) and the digest builder (`digest.sh`, `AGENTMUX_DIGEST_BIN`)** (both read the transcript path as `$1`):

- `ctx.sh <transcript> <max_msgs> [percap] [head|tail|todos]` — prints prose-only turns joined by ` / `. Filters out tool noise and pasted dumps. `head`/`tail` select the earliest/most-recent turns; `todos` emits the latest task-list snapshot (the session's goal/plan). An adapter must support all three modes.
- `digest.sh <transcript> [start_line] [char_budget]` — prints a chronological digest (prose + mutating tool one-liners) for the done/now/next summariser. Drops oldest prose first when over budget; keeps tool lines.

Both must print nothing and exit 0 on any error.

To add e.g. a Gemini CLI adapter: create the adapter's `{status,ctx,digest}.sh` following the Claude versions and wire your agent's hook system to call its `status.sh <state>` (by absolute path) with `state` ∈ `start|working|notify|permission|done`. `install.sh` doesn't wire adapters; your own adapter and its hook wiring are manual and live outside the clone (see below).

**Keep custom adapters outside the shipped tree.** `~/.agentmux/` is a git clone and `amux --update` runs `git pull --ff-only`. Because adapters are referenced by absolute path — the hook command plus the `AGENTMUX_CTX_BIN`/`AGENTMUX_DIGEST_BIN` (and other `AGENTMUX_*_BIN`) overrides — they can live anywhere on your filesystem. Put your own under e.g. `~/.agentmux-local/<agent>/` and point your hook command and env-var overrides at those paths. Avoid authoring an adapter under `~/.agentmux/scripts/<name>/` using a name agentmux might later ship: if a future release adds a tracked `scripts/<name>/`, `amux --update` will refuse to proceed rather than overwrite your file, blocking updates until you relocate it.

## Adding another shell

To support a shell that isn't listed in the README's Shell support table (e.g. nushell, elvish, xonsh):

1. Create `shell/agentmux.<shell>` — a thin wrapper, in that shell's own syntax, that:
   - resolves the launcher path (default `~/.agentmux/bin/amux`, overridable via the `AGENTMUX_BIN` env var) and defines an `amux` command forwarding all arguments to it;
   - optionally registers completion from the four `--complete*` sources the README lists.

   `shell/agentmux.sh` (bash/zsh) and `shell/agentmux.fish` (fish) are the reference implementations — both are only a few lines.
2. Add its source line to `install.sh`'s printed instructions (the file itself ships with the clone).
3. Source `~/.agentmux/shell/agentmux.<shell>` from your shell's startup config.

No other agentmux code needs to change — `bin/amux` and every `scripts/` helper are shell-agnostic subprocesses.
