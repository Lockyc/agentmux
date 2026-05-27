# agentmux

Configurable tmux agent launcher. Shell scripts only — no Python, Node, or other runtime dependencies.

## Stack

Shell scripts only — split between bash and POSIX sh by what each script needs:

- **bash** (`#!/usr/bin/env bash`) — anything that uses `source`, `local`, `${BASH_SOURCE[0]}`, or arrays. That's `install.sh`, `shell/agentmux.sh`, and every config/style consumer (`agentmux-config.sh`, `agent_window_style.sh`, `tab_label.sh`, `cycle_mode.sh`, `launch_agent.sh`, `relaunch.sh`).
- **POSIX sh** (`#!/bin/sh`) — standalone tmux-hook adapters and pure-compute utilities with no source-time dependencies: `summarise.sh`, `summary_rows.sh`, `llm-config.sh`, `tmux-status.sh`, `update_colors.sh`, `window_seen.sh`, `claude/{status,ctx,digest}.sh`.

When adding a script, pick the shell by that rule, not by default. `toml2json` + `jq` are the only runtime dependencies. Don't introduce new ones.

## Layout

| Path | Purpose |
|---|---|
| `scripts/` | Shared runtime scripts (`tmux-status.sh`, `summarise.sh`, etc.) |
| `scripts/claude/` | Claude Code adapter scripts (`status.sh`, `ctx.sh`, `digest.sh`) |
| `scripts/<agent>/` | Pattern for future agent adapters (e.g. `scripts/gemini/`) |
| `shell/agentmux.sh` | Shell functions sourced by the user (`amux`, `tm`) |
| `tmux/agentmux.conf` | tmux snippet sourced from `~/.tmux.conf` |
| `config/agents.toml.example` | Example agent config |
| `VERSION` | Semver version string |

## Local dev setup

`~/.agentmux/scripts`, `~/.agentmux/shell`, and `~/.agentmux/tmux` are directory-level symlinks to the repo. Changes to scripts are live immediately — no install step needed during development.

The Claude Code hook path is `~/.agentmux/scripts/claude/status.sh`. Scripts do **not** need to be copied to `~/.claude/hooks/`.

## Versioning

Bump `VERSION` (semver) when making a meaningful change. `amux --version` reads `~/.agentmux/VERSION` (copied there by `install.sh`). Update `~/.agentmux/VERSION` manually during dev if you need `amux --version` to reflect a working bump.

## Selftests

Several scripts have built-in selftests — run before changing them:

```bash
SUMMARISE_SELFTEST=1      scripts/summarise.sh
SUMMARY_ROWS_SELFTEST=1   scripts/summary_rows.sh
CLAUDE_DIGEST_SELFTEST=1  scripts/claude/digest.sh
AGENTMUX_CONFIG_SELFTEST=1 bash scripts/agentmux-config.sh
AGENTMUX_STYLE_SELFTEST=1  bash scripts/agent_window_style.sh
```
