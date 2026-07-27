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

## Sockets — the server/sharding model

All amux tmux servers are **sharded per project**: `agentmux-{frame,term,agent}-<cksum $PWD>`,
one server per project per role — never one shared server, never tmux's real `default`
socket. `_amux_{frame,term,agent}_sock` derive the shard from `$PWD`; an explicit
`AGENTMUX_{FRAME,TERM,AGENT}_SOCKET` override names a socket verbatim (the selftest-isolation
path). So a live-server diagnostic targets *that project's own* socket —
`tmux -L agentmux-<role>-<cksum $PWD>` — not a bare role name. A **framed** agent runs two
tmux deep (frame → agent); an un-framed one is a single layer. That nesting is what the
escape/key footguns below turn on. Each socket loads only its own `-f` config
(`agent.conf` → `agentmux.conf` / `frame.conf` / `term.conf`); **none sources `~/.tmux.conf`**
(deliberate — falling through to it runs TPM's synchronous plugin load on every cold
per-project agent server; `agent.conf` re-sets the sensible defaults itself). Instead
each socket `source-file -q`'s its **own PER-ROLE** overlay **last** —
`$AGENTMUX_USER_DIR/user.{agent,frame,term}.tmux.conf` (`AGENTMUX_USER_DIR` is exported by
`bin/amux`, default `~/.agentmux`; user files, not repo content; `config/user.tmux.conf.example`
is the template). The dir is a var, not a literal `~`, on purpose — an explicit
`AGENTMUX_USER_DIR` redirects the whole set so the selftest reads throwaway overlays, the same
isolation idiom as `AGENTMUX_*_SOCKET`; don't "simplify" the conf lines back to `~`, that
silently unhooks the overlay tests. Per-role is load-bearing, **not** three
copies of one file: the frame runs a different prefix (`C-f`) and unbinds the window keys
for its fixed layout, so a *single shared* overlay would apply a user `bind-key` to all
three servers and break the frame — the reason the initial one-file design was wrong.
User settings win over our defaults, absent = silent no-op, and `amux --reload` re-sources
**only `user.agent.tmux.conf`** into live agent servers (frame/term picked up on relaunch),
so the agent overlay wants idempotent lines.

## Footguns

The normal case is boring — a single un-framed `amux` launch is one tmux deep on the
project's own agent shard, and the happy path just works. These are the corners where the
wrong fix *looks* right. (The escape/key/render traps — mtime, OSC-777 wrapping,
passthrough, extended-keys, sync — are fully documented at their call sites; see the
pointer list at the end rather than a second copy here.)

**The presence dot is answered from the live-set sidecars — never fold the ledger for it (`session_log.sh`).** `dropped --pending <cwd>` is warden's hot loop: one poll per session-less tab every few seconds across every tab its root scan finds. The ledger path folds the whole log through `jq` and then spawns processes per candidate server just to re-derive a sidecar path, so it costs O(ledger) **forks** per poll — spawns, not data, are the cost. Everything the question needs is instead recorded at **event time** onto the window itself (`@amux_cwd`/`@amux_agent` at open, `@amux_resumable` when a resume hint lands) and copied into `<state>/live/<sockethash>-<pid>.windows` by `_sl_snapshot`, so `_sl_pending_fast` answers with **one** `awk` over the whole glob — a fork moved inside that scan is a silent 40x regression no test asserts on. Three invariants: on the fast path `--pending` emits the single literal line **`pending`** (its only consumer, `_amux_probe`, tests for emptiness — that narrowing is what lets sidecars replace the fold), and the `agent<TAB>cwd<TAB>resume_cmd<TAB>maxts` row contract holds only on the **ledger fallback**, which `--new` and the restore picker do read. `_sl_pending_fast` is **three-state** — 0 = drop, 1 = none, **2 = cannot answer → fall through to the ledger** — and 2 must never collapse to 1: a legacy or `.sock`-less sidecar, or a ledger server with no sidecar at all, is absence of information, and answering "no" there silently stops ghosting recoverable sessions. **Every one of those bails is scoped to the queried cwd, and keeping it scoped is what makes the fast path worth having** — a state dir is the residue of every project on the machine, so an unresolvable sidecar is guaranteed, and bailing on sight makes the path answer for *no* cwd at all (measured: 11 legacy lines on other projects' long-dead servers deferred all 47 cwds; scoped, 23 answer). Scope only on information actually held — the ledger places a legacy window by `(socket_path, server_pid, window_id)`, and the `.sock` companion is the join that makes that lookup possible — never on "absent, therefore irrelevant". `AMUX_PENDING_NO_FAST=1` forces the fallback, the seam the selftest uses to prove both paths agree on one fixture. The ledger remains the durable log and the restore picker's source, **not** the dot's query surface; a state dir predating the sidecar contract is brought up to it by the one-shot, idempotent `session_log.sh migrate` — purely for speed, since the fast path is sound without it (see `docs/FOLLOWUPS.md`).

