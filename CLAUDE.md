---
type: architecture
---
# agentmux

Configurable tmux agent launcher. Shell scripts only — no Python, Node, or other runtime dependencies.

## Stack

Shell scripts only — split between bash, POSIX sh, and (for the fish integration) fish, by what each script needs:

- **bash** (`#!/usr/bin/env bash`) — anything that uses `source`, `local`, `${BASH_SOURCE[0]}`, or arrays. That's `install.sh`, `bin/amux`, `shell/agentmux.sh`, and every config/style consumer (`agentmux-config.sh`, `agent_window_style.sh`, `tab_label.sh`, `cycle_mode.sh`, `launch_agent.sh`, `relaunch.sh`, `fork_session.sh`).
- **POSIX sh** (`#!/bin/sh`) — standalone tmux-hook adapters and pure-compute utilities with no source-time dependencies: `summarise.sh`, `summary_rows.sh`, `strip_unbacked_done.sh`, `llm-config.sh`, `tmux-status.sh`, `clear_icon.sh`, `update_colors.sh`, `colours.sh`, `frame_reattach.sh`, `version_check.sh`, `session_log.sh`, `claude/{status,ctx,digest,goal}.sh`.
- **fish** (`shell/agentmux.fish`) — the fish-shell integration only. It is a thin wrapper around `bin/amux` plus a `complete` line; it never sources bash libs (fish can't). All real logic stays in `bin/amux`.

When adding a script, pick the shell by that rule, not by default. `toml2json` + `jq` are the only runtime dependencies. Don't introduce new ones.

**Footgun — portable file mtime:** read it as `stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0` — GNU form FIRST, BSD form as fallback. Do not flip to BSD-first even though the project targets macOS: when a GNU-semantics `stat` (Homebrew coreutils/uutils) shadows BSD `stat` in PATH, `stat -f %m` reads `-f` as `--file-system`, exits nonzero *and* leaks a `File: …` block to stdout, so a BSD-first `||` chain concatenates that block with the fallback's mtime into a non-numeric value that breaks later arithmetic. GNU-first sidesteps it (`-c %Y` works under GNU, fails cleanly to stderr under BSD).

**Footgun — OSC 777 notify must wrap once PER nested tmux layer (`tmux-status.sh`).** A tmux passthrough envelope (`\033Ptmux;…\033\\`) only escapes ONE tmux server: the innermost tmux strips it and writes the inner bytes to *its* output. Under `--frame` the agent runs **two** tmux deep (frame socket → agent socket), so a single-wrapped OSC 777 is unwrapped by the agent tmux into a *bare* `\033]777;…` that the frame tmux then drops (tmux doesn't forward arbitrary OSCs upstream) — the host never sees it, notifications silently vanish. This is invisible outside frame mode (one layer → one wrap is correct), so it shipped broken for `[frame] default = true` users. Fix: `_tmux_nest_depth` walks outward (each tmux's client tty is a pane in the next tmux out) to count layers, and the emit loop wraps once per layer (each wrap doubles the existing ESCs; the ESC-free, control-char-stripped payload means only envelope ESCs ever need doubling). Verify a change to this with `tmux -L agentmux-frame-<hash> pipe-pane` on the agent pane (`<hash>` = cksum of the project's `$PWD` — see the sharding note below; an `AGENTMUX_FRAME_SOCKET` override names the socket verbatim instead): the bytes crossing into the frame must still carry a `Ptmux;` envelope, not a bare `]777`.

**Footgun — `allow-passthrough on` must be set on EVERY tmux socket the escape transits, including the frame.** Wrapping per layer (above) is only half of it: each layer must also *have passthrough enabled* or it discards the envelope instead of forwarding it. `agentmux.conf` (the agent/default socket) sets it, but `frame.conf` originally did not, so the frame socket sat at tmux's `off` default and silently dropped the (correctly enveloped) notification — both fixes are required together. It's set in two places, mirroring `focus-events`: `frame.conf` (for a freshly-started frame server) **and** `bin/amux` via `tmux -L "$sock" set -g allow-passthrough on` on every `--frame` (because the frame socket is shared and long-lived — a server predating the config never re-reads `frame.conf`, so the live re-assert is what fixes already-running frames). Don't drop either. To check a live server: `tmux -L agentmux-frame-<hash> show -g allow-passthrough`, where `<hash>` is the cksum of the project's `$PWD`. **The frame/term sockets are sharded per project** — `agentmux-frame-<cksum $PWD>` / `agentmux-term-<cksum $PWD>`, one server per project rather than one shared server for all — so every live-server diagnostic in these footguns must target that project's own socket, not a bare `agentmux-frame`/`agentmux-term` name (no such fixed socket exists in production anymore). An explicit `AGENTMUX_FRAME_SOCKET`/`AGENTMUX_TERM_SOCKET` override still names one socket verbatim — that's the selftest-isolation path, unaffected by sharding.

**Footgun — Escape/Ctrl-C dying in a framed agent is `extended-keys off`, not the terminal.** Claude Code (>=2.1.0) enables the kitty keyboard protocol, requesting the terminal encode keys as CSI-u (Escape `ESC[27u`, Ctrl-C `ESC[99;5u`). tmux silently drops that enable request — its CSI parser has no handler for the `>` in `CSI > 1 u` — so at the default `extended-keys off` the agent and terminal desync: Escape and Ctrl-C intermittently stop reaching Claude while plain text, Backspace, Enter, and arrows (unambiguous across both encodings) keep working. It presents as one wedged agent (per-session state), cured by restarting the agent or reattaching — which masks it as a terminal/warden bug when it's this. The tell that it's NOT the host terminal: `/bin/cat -v` at a bare shell in the same pane shows `^[`/`^C` fine (the bytes flow; only Claude's enhanced-mode negotiation is broken). Fix, mirroring `allow-passthrough` exactly: `set -s extended-keys always` + `set -as terminal-features 'xterm*:extkeys,screen*:extkeys'` on **every socket the keys transit** — `agentmux.conf` (agent), `frame.conf` (frame), `term.conf` (scratch) for fresh servers, **and** re-asserted in `bin/amux` on every `--frame` for that project's long-lived frame socket (sharded per project — see the allow-passthrough footgun above). `always` not `on`: `on` waits for the enable request tmux already dropped. A framed agent is two tmux deep, so both the frame and agent layers must carry it — `xterm*:extkeys` matches the host (ghostty), `screen*:extkeys` the frame tmux the inner agent sees. Check a live server: `tmux -L agentmux-frame-<hash> show -s extended-keys` (want `always`; `<hash>` = cksum of the project's `$PWD`, per the per-project sharding above).

**The tmux `sync` terminal-feature: what it does and does NOT fix.** `terminal-features 'xterm*:sync,tmux*:sync,screen*:sync'` (set on every socket the redraw transits — `agentmux.conf`/`frame.conf`/`term.conf` for fresh servers, re-asserted in `bin/amux` on every `--frame` for that project's long-lived frame — sharded per project, see the allow-passthrough footgun above) makes tmux wrap its **full-screen** redraws to ghostty in a DECSET 2026 (synchronized-output) bracket, so ghostty pauses rendering and doesn't tear a full repaint. tmux does **not** derive this from the terminfo `Sync` capability (xterm-ghostty terminfo ships `Sync`, tmux 3.7 still leaves the feature off until named) — so it is worth setting. The feature is computed **at client attach**, so a live frame picks it up on the next reattach, not instantly (`tmux -L agentmux-frame-<hash> list-clients -F '#{client_termfeatures}'` to check, `<hash>` = cksum of the project's `$PWD`). **BUT this does not fix "the cursor flashes around the screen in an unfocused warden window while Claude thinks" — that turned out to be a warden bug, not a tmux one.** warden was leaving *background* window surfaces focused (libghostty inits a surface focused, starting its 60fps render display link; warden only cleared focus on a window losing key, which never fires for a never-key background window), so those windows rendered at 60fps and sampled the cursor at each intermediate cell tmux relays between redraws. Fixed in warden by seeding a surface's focus from the real `NSApp.isActive && window.isKeyWindow` at spawn (see warden's CLAUDE.md). So enabling `sync` here is a genuine but *separate* improvement — it kills full-redraw *tearing* — and is **not** what fixed the flash; don't attribute that flash to the `sync` tag (or to tmux at all).

**Footgun — the writer keys its per-pane state files by `<pane_key>` = `<cksum of the $TMUX socket>-<pane number>`.** `tmux-status.sh` writes its `agentmux-status/-diag/-<agent>-subject/-substart/-sum…-<pane_key>` files under the per-uid runtime dir (`$XDG_RUNTIME_DIR`, else `/tmp/agentmux-<uid>` at mode 0700; a pre-existing dir it doesn't own → private `mktemp` fallback, so a `/tmp` co-tenant can't squat the predictable path). The socket hash folds in server identity because pane numbers (`%0`, `%1`, …) are unique only *per tmux server*, so two servers collide — **guaranteed** under `amux --frame`, where the agent runs a second tmux deep. This is now a **single-script** concern: the writer both writes and reads these by the same key, so there is no separate reader to keep in lockstep and no `#()`-env problem. (Historically `summary_rows.sh`, invoked from `agentmux.conf` via `#()`, re-derived this key to *read* the status file for display — and since `#()` inherits neither `$TMUX` nor `$XDG_RUNTIME_DIR`, the socket and runtime dir had to be passed to it as `#{q:…}`-quoted args. That polled reader is gone: the status bar now reads pushed `@amux_rowN` pane options, not any file.)

**Footgun — blank/stale summaries on a running server usually mean the tmux config is stale, not a code bug.** `agentmux.conf` sets `status-format[1..3]` via plain `set -g`, which tmux evaluates **once**, when the config is sourced — a long-lived server keeps whatever format string it loaded at startup. So a config-level change (e.g. the switch from `#(summary_rows.sh …)` to `#{@amux_rowN}`) does NOT reach an already-running server on `amux --update`/`git pull`: the file on disk is correct and the writer pushes the new options, but the live `status-format` is still the old one (so it keeps polling, or renders blank). The tell: compare `tmux show -gv status-format[1]` (live) against `agentmux.conf` (disk); a diff there is the bug. Fix: `tmux source-file ~/.agentmux/tmux/agentmux.conf` re-asserts the globals across every session on that server at once (the `-g`/`-ga` and `bind-key`/`set-hook -g` lines are idempotent, so re-sourcing a live server is safe) — this is also the **deploy step** for a status-format change. Only the default socket renders these rows — the frame socket doesn't source `~/.tmux.conf`.

**Footgun — the CWD-derived `--probe`/`--kill` are dir-guarded; don't collapse them back to a bare name check (`bin/amux`).** A session is named after `$PWD`'s basename, so two projects sharing a basename (`~/work/api`, `~/personal/api`) map to the same session name. warden drives `--probe`/`--kill` with **no explicit name** (cwd = the tab's dir), so a naïve `has-session <basename>` would light warden's dot from — and `--kill` would tear down — whichever same-basename project happened to own the session: the wrong project. So each agent/frame session records its launch dir in an `@amux_dir` session option (set beside `@autoagent` on the agent, beside `@amux_project` on the frame, on **every** (re)launch), and `_amux_agent_session_is_mine`/`_amux_frame_session_is_mine` gate the no-arg probe/kill on `@amux_dir == $PWD`. Two invariants: (1) an **explicit** `amux --probe/--kill <name>` skips the guard (targets by name, unchanged) — only the arg-less CWD path guards; (2) a session with **no** `@amux_dir` (created before this feature, not yet relaunched) counts as ours, so nothing regresses for already-running sessions. `@amux_dir` is only ever compared as an opaque string, never re-expanded as a `-t` target, so it's exempt from the session-name whitelist. The term session carries no `@amux_dir` — it's 1:1 with the frame, so its kill follows frame ownership (`own_frame`). This does **not** let two same-basename projects run agents at once (the second still attaches to the first's session) — it only stops the cross-fire; giving them distinct names is a deliberately-unshipped bigger change. The frame/term sockets being sharded per project (`agentmux-frame-<cksum $PWD>` / `agentmux-term-<cksum $PWD>`, see above) now *also* separates same-basename projects' frame/term servers at the socket level — two same-basename projects each get their own frame server, so they can't collide there even before this guard runs. The `@amux_dir` guard remains and is still load-bearing: it's what protects the *agent session* (named by basename, on the shared default socket, not sharded), so this is belt-and-suspenders, not a replacement.

**Footgun — the summary status rows are PUSHED (event-driven); never turn them back into a `#()` poll.** `tmux-status.sh` (the writer, run on each agent hook event) renders the three rows via `summary_rows.sh --stdin` and sets them as `@amux_row1/2/3` **pane options** + `refresh-client`; `agentmux.conf`'s `status-format[1..3]` reference those options statically (`#{@amux_row1}`), so a status redraw just substitutes an option value and **spawns nothing** — `status-interval` no longer gates any process spawn here. This replaced a `#(summary_rows.sh …)` poll that tmux re-ran every `status-interval` per client: each call spawned `awk`/coreutils helpers with **no backpressure**, so at `status-interval 1` across many amux panes a system slowdown (e.g. a post-reboot Spotlight storm) made spawns outrun drain and exhaust the **per-user process table** (`kern.maxprocperuid`, ~10666) — `fork()` then fails for everything (new shells hang, nothing launches, apps can't be killed) while RAM/CPU sit *idle*. It reads like a freeze but is process-table exhaustion — diagnose with `ps -Axo user= | grep -c $(id -un)` climbing past ~400 (confirmed 2026-07-09: 6237 procs / 16475 threads, flooded with `bash`/`gawk`/`ggrep`/`uu-coreutils`). The lesson that outlives the fix: **show live status via pushed options, never a `#()` in the status format.** (`~/.tmux.conf`'s `status-interval` is now irrelevant to spawning here; it only paces passive redraws — a lower value is harmless again.)

**Footgun — `bin/amux` must stay bash-3.2-compatible; no associative arrays or other bash-4-isms.** macOS ships bash 3.2 as `/bin/bash`, and `bin/amux` is `#!/usr/bin/env bash` installed via `curl|bash`, so it must run on the stock shell, not whatever Homebrew bash a dev machine happens to have on `PATH` — no `local -A`/`declare -A` (associative arrays), no other bash-4+ feature. The selftest guards this mechanically: it asserts `grep -cE '^[[:space:]]*(local|declare) -A' bin/amux` is `0`. Verify a change with `AMUX_SELFTEST=1 /bin/bash bin/amux`, which must pass under the real `/bin/bash`, not just under `PATH`'s bash.

## Layout

| Path | Purpose |
|---|---|
| `bin/amux` | The `amux` launcher — standalone bash, single source of truth for amux logic |
| `scripts/` | Shared runtime scripts (`tmux-status.sh`, `summarise.sh`, etc.) |
| `scripts/clear_icon.sh` | `prefix v` binding target — one-shot strips the leading state emoji off the current window name (emoji-agnostic; relies on `tmux-status.sh`'s `"<emoji> <label>"` invariant). Hooks re-badge on the next event |
| `scripts/claude/` | Claude Code adapter scripts (`status.sh`, `ctx.sh`, `digest.sh`, `goal.sh`) |
| `scripts/fork_session.sh` | `prefix f` binding target — forks the current tab's agent session into a new tab, using the `fork_cmd` its adapter recorded in the session log. Passes the fork command as the new window's `pane_start_command`, which is what makes `launch_agent.sh` skip its auto-launch |
| `scripts/session_log.sh` | Durable open/close ledger of agent windows amux opens, for crash recovery. The `dropped [<cwd>\|--global\|--new <cwd>\|--pending <cwd>]` subcommand emits restorable dropped tabs (agent tab, dead server, open-at-death, resume-program-swapped from `[[agents]] resume`); `amux`'s launch picker (and `amux --restore`) consume it. `--new` gates the launch offer once per (dead-server, cwd) via the `notified` marker; `--pending` applies that gate **read-only** — it's what the CWD-derived `amux --probe` uses to exit 3 ("restorable"), and a marking read there would let warden's poll burn the offer. The `forkcmd [target]` subcommand emits `agent<TAB>fork_cmd` for one LIVE window, program-swapped the same way; `scripts/fork_session.sh` consumes it |
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
| `docs/FOLLOWUPS.md` | Deferred, non-blocking work with pick-up-cold context (e.g. the restore picker's window-launch consistency item) |
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

**On a heavily-loaded machine, prefer the individual selftests below for local
checks and let CI run the aggregate `bash test.sh`.** It's bounded — one
shellcheck call plus strictly-sequential selftests, no infinite fan-out — but it
does spike process count, not worth stacking on a machine already near its
per-user process limit. (It once contributed to a process-table lockup, but only
as a spike on top of the old status-bar `#()` poll that was spawning per second;
both that poll and the one true infinite-fork vector — the `summary_rows`
selftest re-entering itself — are gone now: `summary_rows.sh` checks `--stdin`
*before* its selftest block, so a `--stdin` child renders and exits, never
recursing.)

Several scripts also have built-in selftests — run the relevant one directly for
a targeted check while changing a script:

```bash
LLM_CONFIG_SELFTEST=1        sh scripts/llm-config.sh
SUMMARISE_SELFTEST=1         scripts/summarise.sh
STRIP_UNBACKED_DONE_SELFTEST=1 scripts/strip_unbacked_done.sh
SUMMARY_ROWS_SELFTEST=1      scripts/summary_rows.sh
CLAUDE_CTX_SELFTEST=1        scripts/claude/ctx.sh
CLAUDE_GOAL_SELFTEST=1       scripts/claude/goal.sh
CLAUDE_DIGEST_SELFTEST=1     scripts/claude/digest.sh
AGENTMUX_CONFIG_SELFTEST=1   bash scripts/agentmux-config.sh
AGENTMUX_STYLE_SELFTEST=1    bash scripts/agent_window_style.sh
SESSION_LOG_SELFTEST=1       sh scripts/session_log.sh
FORK_SESSION_SELFTEST=1      bash scripts/fork_session.sh
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
