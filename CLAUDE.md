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

**The presence dot is answered from the live-set sidecars — never fold the ledger for it (`session_log.sh`).** `dropped --pending <cwd>` is warden's hot loop: one poll per session-less tab every few seconds across every tab its root scan finds. The ledger path folds the whole log through `jq` and then spawns processes per candidate server just to re-derive a sidecar path, so it costs O(ledger) **forks** per poll — spawns, not data, are the cost. Everything the question needs is instead recorded at **event time** onto the window itself (`@amux_cwd`/`@amux_agent` at open, `@amux_resumable` when a resume hint lands) and copied into `<state>/live/<sockethash>-<pid>.windows` by `_sl_snapshot`, so `_sl_pending_fast` answers with **one** `awk` over the whole glob — a fork moved inside that scan is a silent 40x regression no test asserts on. Three invariants: on the fast path `--pending` emits the single literal line **`pending`** (its only consumer, `_amux_probe`, tests for emptiness — that narrowing is what lets sidecars replace the fold), and the `agent<TAB>cwd<TAB>resume_cmd<TAB>maxts` row contract — columns *and* order (see the pointer list below) — holds only on the **ledger fallback**, which `--new` and the restore picker do read. `_sl_pending_fast` is **three-state** — 0 = drop, 1 = none, **2 = cannot answer → fall through to the ledger** — and 2 must never collapse to 1: a cwd-unknown or `.sock`-less sidecar, or a ledger server with no sidecar at all, is absence of information, and answering "no" there silently stops ghosting recoverable sessions. **A sidecar line's field count is not what makes its cwd known — `_SL_SHAPE_FN` is.** `_sl_live_windows` formats every window with the full four-field `-F` string, so a window whose `@amux_*` options never landed (the stamps are best-effort, and any window open before they shipped re-snapshots this way) still writes four fields with an EMPTY cwd — a cwd-unknown line wearing the current shape. Counted as current, its empty cwd fails the `$2 == c` match and the query resolves to a confident "not this cwd", which is the silent 1 the exit code exists to prevent. `_SL_SHAPE_FN` is the single awk-source encoding of that test (`NF >= 4 && $2 != ""`), shared by `_sl_pending_fast` and `sl_migrate` because both once encoded it as a bare field count and both therefore misread the same line. Likewise **liveness alone is not the deadness test**: a reboot can hand a new server the dead one's pid on its socket, so both paths pair `_sl_server_live` with the boot epoch — the ledger path on its rows' max `ts`, the fast path on the sidecar's mtime (rewritten on every open and close, so it records the same fact), and an older-than-boot sidecar defers rather than reading as live. **Every one of those bails is narrowed to what could actually change THIS cwd's answer, and keeping it narrow is what makes the fast path worth having** — a state dir is the residue of every project on the machine, so an unresolvable sidecar is guaranteed, and bailing on sight makes the path answer for *no* cwd at all (measured over 47 cwds: bail-on-sight 0 answered, scoped to the cwd 23, plus the inertness test 44). Two narrowings, both from information actually held, never from "absent, therefore irrelevant". PLACEMENT: the ledger places a cwd-unknown window by `(socket_path, server_pid, window_id)`, and the `.sock` companion is the join that makes that lookup possible; a window it places elsewhere is dropped by the ledger path's own `cwd != scope` test, so ignoring it cannot disagree. INERTNESS: a sidecar line only ever *gates* ledger rows — it is the was-open-at-death set the fold intersects with — and never contributes one, so a window the ledger holds **no row** for is a set member nothing can be emitted for, and its unknown cwd cannot change the answer on any server. Only a window the ledger holds a row for while naming no cwd for it still bails. That second test is keyed on `(server_pid, window_id)` and recorded *before* the socket-path parse can skip a row: incompleteness in it turns a live window into a false "inert", i.e. the wrong `1` — so it is deliberately the coarser key, since coarse can only preserve a bail, never invent an answer. `AMUX_PENDING_NO_FAST=1` forces the fallback, the seam the selftest uses to prove both paths agree on one fixture. The ledger remains the durable log and the restore picker's source, **not** the dot's query surface; a state dir predating the sidecar contract is brought up to it by the one-shot, idempotent `session_log.sh migrate` — purely for speed, since the fast path is sound without it (see `docs/FOLLOWUPS.md`).