**Any new deliberate-teardown path must `session_log.sh discard` the agent shard's sidecar first (`bin/amux`).** The agent session is the only one on its shard, so `kill-session` tears down the whole server — and a dead server whose sidecar still lists windows *is* the **crash signature** the restore picker recovers from, so its kills would come back as offers to restore. `_amux_kill`/`_amux_kill_all` write an **empty** sidecar before killing (empty → offer nothing; *absent* → dead legacy server, offer ALL — so discard must write the empty file, never delete it). Add a `--kill`-like command → discard first, or its kills read as crashes. Discard declares that intent **synchronously**; it does not lean on the async `window-unlinked` hook, which covers the ordinary close path (including the last window — see `_sl_live_windows` for the hard case there). (Frame/term kills need none — only agent sessions log `open` events.)

**A CLI-invoked helper that runs `tmux` must take the resolved socket — bare `tmux` hits the wrong server (`bin/amux`).** A helper called from the `bin/amux` process (window styling, open-logging) has **no ambient `$TMUX`** for the shard — the CLI hasn't attached — so bare `tmux` falls back to the literal `default` socket and silently does nothing on the shard. Bitten twice (`session_log.sh` `_sl_ctx`, `agent_window_style.sh`), presenting as the first agent pane starting colourless with a bare label (windows 1+ are fine — their `after-new-window` hook runs *inside* the agent server where `$TMUX` is correct). Rule: CLI-path helpers accept `$(_amux_agent_sock)` and use `env -u TMUX tmux -L "$sock"`; hook-path helpers keep the inherited `$TMUX`.

**The CWD-derived `--probe`/`--kill` are dir-guarded — don't collapse them to a bare name check (`bin/amux`).** A session is named after `$PWD`'s basename, so two projects sharing one (`~/work/api`, `~/personal/api`) collide. warden drives the arg-less probe/kill by cwd, so a naïve `has-session <basename>` would probe — and `--kill` would tear down — the wrong same-basename project. Each session records `@amux_dir`; `_amux_*_session_is_mine` gate the arg-less path on `@amux_dir == $PWD`. Invariants: an **explicit** `<name>` skips the guard (targets by name); a session with **no** `@amux_dir` counts as ours (no regression for pre-existing sessions). Residual cross-fire on the *named* path when two same-basename agents run at once is tracked in `docs/FOLLOWUPS.md` ("Named `--kill <basename>`").

**Summary status rows are PUSHED (event-driven) — never turn them back into a `#()` poll (`tmux-status.sh`, `agentmux.conf`).** The writer renders the three rows on each hook event and sets them as `@amux_row1/2/3` **pane options**; `status-format[1..3]` reference those statically, so a redraw substitutes a value and **spawns nothing**. The old `#(summary_rows.sh …)` poll re-ran per client per `status-interval` with no backpressure — under load (a post-reboot Spotlight storm) spawns outran drain and exhausted the **per-user process table** (`kern.maxprocperuid`), so `fork()` failed for everything while CPU/RAM sat idle: a lockup that reads like a freeze. Diagnose with `ps -Axo user= | grep -c $(id -un)` climbing past ~400. Show live status via pushed options, never a `#()` in the status format.

