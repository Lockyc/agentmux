# agentmux

Configurable tmux agent launcher. Shell scripts only — no Python, Node, or other runtime dependencies.

## Stack

Shell scripts only — split between bash, POSIX sh, and (for the fish integration) fish, by what each script needs:

- **bash** (`#!/usr/bin/env bash`) — anything that uses `source`, `local`, `${BASH_SOURCE[0]}`, or arrays. That's `install.sh`, `bin/amux`, `shell/agentmux.sh`, and every config/style consumer (`agentmux-config.sh`, `agent_window_style.sh`, `tab_label.sh`, `cycle_mode.sh`, `launch_agent.sh`, `relaunch.sh`).
- **POSIX sh** (`#!/bin/sh`) — standalone tmux-hook adapters and pure-compute utilities with no source-time dependencies: `summarise.sh`, `summary_rows.sh`, `strip_unbacked_done.sh`, `llm-config.sh`, `tmux-status.sh`, `clear_icon.sh`, `update_colors.sh`, `colours.sh`, `frame_reattach.sh`, `version_check.sh`, `session_log.sh`, `claude/{status,ctx,digest}.sh`.
- **fish** (`shell/agentmux.fish`) — the fish-shell integration only. It is a thin wrapper around `bin/amux` plus a `complete` line; it never sources bash libs (fish can't). All real logic stays in `bin/amux`.

When adding a script, pick the shell by that rule, not by default. `toml2json` + `jq` are the only runtime dependencies. Don't introduce new ones.

**Footgun — portable file mtime:** read it as `stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0` — GNU form FIRST, BSD form as fallback. Do not flip to BSD-first even though the project targets macOS: when a GNU-semantics `stat` (Homebrew coreutils/uutils) shadows BSD `stat` in PATH, `stat -f %m` reads `-f` as `--file-system`, exits nonzero *and* leaks a `File: …` block to stdout, so a BSD-first `||` chain concatenates that block with the fallback's mtime into a non-numeric value that breaks later arithmetic. GNU-first sidesteps it (`-c %Y` works under GNU, fails cleanly to stderr under BSD).

**Footgun — OSC 777 notify must wrap once PER nested tmux layer (`tmux-status.sh`).** A tmux passthrough envelope (`\033Ptmux;…\033\\`) only escapes ONE tmux server: the innermost tmux strips it and writes the inner bytes to *its* output. Under `--frame` the agent runs **two** tmux deep (frame socket → agent socket), so a single-wrapped OSC 777 is unwrapped by the agent tmux into a *bare* `\033]777;…` that the frame tmux then drops (tmux doesn't forward arbitrary OSCs upstream) — the host never sees it, notifications silently vanish. This is invisible outside frame mode (one layer → one wrap is correct), so it shipped broken for `[frame] default = true` users. Fix: `_tmux_nest_depth` walks outward (each tmux's client tty is a pane in the next tmux out) to count layers, and the emit loop wraps once per layer (each wrap doubles the existing ESCs; the ESC-free, control-char-stripped payload means only envelope ESCs ever need doubling). Verify a change to this with `tmux -L agentmux-frame pipe-pane` on the agent pane: the bytes crossing into the frame must still carry a `Ptmux;` envelope, not a bare `]777`.

**Footgun — `allow-passthrough on` must be set on EVERY tmux socket the escape transits, including the frame.** Wrapping per layer (above) is only half of it: each layer must also *have passthrough enabled* or it discards the envelope instead of forwarding it. `agentmux.conf` (the agent/default socket) sets it, but `frame.conf` originally did not, so the frame socket sat at tmux's `off` default and silently dropped the (correctly enveloped) notification — both fixes are required together. It's set in two places, mirroring `focus-events`: `frame.conf` (for a freshly-started frame server) **and** `bin/amux` via `tmux -L "$sock" set -g allow-passthrough on` on every `--frame` (because the frame socket is shared and long-lived — a server predating the config never re-reads `frame.conf`, so the live re-assert is what fixes already-running frames). Don't drop either. To check a live server: `tmux -L agentmux-frame show -g allow-passthrough`.

**Footgun — Escape/Ctrl-C dying in a framed agent is `extended-keys off`, not the terminal.** Claude Code (>=2.1.0) enables the kitty keyboard protocol, requesting the terminal encode keys as CSI-u (Escape `ESC[27u`, Ctrl-C `ESC[99;5u`). tmux silently drops that enable request — its CSI parser has no handler for the `>` in `CSI > 1 u` — so at the default `extended-keys off` the agent and terminal desync: Escape and Ctrl-C intermittently stop reaching Claude while plain text, Backspace, Enter, and arrows (unambiguous across both encodings) keep working. It presents as one wedged agent (per-session state), cured by restarting the agent or reattaching — which masks it as a terminal/warden bug when it's this. The tell that it's NOT the host terminal: `/bin/cat -v` at a bare shell in the same pane shows `^[`/`^C` fine (the bytes flow; only Claude's enhanced-mode negotiation is broken). Fix, mirroring `allow-passthrough` exactly: `set -s extended-keys always` + `set -as terminal-features 'xterm*:extkeys,screen*:extkeys'` on **every socket the keys transit** — `agentmux.conf` (agent), `frame.conf` (frame), `term.conf` (scratch) for fresh servers, **and** re-asserted in `bin/amux` on every `--frame` for the shared long-lived frame socket. `always` not `on`: `on` waits for the enable request tmux already dropped. A framed agent is two tmux deep, so both the frame and agent layers must carry it — `xterm*:extkeys` matches the host (ghostty), `screen*:extkeys` the frame tmux the inner agent sees. Check a live server: `tmux -L agentmux-frame show -s extended-keys` (want `always`).

**Footgun — the per-pane status-file path is derived in TWO places that must stay in lockstep, and tmux `#()` inherits NEITHER `$TMUX` NOR `$XDG_RUNTIME_DIR`.** `tmux-status.sh` (writer) and `summary_rows.sh` (reader) resolve their files as `<runtime_dir>/…-<pane_key>.txt`, where `pane_key="$(printf '%s' "$socket" | cksum | cut -d' ' -f1)-<pane number>"`. The socket hash folds in server identity because pane numbers (`%0`, `%1`, …) are unique only *per tmux server*, so two servers collide — **guaranteed** under `amux --frame`, where the agent runs a second tmux deep. If writer and reader derive the path differently, the summary silently never renders. The core subtlety: `summary_rows.sh` is invoked from `agentmux.conf`'s `status-format` via tmux `#()`, and **`#()` commands don't inherit the hook's environment** (only `run-shell` does), so ANYTHING the two must agree on that lives in the writer's env has to be passed as an arg, not re-derived by the reader. Two things do:
- **socket** — writer reads `${TMUX%%,*}`; reader gets it as `#{socket_path}` (arg 4), which equals `${TMUX%%,*}` for the same server.
- **runtime_dir** — `runtime_dir="${XDG_RUNTIME_DIR:-/tmp/agentmux-$(id -u)}"` (created `mkdir -p -m 0700`; a pre-existing dir the writer doesn't own → private `mktemp` fallback, so a `/tmp` co-tenant can't squat the predictable path). The writer *publishes* the resolved dir as the `@amux_runtime_dir` tmux option (global `set-option`); the reader gets it as `#{@amux_runtime_dir}` (arg 5). The reader must NOT re-derive it from its own env — `#()` can't see the hook's `$XDG_RUNTIME_DIR`, so on a server where the two envs differ (server started without the var, hook with it) writer and reader would land in different dirs and every row blanks. Env re-derivation survives only as a fallback for a manual call or a server predating the option (empty arg 5).

Both args are `#{q:…}`-quoted in `agentmux.conf` (`#{q:socket_path}`, `#{q:@amux_runtime_dir}`) so a socket/runtime path containing a space survives `sh -c` word-splitting as one arg; drop the `q:` and an unusual `TMUX_TMPDIR`/`TMPDIR`/`XDG_RUNTIME_DIR` with a space silently blanks every row. Change any one of {`tmux-status.sh` path derivation + its `@amux_runtime_dir` publish, `summary_rows.sh` path derivation, the `#{q:socket_path}`/`#{q:@amux_runtime_dir}` args in `agentmux.conf`} and you must change them together.

**Footgun — blank summaries on a running server usually mean the tmux config is stale, not a code bug.** `agentmux.conf` sets `status-format[1..3]` (the summary rows) via plain `set -g`, which tmux evaluates **once**, when the config is sourced — a long-lived server keeps whatever format string it loaded at startup. So a config-level change (e.g. adding the `#{socket_path}` arg above) does NOT reach an already-running server on `amux --update`/`git pull`: the file on disk is correct, the writer keys files the new way, but the live reader still runs the old format string and looks under the old key → every row renders blank with no error. The tell that it's this and not a broken script: `summary_rows.sh` with the real socket arg prints the row (`sh scripts/summary_rows.sh <pane_id> 1 120 <socket_path>`) AND the status file exists with content, yet the bar is blank — compare `tmux show -g status-format[1]` (live) against `agentmux.conf` (disk); a diff there is the bug. Fix: `tmux source-file ~/.agentmux/tmux/agentmux.conf` re-asserts the globals across every session on that server at once (the `-g`/`-ga` and `bind-key`/`set-hook -g` lines are all idempotent, so re-sourcing a live server is safe). Only the default socket renders these rows — the frame socket doesn't source `~/.tmux.conf`.

**Footgun — the CWD-derived `--probe`/`--kill` are dir-guarded; don't collapse them back to a bare name check (`bin/amux`).** A session is named after `$PWD`'s basename, so two projects sharing a basename (`~/work/api`, `~/personal/api`) map to the same session name. warden drives `--probe`/`--kill` with **no explicit name** (cwd = the tab's dir), so a naïve `has-session <basename>` would light warden's dot from — and `--kill` would tear down — whichever same-basename project happened to own the session: the wrong project. So each agent/frame session records its launch dir in an `@amux_dir` session option (set beside `@autoagent` on the agent, beside `@amux_project` on the frame, on **every** (re)launch), and `_amux_agent_session_is_mine`/`_amux_frame_session_is_mine` gate the no-arg probe/kill on `@amux_dir == $PWD`. Two invariants: (1) an **explicit** `amux --probe/--kill <name>` skips the guard (targets by name, unchanged) — only the arg-less CWD path guards; (2) a session with **no** `@amux_dir` (created before this feature, not yet relaunched) counts as ours, so nothing regresses for already-running sessions. `@amux_dir` is only ever compared as an opaque string, never re-expanded as a `-t` target, so it's exempt from the session-name whitelist. The term session carries no `@amux_dir` — it's 1:1 with the frame, so its kill follows frame ownership (`own_frame`). This does **not** let two same-basename projects run agents at once (the second still attaches to the first's session) — it only stops the cross-fire; giving them distinct names is a deliberately-unshipped bigger change.

## Layout

| Path | Purpose |
|---|---|
| `bin/amux` | The `amux` launcher — standalone bash, single source of truth for amux logic |
| `scripts/` | Shared runtime scripts (`tmux-status.sh`, `summarise.sh`, etc.) |
| `scripts/clear_icon.sh` | `prefix v` binding target — one-shot strips the leading state emoji off the current window name (emoji-agnostic; relies on `tmux-status.sh`'s `"<emoji> <label>"` invariant). Hooks re-badge on the next event |
| `scripts/claude/` | Claude Code adapter scripts (`status.sh`, `ctx.sh`, `digest.sh`) |
| `scripts/session_log.sh` | Durable roster of agent windows amux opens (`amux --log`); recovery after a server/reboot kill, with a one-time launch nudge when a dead server left sessions open. The roster groups by project (one `cd` per project dir), tags each window `● live`/`✗ lost`, and builds each resume command from the launching agent's `resume` program (`[[agents]]` `resume` field; falls back to the recorded default) |
| `scripts/<agent>/` | Pattern for future agent adapters (e.g. `scripts/gemini/`) |
| `shell/agentmux.sh` | bash/zsh integration: thin `amux` wrapper + zsh completion |
| `shell/agentmux.fish` | fish-shell integration (thin wrapper + completion) |
| `tmux/agentmux.conf` | tmux snippet sourced from `~/.tmux.conf` |
| `tmux/frame.conf` | `amux --frame` outer wrapper config (own socket; no `~/.tmux.conf`) |
| `tmux/term.conf` | `amux --frame` left scratch terminal config (own socket; persistent) |
| `config/amux.toml.example` | Example agent config |
| `install.sh` | Core installer: clones the repo into `~/.agentmux/` and prints setup instructions |
| `.claude/commands/agentmux/install.md` | Claude-driven `/agentmux:install` flow |
| `docs/ai-summary.md` | AI summary design rationale: invariants, ruled-out approaches, eval method — **start here when revisiting the summary feature** |
| `VERSION` | Semver version string |

## Install

`~/.agentmux/` is a **git clone** of this repo. Two installers, kept in sync:

- **`install.sh`** — clones into `~/.agentmux/` if absent, `git pull --ff-only`s an
  existing clone, leaves a dev/symlink install untouched, and *refuses* a pre-clone
  copy-install (pointing at `/agentmux:install` to migrate). Seeds `amux.toml` from
  the example and prints the shell/tmux/hook wiring. Runnable locally or via
  `curl -fsSL …/install.sh | bash`. Needs `git` (install/update only).
- **`/agentmux:install`** (`.claude/commands/agentmux/install.md`) — interactive. Runs
  `install.sh`, migrates an old copy-install (backup → clone → restore `amux.toml`),
  and wires shell config, `~/.tmux.conf`, the Claude Code hooks, and `[llm]`/`[update]`.

**Invariant:** whenever you change what gets installed or wired, update **both**
`install.sh` and `install.md` — they drift silently otherwise.

Updating an installed clone: `amux --update` (= `git -C ~/.agentmux pull --ff-only`).

## Local dev setup

`~/.agentmux/scripts`, `~/.agentmux/shell`, `~/.agentmux/tmux`, and `~/.agentmux/bin` are directory-level symlinks to the repo, and `~/.agentmux/VERSION` is a file-level symlink to it. Changes to scripts are live immediately — no install step needed during development. (`amux.toml` stays a real file — it's your config, not repo content.)

The Claude Code hook path is `~/.agentmux/scripts/claude/status.sh`. Scripts do **not** need to be copied to `~/.claude/hooks/`.

Session-log state lives at `${XDG_STATE_HOME:-~/.local/state}/agentmux/sessions.jsonl` — **not** inside the `~/.agentmux` clone (that's repo content; the ledger is runtime state).

## Branches

`dev` is the working branch — do day-to-day work here, and default to it. `main` is the release branch: merge `dev` into `main` to cut a release. Don't commit directly to `main`. Cutting a release means publishing it: after merging to `main`, push `main` to `origin` (this is the one push that isn't "backup only" — it's how a release ships, so do it as part of the release rather than waiting to be asked).

**Every release to `main` gets a matching GitHub release.** After pushing `main`, tag the release commit `v<VERSION>` and publish it with `gh release create v<VERSION> --target main --title v<VERSION> --notes "<changelog>"` — the tag name is `v` + the `VERSION` file's value, and the notes summarise what shipped since the previous release (features / fixes / docs). This is part of cutting the release, not a follow-up; do it without being asked. If `VERSION` wasn't bumped since the last release, bump it first — a release tag must be unique.

## Versioning

Bump `VERSION` (semver) when making a meaningful change. For clone installs,
`~/.agentmux/VERSION` is the tracked file at the checked-out commit, so it's always
correct after `amux --update`. On a **dev/symlink** box `~/.agentmux/VERSION`
symlinks the repo's working-tree file, so `amux --version` reflects a working bump
the moment you edit `VERSION` — no manual copy needed.

The opt-in daily check (`scripts/version_check.sh`) compares the GitHub `VERSION` to
the local one and, when newer, prints a notice suggesting `amux --update`. It is off
by default (`[update] check`, or `AGENTMUX_VERSION_CHECK`).

## Selftests

`bash test.sh` (repo root) is the aggregate "run everything" entry point: it runs
shellcheck, the `fish -n` syntax check, and every selftest below, prints a
per-check pass/fail line and a summary, and exits non-zero if anything fails.
It's runnable from any cwd and is what CI runs (`.github/workflows/ci.yml`, on
push to `dev`/`main` and every PR — the runner installs `tmux` so the
tmux-gated selftests actually run rather than self-skip).

Several scripts also have built-in selftests — run the relevant one directly for
a targeted check while changing a script:

```bash
SUMMARISE_SELFTEST=1         scripts/summarise.sh
STRIP_UNBACKED_DONE_SELFTEST=1 scripts/strip_unbacked_done.sh
SUMMARY_ROWS_SELFTEST=1      scripts/summary_rows.sh
CLAUDE_CTX_SELFTEST=1        scripts/claude/ctx.sh
CLAUDE_DIGEST_SELFTEST=1     scripts/claude/digest.sh
AGENTMUX_CONFIG_SELFTEST=1   bash scripts/agentmux-config.sh
AGENTMUX_STYLE_SELFTEST=1    bash scripts/agent_window_style.sh
SESSION_LOG_SELFTEST=1       sh scripts/session_log.sh
AMUX_SELFTEST=1              bash bin/amux
CLEAR_ICON_SELFTEST=1        sh scripts/clear_icon.sh
VERSION_CHECK_SELFTEST=1     sh scripts/version_check.sh
COLOURS_SELFTEST=1           sh scripts/colours.sh
UPDATE_COLORS_SELFTEST=1     sh scripts/update_colors.sh
FRAME_REATTACH_SELFTEST=1    sh scripts/frame_reattach.sh
```

`summarise.sh` also has an optional live-LM smoke test that hits the configured endpoint and asserts the prompt rules survive (third-party scope, anti-invention). Manual only — skips silently if the LM is unreachable:

```bash
SUMMARISE_SMOKE=1 scripts/summarise.sh
```

## Linting

`shellcheck` is the linter (install with `brew install shellcheck`). It's lint-only, not a runtime dep, so it doesn't conflict with the toml2json + jq rule — but it's expected to be run before landing shell changes, not treated as optional:

```bash
shellcheck scripts/*.sh scripts/claude/*.sh shell/agentmux.sh bin/amux install.sh
fish -n shell/agentmux.fish   # fish can't be shellcheck'd; this is its syntax check
```

Known-benign findings (do **not** chase these to zero — they're inherent to the patterns, not regressions):

- **SC1091** "Not following: …" — dynamic `source "$SCRIPT_DIR/…"` paths shellcheck can't resolve statically.
- **SC2154** `_llm_url`/`_llm_model`/`_llm_timeout` "referenced but not assigned" — set by `_amux_load_llm` inside `llm-config.sh`; shellcheck doesn't trace function-set globals across a sourced file.

Real findings (anything else, especially error-level) must be fixed or, for a genuine false positive, suppressed with a commented `# shellcheck disable=<code>` on that line (see the zsh `(@f)` line in `shell/agentmux.sh`). A clean run filters to actionable severity:

```bash
shellcheck --severity=warning scripts/*.sh scripts/claude/*.sh shell/agentmux.sh bin/amux install.sh
```