**`sl_prune`'s keep set is the QUERY'S REACHABILITY, and widening it is not the safe direction it looks like (`session_log.sh`).** `sl_dropped` collapses to ONE dead server per answer (its `NR==1` "last crash only" stage), so what a query can ever name is: every LIVE server, plus — per cwd — the dead server holding the newest *emittable* row (agent row, resume hint, window in that server's live-set sidecar), plus the same again among the servers the `notified` marker has not yet burned (the gate `--new`/`--pending` apply, which reaches past the ungated winner). Everything else is dead weight the fold parses on every ledger-path poll; a time-based cutoff cannot see it (measured: 246 servers across 47 cwds, ~200 unreachable). The trap is that the keep set is an **argmax**, so counting a server emittable when it is not does not merely over-retain — it **shadows the real winner and prunes it**. Hence the deliberate asymmetry: when a sidecar cannot be placed on a server (no readable `.sock` companion), prune keeps that server whole AND withholds it from the competition, so neither it nor anything behind it can be lost. Deadness here must be the query's deadness — `_sl_server_live` **paired with the boot epoch**, since a narrower notion of "live" is what lets a wrongly-dead server win a cwd and evict the real answer. Two consequences that must move together: a kept DEAD server is trimmed to the windows in its own (frozen) sidecar — that, not the server count, is what bounds the ledger, since a long-lived project shard logs a row per launch forever while only the windows open AT DEATH are restorable — and the **sidecar sweep runs on the same keep set, matched on `(socket, pid)` from the `.sock` companion**. Matching on the pid alone leaves a same-pid sidecar from a DIFFERENT socket behind, and `_sl_pending_fast` then answers "pending" from a candidate the ledger can no longer see; deleting a sidecar from under a server the ledger still names flips it to the "no sidecar → every window was open at death" reading and re-offers closed tabs. `AGENTMUX_LOG_MAX_LINES` is set against the measured steady state (272 lines on a real 47-project dir), not against "big": a cap far above it just restores the sawtooth the keep set exists to remove.

**Any new deliberate-teardown path must `session_log.sh discard` the agent shard's sidecar first (`bin/amux`).** The agent session is the only one on its shard, so `kill-session` tears down the whole server — and a dead server whose sidecar still lists windows *is* the **crash signature** the restore picker recovers from, so its kills would come back as offers to restore. `_amux_kill`/`_amux_kill_all` write an **empty** sidecar before killing (empty → offer nothing; *absent* → dead legacy server, offer ALL — so discard must write the empty file, never delete it). Add a `--kill`-like command → discard first, or its kills read as crashes. Discard declares that intent **synchronously**; it does not lean on the async `window-unlinked` hook, which covers the ordinary close path (including the last window — see `_sl_live_windows` for the hard case there). (Frame/term kills need none — only agent sessions log `open` events.)

**A CLI-invoked helper that runs `tmux` must take the resolved socket — bare `tmux` hits the wrong server (`bin/amux`).** A helper called from the `bin/amux` process (window styling, open-logging) has **no ambient `$TMUX`** for the shard — the CLI hasn't attached — so bare `tmux` falls back to the literal `default` socket and silently does nothing on the shard. Bitten twice (`session_log.sh` `_sl_ctx`, `agent_window_style.sh`), presenting as the first agent pane starting colourless with a bare label (windows 1+ are fine — their `after-new-window` hook runs *inside* the agent server where `$TMUX` is correct). Rule: CLI-path helpers accept `$(_amux_agent_sock)` and use `env -u TMUX tmux -L "$sock"`; hook-path helpers keep the inherited `$TMUX`.

**The CWD-derived `--probe`/`--kill` are dir-guarded — don't collapse them to a bare name check (`bin/amux`).** A session is named after `$PWD`'s basename, so two projects sharing one (`~/work/api`, `~/personal/api`) collide. warden drives the arg-less probe/kill by cwd, so a naïve `has-session <basename>` would probe — and `--kill` would tear down — the wrong same-basename project. Each session records `@amux_dir`; `_amux_*_session_is_mine` gate the arg-less path on `@amux_dir == $PWD`. Invariants: an **explicit** `<name>` skips the guard (targets by name); a session with **no** `@amux_dir` counts as ours (no regression for pre-existing sessions). Residual cross-fire on the *named* path when two same-basename agents run at once is tracked in `docs/FOLLOWUPS.md` ("Named `--kill <basename>`").

**Summary status rows are PUSHED (event-driven) — never turn them back into a `#()` poll (`tmux-status.sh`, `agentmux.conf`).** The writer renders the three rows on each hook event and sets them as `@amux_row1/2/3` **pane options**; `status-format[1..3]` reference those statically, so a redraw substitutes a value and **spawns nothing**. The old `#(summary_rows.sh …)` poll re-ran per client per `status-interval` with no backpressure — under load (a post-reboot Spotlight storm) spawns outran drain and exhausted the **per-user process table** (`kern.maxprocperuid`), so `fork()` failed for everything while CPU/RAM sat idle: a lockup that reads like a freeze. Diagnose with `ps -Axo user= | grep -c $(id -un)` climbing past ~400. Show live status via pushed options, never a `#()` in the status format.
The notes surface rides the same rule: `status-format` picks between `@amux_rowN` and
`@amux_noteN` on a flag, so a redraw still substitutes values and spawns nothing. A note
row must never become a `#()` either. Two options per row is load-bearing —
`@amux_note_rawN` is what the user typed and `@amux_noteN` is that text with `#` doubled
for `status-format`'s re-parse; collapsing them to one option makes every edit re-escape
its own output (`fix #42` → `fix ##42` → `fix ####42`).

**Row 4's empty-state hint is a SESSION-scope default published at launch, not the product of a render (`bin/amux`, `scripts/notes.sh`).** `status-format[4]` substitutes `@amux_note4`, but the only thing that ever *writes* that option — `notes.sh`'s `_nt_render` — hangs off the click binding and `prefix N`, and neither is on the launch path. So `_amux_ensure_agent_session` publishes `notes.sh hint 4` (its `NT_HINT4`, the one home for the literal) as the **session-level** `@amux_note4` alongside `@amux_note_row`; tmux resolves pane→window→session→global, so one write covers every window and pane of the session — including the ones amux never creates itself (restored/forked tabs carry a `pane_start_command` and are deliberately skipped by `launch_agent.sh`; split panes likewise) — and a real note, always written pane-level, shadows it. Rendering per window instead *looks* equivalent: it costs a fork per window, misses every creation path amux doesn't own, and needs the CLI-socket dance for window 0 (`after-new-window` never fires for a session's first window). Both note-row options are emitted **symmetrically** — `set-option -u` when `[notes] row` is false — because that batch runs on **every** `amux` for the project, not only at creation, so an add-only emit left a running session's row stuck on until `amux --kill`. What keeps the guard honest is a paired assertion: pane-scope `@amux_note4` unset **and** the format chain resolving to the hint. A test fixture that renders before asserting (as `reset_to_summary` once did) satisfies the second on its own and passes whether or not the product ever puts the hint on screen — which is exactly how the row shipped blank.