**Hot-path config/socket lookups must ride the launch-time memo, never re-fork (`bin/amux`).** A cold `amux` launch fires dozens of `$()` subshells, and each `$()` inherits the parent's caches but its own writes die with it — so a per-process memo (`_amux_json_cache`, `_amux_pwd_hash_val`) re-forks `stat`/`cksum`/`cut`/`cat` on every call. This turned acute post-sharding (fixed-name sockets were constant strings; `cksum`-derived ones are not). `_amux_warm_launch_caches` runs **once** as a direct (non-substituted) statement at the top of the launch paths, so every later `$()` inherits populated memos. Add a launch-path helper that shells out per call → warm it in parent context too. Companion lever on the same cost: chain consecutive same-socket `tmux` calls with the `';'` separator instead of one `env`+`tmux` exec each. (macOS `fork`+`exec` is ~10ms idle but 50–250ms under load, so this is a real cold-start floor — though machine load still dominates.)

**`bin/amux` must stay bash-3.2-clean — no `local -A`/`declare -A` or other bash-4-isms (`bin/amux`).** macOS ships bash 3.2 as `/bin/bash` and `bin/amux` is `#!/usr/bin/env bash` installed via `curl|bash`, so it must run on the stock shell, not a dev machine's Homebrew bash. The rule is commented at the sites and guarded by a selftest (`grep -cE '^[[:space:]]*(local|declare) -A' bin/amux` must be `0`); **don't remove the guard.** Verify a change with `AMUX_SELFTEST=1 /bin/bash bin/amux` (the real `/bin/bash`, not `PATH`'s bash).

**Traps that live at their call site — read the code comment, don't re-document them here:**
- **mtime: GNU `stat -c %Y` before BSD `stat -f %m`, never flip** despite macOS (a shadowing GNU/uutils `stat` reads `-f` as `--file-system` and leaks a non-numeric value) — commented at the `stat` calls in `tmux-status.sh`.
- **OSC 777 notify wraps once *per nested tmux layer*, and `allow-passthrough on` + `extended-keys always` + the `sync` feature must be set on *every* socket the escape/keys/redraw transit** — `tmux-status.sh` (`_tmux_nest_depth`) and `tmux/{agentmux,frame,term}.conf`, each with full rationale. Under `--frame` the agent is two layers deep, so `bin/amux` re-asserts the socket-level features on the long-lived frame server (which never re-reads its `-f` file). Escape/Ctrl-C dying in a framed agent is `extended-keys off`, not the terminal.
- **Per-pane state files key on `<cksum $TMUX socket>-<pane#>`** — pane numbers are unique only per server, so the socket hash disambiguates the two servers a framed agent spans — `tmux-status.sh`.
- **`respawn-pane` with no shell-command re-runs the pane's ORIGINAL start command** — so `prefix x` on a RESTORED or FORKED tab (whose start command is the agent's `--resume <id>` line, the very thing that suppresses `launch_agent.sh`'s auto-launch) brought back the session you were closing. `relaunch.sh` owns the respawn and always names a fresh shell explicitly; **don't re-add a bare `respawn-pane -k` to the `bind-key x` in `agentmux.conf`**. An ordinary tab respawns correctly either way, which is what makes the bare form look proven.
- **An empty window set is a real answer that tmux cannot give**: on the server whose LAST window just closed, `list-windows -a` exits 1 ("no current target") instead of printing nothing, so treating a failed query as "no data" turns an ordinary close into a false crash. Disambiguate on server liveness, and only ever empty a sidecar on positive evidence — `_sl_live_windows` in `session_log.sh`.

## Layout

| Path | Purpose |
|---|---|
| `bin/amux` | The `amux` launcher — standalone bash, single source of truth for amux logic |
| `scripts/` | Shared runtime scripts (`tmux-status.sh`, `summarise.sh`, etc.) |
| `scripts/clear_icon.sh` | `prefix v` binding target — one-shot strips the leading state emoji off the current window name (emoji-agnostic; relies on `tmux-status.sh`'s `"<emoji> <label>"` invariant). Hooks re-badge on the next event |
| `scripts/claude/` | Claude Code adapter scripts (`status.sh`, `ctx.sh`, `digest.sh`, `goal.sh`) |
| `scripts/fork_session.sh` | `prefix f` binding target — forks the current tab's agent session into a new tab, using the `fork_cmd` its adapter recorded in the session log. Passes the fork command as the new window's `pane_start_command`, which is what makes `launch_agent.sh` skip its auto-launch |
| `scripts/session_log.sh` | Durable open/close ledger of agent windows amux opens, for crash recovery. The `dropped [<cwd>\|--global\|--new <cwd>\|--pending <cwd>]` subcommand emits restorable dropped tabs (agent tab, dead server, open-at-death, resume-program-swapped from `[[agents]] resume`); `amux`'s launch picker (and `amux --restore`) consume it. `--new` gates the launch offer once per (dead-server, cwd) via the `notified` marker; `--pending` applies that gate **read-only** — it's what the CWD-derived `amux --probe` uses to exit 3 ("restorable"), and a marking read there would let warden's poll burn the offer. `--pending` is answered from the live-set sidecars and emits only the literal line `pending`; the row contract above is the **ledger fallback's** (see the presence-dot footgun). `migrate` is the one-shot backfill that brings a pre-existing `live/` up to that sidecar contract. The `forkcmd [target]` subcommand emits `agent<TAB>fork_cmd` for one LIVE window, program-swapped the same way; `scripts/fork_session.sh` consumes it |
| `scripts/<agent>/` | Pattern for future agent adapters (e.g. `scripts/gemini/`) |
| `shell/agentmux.sh` | bash/zsh integration: thin `amux` wrapper + zsh completion |
| `shell/agentmux.fish` | fish-shell integration (thin wrapper + completion) |
| `tmux/agentmux.conf` | tmux snippet sourced from `~/.tmux.conf` |
| `tmux/frame.conf` | `amux --frame` outer wrapper config (own socket; no `~/.tmux.conf`) |
| `tmux/term.conf` | `amux --frame` left scratch terminal config (own socket; persistent) |
| `tmux/agent.conf` | Agent socket config, loaded via `-f` by `_amux_atmux` (sources `agentmux.conf`; no `~/.tmux.conf`/TPM). Keeps a cold per-project agent server fast |
| `config/amux.toml.example` | Example agent config |
| `config/user.tmux.conf.example` | Template for the optional **per-role** user tmux overlays — `~/.agentmux/user.{agent,frame,term}.tmux.conf`, each `source-file -q`'d last by its own socket so it overrides amux's defaults without a binding leaking across roles (a shared file would break the frame's C-f layout). The escape hatch for the deliberate `~/.tmux.conf` isolation |
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

**Deploying a `tmux` config change to already-running servers.** Scripts are live
immediately, but `agent.conf`/`agentmux.conf` options are `set -g`, evaluated *once* when a
server sources them — so an edit doesn't reach a running agent server on `git pull`/`amux
--update` (a fresh launch gets it via `-f`; a live one keeps its startup format string, and
you see blank/stale status rows). Run **`amux --reload`** (`_amux_reload`) to re-source
`agent.conf` on every live agent shard — every line there is an idempotent
`set -g`/`bind`/`set-hook`, so it's safe. Agent-sockets only by design (re-sourcing
`frame.conf` would reset the per-launch `[frame] prefix`); frame/term config changes are
picked up by relaunching the frame, and `terminal-features` apply on the next reattach.

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

**Invariant — a selftest that spawns a real tmux server must ride the
selftest-wide `TMUX_TMPDIR`, never set its own.** `tmux kill-server` stops the
server *process* but leaves the socket *file* on disk (macOS never unlinks it),
and selftest socket names embed `$$`, so a server created on the user's shared
`/tmp/tmux-<uid>/` dir strands a fresh orphan file every run — accumulating
unbounded (this leaked ~hundreds of files over time until fixed). `bin/amux`'s
selftest sets one throwaway `TMUX_TMPDIR` at the top with an `EXIT` trap that
`rm -rf`s it, so every server it spawns is confined there and reaped on any exit
path; individual blocks must not override it. A regression assert ("no tmux
sockets stranded in the shared dir") fails loudly if a new block leaks. Keep each
block's `kill-server` (it ends the process; the trap only reaps the files).
`session_log.sh`'s selftest isolates the same way (its own `/tmp/slsktest-$$` +
`rm -rf`). When adding a tmux-spawning selftest, inherit the ambient
`TMUX_TMPDIR`; don't reintroduce a per-block one.

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
RELAUNCH_SELFTEST=1          bash scripts/relaunch.sh
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
