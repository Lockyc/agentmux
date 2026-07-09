# Deferred work / follow-ups

Non-blocking items intentionally left for later, with enough context to pick up
cold. Not a changelog — remove an entry when it's done or decided against.

## Restore picker: make additional windows launch through an interactive shell

**Status:** deferred by choice — want to use the restore picker first before deciding.

**Where:** `bin/amux` → `_amux_restore_into`.

**What:** restore relaunches each dropped tab's resume command, but the first tab and
the rest go through *different* shell contexts:

- **Window 0** → `send-keys "<resume_cmd>" Enter` into the pane's **interactive** shell
  (same mechanism every normal agentmux launch uses, incl. `launch_agent.sh`).
- **Additional windows** (2nd+ tab restored into one project) → `new-window "<resume_cmd>"`,
  which tmux runs as **`default-shell -c "<resume_cmd>"`** — non-interactive. On a fish
  login-shell box that's `fish -c "claude-work --resume …"`, which does **not** source
  `config.fish`.

**Why it's fine today (verified):** the resume programs (`claude-work`/`claude-personal`,
the `[[agents]] resume` values) are autoloaded fish function files in
`~/.config/fish/functions/`, so `fish -c 'claude-work'` resolves them without `config.fish`.
Restoring multiple same-project tabs works.

**The latent risk:** a resume program defined **inline in `config.fish`**, or one relying on
PATH/env set there, would launch fine in window 0 and **fail silently in window 2+** (dead/blank
pane) — the kind of divergence that later reads as "flaky."

**Fix (Option A) when we act on it:** make additional windows consistent with window 0 —
create them with an explicit interactive shell as the pane start-command (keeps
`launch_agent.sh`'s `pane_start_command`-non-empty guard skipping the auto-launch), then
`send-keys` the resume command into that interactive shell. ~5 lines, removes the fragility.

**Trigger to revisit:** a restored 2nd-tab pane comes up dead/blank, or before changing the
`[[agents]] resume` convention to anything not autoloaded.