**Hot-path config/socket lookups must ride the launch-time memo, never re-fork (`bin/amux`).** A cold `amux` launch fires dozens of `$()` subshells, and each `$()` inherits the parent's caches but its own writes die with it — so a per-process memo (`_amux_json_cache`, `_amux_pwd_hash_val`) re-forks `stat`/`cksum`/`cut`/`cat` on every call. This turned acute post-sharding (fixed-name sockets were constant strings; `cksum`-derived ones are not). `_amux_warm_launch_caches` runs **once** as a direct (non-substituted) statement at the top of the launch paths, so every later `$()` inherits populated memos. Add a launch-path helper that shells out per call → warm it in parent context too. Companion lever on the same cost: chain consecutive same-socket `tmux` calls with the `';'` separator instead of one `env`+`tmux` exec each. (macOS `fork`+`exec` is ~10ms idle but 50–250ms under load, so this is a real cold-start floor — though machine load still dominates.)

**`bin/amux` must stay bash-3.2-clean — no `local -A`/`declare -A` or other bash-4-isms (`bin/amux`).** macOS ships bash 3.2 as `/bin/bash` and `bin/amux` is `#!/usr/bin/env bash` installed via `curl|bash`, so it must run on the stock shell, not a dev machine's Homebrew bash. The rule is commented at the sites and guarded by a selftest (`grep -cE '^[[:space:]]*(local|declare) -A' bin/amux` must be `0`); **don't remove the guard.** Verify a change with `AMUX_SELFTEST=1 /bin/bash bin/amux` (the real `/bin/bash`, not `PATH`'s bash).

**Traps that live at their call site — read the code comment, don't re-document them here:**
- **mtime: GNU `stat -c %Y` before BSD `stat -f %m`, never flip** despite macOS (a shadowing GNU/uutils `stat` reads `-f` as `--file-system` and leaks a non-numeric value) — commented at the `stat` calls in `tmux-status.sh`.
- **OSC 777 notify wraps once *per nested tmux layer*, and `allow-passthrough on` + `extended-keys always` + the `sync` feature must be set on *every* socket the escape/keys/redraw transit** — `tmux-status.sh` (`_tmux_nest_depth`) and `tmux/{agentmux,frame,term}.conf`, each with full rationale. Under `--frame` the agent is two layers deep, so `bin/amux` re-asserts the socket-level features on the long-lived frame server (which never re-reads its `-f` file). Escape/Ctrl-C dying in a framed agent is `extended-keys off`, not the terminal.
- **Per-pane state files key on `<cksum $TMUX socket>-<pane#>`** — pane numbers are unique only per server, so the socket hash disambiguates the two servers a framed agent spans — `tmux-status.sh`.
- **`respawn-pane` with no shell-command re-runs the pane's ORIGINAL start command** — so `prefix x` on a RESTORED or FORKED tab (whose start command is the agent's `--resume <id>` line, the very thing that suppresses `launch_agent.sh`'s auto-launch) brought back the session you were closing. `relaunch.sh` owns the respawn and always names a fresh shell explicitly; **don't re-add a bare `respawn-pane -k` to the `bind-key x` in `agentmux.conf`**. An ordinary tab respawns correctly either way, which is what makes the bare form look proven.
- **`sl_dropped`'s row ORDER is the restored tab order, and it is not the recency order the same function sorts by** — `_amux_restore_into` creates one window per row *in order* (first row replaces window 0), so emitting the ts-desc stream that `NR==1` last-crash scoping and uuid dedup need restored a crashed session with its tabs reversed. Two orderings, both load-bearing: recency picks *which* rows survive, window id decides *where* each one lands — so the final stage re-sorts on window id after the dedup, and the picker renders recency as a per-row "(ago)" instead. Read the final-stage comment in `sl_dropped` before reordering either for display.
- **An empty window set is a real answer that tmux cannot give**: on the server whose LAST window just closed, `list-windows -a` exits 1 ("no current target") instead of printing nothing, so treating a failed query as "no data" turns an ordinary close into a false crash. Disambiguate on server liveness, and only ever empty a sidecar on positive evidence — `_sl_live_windows` in `session_log.sh`.

## Layout

| Path | Purpose |
|---|---|
| `bin/amux` | The `amux` launcher — standalone bash, single source of truth for amux logic |
| `scripts/` | Shared runtime scripts (`tmux-status.sh`, `summarise.sh`, etc.) |
| `scripts/clear_icon.sh` | `prefix v` binding target — one-shot strips the leading state emoji off the current window name (emoji-agnostic; relies on `tmux-status.sh`'s `"<emoji> <label>"` invariant). Hooks re-badge on the next event |
| `scripts/claude/` | Claude Code adapter scripts (`status.sh`, `ctx.sh`, `digest.sh`, `goal.sh`) |
| `scripts/fork_session.sh` | `prefix f` binding target — forks the current tab's agent session into a new tab, using the `fork_cmd` its adapter recorded in the session log. Passes the fork command as the new window's `pane_start_command`, which is what makes `launch_agent.sh` skip its auto-launch |
| `scripts/notes.sh` | `prefix N` and status-row click target — per-tab notes in the status rows. Slots 1-3 ride the summary/notes swap (`@amux_notes`); **slot 4 is the always-on note line** on `status-format[4]`, outside the swap entirely — it reads only its own raw, carries its own empty-state hint (published at launch as a session default — see the footgun — since nothing renders a fresh tab), and never touches the mode flag. The `hint 4` subcommand is that publish's single source. Writes `@amux_note_rawN` (what you typed, the prefill source) and `@amux_noteN` (escaped for display). Never touches `@amux_rowN`, so the summary pipeline is untouched and toggling back shows a current summary. Rows 1-3 are click-INERT while the summaries show — clicking one no longer enters notes mode (row 4 is the summary-mode click target). Two display invariants, both asserted: every row showing a note leads with `NT_MARK` (empty or not — the mark identifies a note ROW, so marking only the first made the others read as filler), and the hints style with `#[dim]`, never a fixed `fg=` — the row's background is a per-session shade spanning the whole colour cube, so one hardcoded grey is unreadable against much of it, and a format can't adapt it (`#{?…}` inside a substituted option value is not expanded; `#{E:…}` would expand directives in user note text, which `_nt_esc` exists to prevent). A click also sets `message-line` to the row it is editing, so the prompt opens there instead of over the window list. Row 4 additionally carries a **second range** (`amuxcopy4`) — a button holding copy+clear (`⧉`) or undo (`↩`) by state, written to `@amux_btn4` at a CONSTANT width including its blank state, which is why `status-format[4]` substitutes it with no `#{pN:…}` pad (a pad would be a second home for that width) and why the note text never shifts as the button changes. It leads the row because the `#{p400:…}` pad consumes the line, so a right-hand control would be off screen. The clear is destructive, so it is made safe three ways before it fires — clipboard, tmux paste buffer (`load-buffer`, the one that cannot fail quietly), and `@amux_note_raw_prev4` for the undo |
| `scripts/session_log.sh` | Durable open/close ledger of agent windows amux opens, for crash recovery. The `dropped [<cwd>\|--global\|--new <cwd>\|--pending <cwd>]` subcommand emits restorable dropped tabs (agent tab, dead server, open-at-death, resume-program-swapped from `[[agents]] resume`); `amux`'s launch picker (and `amux --restore`) consume it. `--new` gates the launch offer once per (dead-server, cwd) via the `notified` marker; `--pending` applies that gate **read-only** — it's what the CWD-derived `amux --probe` uses to exit 3 ("restorable"), and a marking read there would let warden's poll burn the offer. `--pending` is answered from the live-set sidecars and emits only the literal line `pending`; the row contract above is the **ledger fallback's** (see the presence-dot footgun). `migrate` is the one-shot backfill that brings a pre-existing `live/` up to that sidecar contract. The `forkcmd [target]` subcommand emits `agent<TAB>fork_cmd` for one LIVE window, program-swapped the same way; `scripts/fork_session.sh` consumes it. `prune` (run from every `sl_open`, self-gated on `AGENTMUX_LOG_MAX_LINES`) trims the ledger, the `notified` marker and the `live/` sidecars to that reachable set — see the footgun |
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
| `tests/mouse/` | The status-bar click suite — the only test that exercises the path a real mouse click takes (`NOTES_SELFTEST` stops short of it by design). `run.sh` is the entry point; `main.exp`/`frame.exp`/`lib.tcl` are the `expect` drivers. Its `README.md` carries the technique and the traps that make a harness of this shape silently test nothing |
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

**`--reload` also re-publishes the LAUNCH-TIME config-derived session options
(`_amux_reload_config_opts`), and a new one of those belongs there too.** Re-sourcing
`agent.conf` only reloads what lives *in* the tmux config; a field read from `amux.toml`
by `bin/amux` and published as a tmux *option* (`[notes] row` → `@amux_note_row` →
`update_colors.sh`'s row count) needs this second step, or `--reload` silently delivers
half the change — the shipped bug that prompted it: the new `status-format[4]` arrived,
the option and the fifth row did not, and the command appeared to do nothing at all.
`_amux_note_opts` is the single emitter both this and the launch path use, so they cannot
drift. Two traps it encodes: resolve each session against **its own `@amux_dir`**, never
`$PWD` (reload spans every project, and `[notes.dirs]` answers per directory; a session
with no `@amux_dir` is skipped rather than resolved against the wrong one), and target
sessions by **bare name** — `show-options -t '=name'` silently returns empty and
`set-option -t '=name'` errors `no such session`, so the `=` exact-match form used by
`_amux_attach` publishes *nothing* here while looking right.

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
shellcheck, the `fish -n` syntax check, every selftest below, and the
`tests/mouse` click suite; it prints a per-check pass/fail line and a summary, and
exits non-zero if anything fails. It's runnable from any cwd and is what CI runs
(`.github/workflows/ci.yml`, on push to `dev`/`main` and every PR — the runner
installs `tmux` and `expect`, then a dedicated step builds tmux from source when
the packaged version is below the click suite's 3.6 floor, so the tmux-gated
selftests and the click suite actually run rather than self-skip).

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

**Invariant — a selftest that spawns a real tmux server must ISOLATE it under a
throwaway `TMUX_TMPDIR` and REAP that dir on the way out.** Never the user's
shared `/tmp/tmux-<uid>/`: `tmux kill-server` stops the server *process* but
leaves the socket *file* on disk (macOS never unlinks it), and selftest socket
names embed `$$`, so a server on the shared dir strands a fresh orphan every run
— accumulating unbounded (this leaked ~hundreds of files before it was fixed).
Keep each block's `kill-server` too: it ends the process, the `rm -rf` only reaps
the files.

**`kill-server` returns BEFORE its teardown hooks finish, so `kill-server; rm -rf`
is not enough on its own.** Destroying the windows fires `window-unlinked` →
`run-shell session_log.sh …`, and those children are forked by the *dying* server,
so they outlive both the `kill-server` return and the `rm -rf` that follows it.
Measured: the dir is gone, and ~0.3s later `state/live` is back — a run that
reported a clean exit stranded one dir every time. Wait for the teardown children
(then re-check) rather than trusting `kill-server`'s exit. This is also the sharper
reason `AGENTMUX_STATE_DIR` must be scoped **before the server starts**, not merely
around the test body: those writes land at *teardown*, after the assertions have
passed, so an unscoped run pollutes the user's real `live/` at the moment it looks
finished.

*Which* throwaway dir is a per-block call, and both shapes are in use.
`bin/amux`'s selftest sets one at the top with an `EXIT` trap that `rm -rf`s it,
covering every block and every exit path — blocks there inherit it rather than
overriding, and a regression assert ("no tmux sockets stranded in the shared
dir") fails loudly if one leaks. `session_log.sh`'s selftest instead gives each
tmux-spawning block its own short literal dir (`/tmp/sl<block>-$$`) with a
matching `rm -rf`, because its state dir comes from `mktemp -d` and a macOS
`mktemp` path plus a socket name can exceed the 104-char `AF_UNIX` limit —
the shared-dir hazard is the thing to avoid, not per-block dirs as such. When
adding a tmux-spawning selftest, follow the file you're in, and make sure the
dir you use is removed on every path out.

**Companion invariant — a selftest block that opens a real session must also
scope `AGENTMUX_STATE_DIR` to a throwaway dir, `export`ed and reaped.** Isolating
the tmux socket is not enough: opening a session reaches `sl_open`, which appends
to the ledger and writes a `live/` sidecar, so an unscoped block mutates the
*user's* real state — invisibly (nothing fails), and not inertly, since that
residue is the input to `sl_dropped`'s per-server liveness sweep. Save the previous
value, `export` the `mktemp -d`, and restore-or-`unset` it on the way out; `export`
matters because the tmux server the block spawns must inherit it. Acceptance check
for any such block: `wc -l` the real ledger and count `live/` entries before and
after a full `sh test.sh` — both must be unchanged.

**Third invariant — a selftest that exercises a HOOK-PATH helper must also isolate
`$TMUX`, not just `TMUX_TMPDIR`.** A hook-path helper (`notes.sh`, and the same class
as `session_log.sh`'s `_sl_ctx` and `agent_window_style.sh`) resolves its server from
the ambient `$TMUX` by design — it calls bare `tmux` with no `-L`, because tmux itself
invokes it from a key binding. So a selftest run *from inside a live agentmux pane*
writes its options onto the **user's real session** — this actually happened during
development, when an un-isolated run set `@amux_note1` on a live pane. Isolating
`TMUX_TMPDIR` alone does **not** prevent it — that variable only governs where *new*
sockets are created, not which server a bare `tmux` resolves. Save `$TMUX`, point it
at the throwaway socket (ask tmux for it, `display-message -p '#{socket_path}'`, the
way `session_log.sh` does — don't hand-build the path from `TMUX_TMPDIR`'s layout),
and restore it on every exit path alongside `TMUX_TMPDIR`. In a clean CI environment
with no ambient `$TMUX` the unfixed version still fails, just without the
contamination: bare `tmux` resolves to socket `default`, which the test never creates.
This is the mirror image of the CLI-path/hook-path split in Footguns above — that one
says a CLI-invoked helper must take the resolved socket because it has no ambient
`$TMUX`; this one says a *test* of a hook-path helper must fake the ambient `$TMUX`
precisely because the helper trusts it.

**Fourth invariant — a selftest's cleanup trap must be `EXIT`-only and idempotent.** Adding `INT TERM`
alongside `EXIT` looks like better signal coverage, but a POSIX-sh handler that
doesn't itself `exit` lets the shell *resume* after it — so an `INT TERM EXIT` trap
list runs cleanup once from the signal and again from the normal fall-through, and a
cleanup that `rm -rf`s a variable it then reassigns will, on that second run, delete
the **user's real** directory once the first run has already restored it to its real
value. `bin/amux`'s selftest is the precedent for the trap list — `EXIT` only. The
done-guard is the second half and is `notes.sh`'s own: `bin/amux` needs none because
nothing calls its cleanup a second time, whereas a block that also cleans up on its
normal fall-through must be safe to run twice. Accepted cost
of `EXIT`-only: under `dash` (CI's `/bin/sh`) an untrapped `SIGINT` doesn't fire the
`EXIT` trap either, so one throwaway dir is stranded — non-destructive, and specific to
POSIX-sh scripts run under dash. It does **not** match `bin/amux`'s behaviour: `bin/amux`
is bash, and bash **does** fire its `EXIT` trap on an untrapped `SIGINT`, so it never
strands anything this way. The shared precedent with `bin/amux` is the trap-list
*shape* (`EXIT` only, no `INT`/`TERM`), not this dash-specific stranding.

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
NOTES_SELFTEST=1             sh scripts/notes.sh
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

### The mouse-click suite (`tests/mouse`)

The one test that exercises a **real mouse click**. `NOTES_SELFTEST` covers
`scripts/notes.sh` except the click itself — it invokes `click` with a `/dev/null`
client tty on purpose, so `command-prompt` fails fast instead of hanging a headless
run — which leaves the path a real click takes uncovered by every other test, and the
defects it hides are silent (the worst found: `command-prompt` substitutes *all*
`%1`–`%9` occurrences in its template with the typed response, and pane ids are
`%0`, `%1`, `%2`…, so a literal pane id in the target made every tab but the first
silently do nothing at all).

```bash
bash tests/mouse/run.sh                       # 12 checks; from any cwd
AMUX_MOUSE_VERBOSE=1 bash tests/mouse/run.sh  # every assertion, not just failures
```

The suite runs at five status lines and sets `@amux_note_row 1` itself, since
`update_colors.sh` picks `status 4` without it — one fewer row than the suite's
own checks need. It also publishes the session-level `@amux_note4` default, by
asking `notes.sh hint 4` for it exactly as `bin/amux` does: it drives tmux, not
amux, so it has to stand in for the launch-time publish — and the row-4 checks
observe the genuine un-rendered launch state, so a stand-in that restated the
literal (or a fixture that rendered first) would test the harness, not the row.

**`expect` is a test-only dependency**, exactly like `shellcheck` — needed to develop
agentmux, never to run it, so the Stack section's "`toml2json` + `jq` are the only
runtime dependencies" still holds. **tmux must also be >= 3.6** — the suite clicks
through `command-prompt -l` (`scripts/notes.sh`), which doesn't exist before that
release; the floor and the `tmux -V` parse are single-sourced in
`scripts/tmux_version.sh`, consumed by both `tests/mouse/run.sh`'s preflight (hard
abort) and `test.sh`'s classification below. `test.sh` skips this check with a note
when `expect`/`tmux` is missing **or** an installed tmux is below 3.6 (the message
names the version found), **except** under `AGENTMUX_REQUIRE_MOUSE_TESTS=1` (set by
CI), where either condition fails instead: a self-skipping *regression* test stops
protecting you wherever it skips, unlike an advisory linter, so CI must not be able
to pass by skipping it — CI's workflow also builds tmux from source when the
packaged version lags, so the runner is actually capable rather than hoped to be.

It is **slower than the other selftests (~1 minute)** — it drives real pty clients
and must settle between clicks — so run it directly while iterating and let `test.sh`
sequence it last. `tests/mouse/README.md` carries the technique (why a genuinely
attached, correctly *sized* pty is required; asserting on `show-options` rather than
the rendered screen; the row→line arithmetic) and the traps that make a harness of
this shape silently test nothing. Read it before changing the suite.

## Linting

`shellcheck` is the linter (install with `brew install shellcheck`). It's lint-only, not a runtime dep, so it doesn't conflict with the toml2json + jq rule — but it's expected to be run before landing shell changes, not treated as optional:

```bash
shellcheck scripts/*.sh scripts/claude/*.sh shell/agentmux.sh bin/amux install.sh tests/mouse/run.sh
fish -n shell/agentmux.fish   # fish can't be shellcheck'd; this is its syntax check
```

`tests/mouse/`'s `.exp`/`.tcl` drivers are Tcl, not shell — shellcheck can't read
them and shouldn't be pointed at them; only `run.sh` is a target.

Known-benign findings (do **not** chase these to zero — they're inherent to the patterns, not regressions):

- **SC1091** "Not following: …" — dynamic `source "$SCRIPT_DIR/…"` paths shellcheck can't resolve statically.
- **SC2154** `_llm_url`/`_llm_model`/`_llm_timeout` "referenced but not assigned" — set by `_amux_load_llm` inside `llm-config.sh`; shellcheck doesn't trace function-set globals across a sourced file.

Real findings (anything else, especially error-level) must be fixed or, for a genuine false positive, suppressed with a commented `# shellcheck disable=<code>` on that line (see the zsh `(@f)` line in `shell/agentmux.sh`). A clean run filters to actionable severity:

```bash
shellcheck --severity=warning scripts/*.sh scripts/claude/*.sh shell/agentmux.sh bin/amux install.sh tests/mouse/run.sh
```
