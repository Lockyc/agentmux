---
type: reference
links:
  - rel: part-of
    to: CLAUDE.md
    note: the deferred-work register CLAUDE.md's Layout table points into
---
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

## Named `--kill <basename>` can cross-fire between two live same-basename projects

**Status:** deferred — a low-severity edge introduced by per-project socket sharding; the real
fix is the already-deferred "give same-basename projects distinct names" change.

**Where:** `bin/amux` → `_amux_kill` (the explicit-name branch resolving `fsock`/`tsock`).

**What:** under per-project socket sharding, `amux --kill <base>` resolves the frame and term
sockets by **two independent scans** — `_amux_frame_socks | _amux_sock_hosting "${base}-frame"`
and `_amux_term_socks | _amux_sock_hosting "${base}-term"`. If two same-basename projects
(`~/work/api`, `~/personal/api`) both have live frames at once, `<base>-frame` and `<base>-term`
live on two different shards, so the two scans can land on **different** projects — `amux --kill api`
could tear down project A's frame but project B's scratch terminal.

**Why it's fine today:** warden drives kill via the **CWD no-arg** path, where `fsock`/`tsock`
both derive from the one `$PWD` (`_amux_frame_sock`/`_amux_term_sock`) and cannot mismatch. Only an
**explicit** same-basename `amux --kill <name>` typed by hand hits this, and running two
same-basename projects' frames simultaneously is itself the case the CWD guard (`@amux_dir`) exists
to disambiguate. Pre-sharding this couldn't happen (one shared socket meant only one same-basename
project could hold a frame at all).

**Fix when we act on it:** fold into the deferred "distinct session names for same-basename
projects" work (see the `@amux_dir` guard footgun in CLAUDE.md) — once names are unique the
cross-fire is impossible. A narrower stopgap: resolve `tsock` from the **same** shard `fsock`
resolved to (frame `agentmux-frame-<hash>` → term `agentmux-term-<hash>`, same suffix) instead of
an independent scan, so the pair always belongs to one project.

**Trigger to revisit:** the same-basename distinct-naming change is picked up, or a hand-typed
`amux --kill <name>` is observed killing the wrong project's terminal.

**Agent sharding widens the same collision to live agent sessions, not just frame/term.**
Before agent-socket sharding, two same-basename projects (`~/work/api`, `~/personal/api`)
could never both hold a *live agent* session at once — one shared agent socket meant tmux's
own session-name uniqueness made the second project's `amux` just attach to the first's
session. Now that agents are sharded too (`agentmux-agent-<cksum $PWD>`, see the `@amux_dir`
guard footgun in CLAUDE.md), each project gets its own agent server, so both `api` sessions
*can* be live simultaneously. `_amux_sock_hosting` (used by named `amux --kill <name>`,
`amux --probe <name>`, and the new `amux attach <name>`) resolves a name by scanning every
agent shard and returning the **first** match — so with two live same-basename agents,
`amux --kill api` / `amux attach api` deterministically addresses whichever shard sorts
first in the glob, not necessarily the one the caller meant. Same root cause and same fix as
the frame/term case above (distinct session names removes it outright); until then this is
the agent-session sibling of the frame/term cross-fire, not a separate bug.

**Trigger to revisit (agent case):** as above, plus any report of `amux --kill <name>` or
`amux attach <name>` landing on the wrong same-basename project's agent session.

## `--pending` still defers for a legacy window the ledger places in this cwd

**Status:** deferred — 44 of the 47 cwds on a real state dir now answer from the sidecars;
the 3 that do not all hit one condition, and narrowing it further needs evidence this pass
does not currently collect. This is a speed ceiling, never a correctness one: a deferral is
the ledger path answering, which is always right.

**Where:** `<state>/live/*.windows` + their `.sock` companions, produced by `_sl_snapshot`;
consumed by `_sl_pending_fast` in `scripts/session_log.sh`.

**What — THREE independent conditions make a query unanswerable from the sidecars alone,
and every one of them is scoped to the queried cwd** (an unresolvable sidecar belonging to
another project must never suppress the answer here — see the presence-dot footgun in
CLAUDE.md, and the `t6:` selftest block that pins each shape as a pair):

1. **Legacy line shape** (`exit 3`). The current shape is 4 tab-separated fields (window
   id, cwd, agent, resumable); a line whose cwd is unknown — a bare pre-migration window
   id, or an unstamped 4-field line — hides which project it concerns. Two tests can retire
   it, and it defers only when both fail. **Placement:** the ledger records cwd per
   `(socket_path, server_pid, window_id)` (the `.sock` companion is the join back to the
   socket path), so a window the ledger puts in another cwd is irrelevant here — but one it
   puts in *this* cwd stays unresolvable, and that is the only condition still deferring on
   the real dir. **Inertness:** a sidecar line only ever *gates* ledger rows (it is the
   was-open-at-death set the fold intersects with) and never contributes one, so a window
   the ledger holds **no row at all** for can be emitted by neither path — its unknown cwd
   cannot change the answer, and it is dropped rather than bailed on, even on a server the
   ledger does tie to this cwd. Only a window with a `resume` row and no `open` row is
   genuinely unknown-but-live.
2. **Missing `.sock` companion** (`exit 4` / `return 2`). The filename only *hashes* the
   socket, so the companion is the only way back to the socket path — without it neither
   the liveness probe nor that ledger join can run. It defers where the probe would have
   run: a candidate row in this cwd, or the sidecar of a ledger server named for this cwd.
   The legacy join then degrades to the pid alone, which still carries the inertness test
   on the coarser `(server_pid, window_id)` key.
3. **A ledger server with no sidecar at all** (`exit 4`). The ledger names a (socket, pid)
   for the queried cwd that `live/` cannot see — a crash at launch, where `sl_open` writes
   the row and the follow-up `_sl_snapshot` liveness query then fails. The ledger path
   offers all of that server's windows, so the sidecars genuinely cannot answer. This one
   is **not** a migration target: writing a sidecar for such a server would invent
   membership and silently convert the deferral into "no drop".

**Measured on a real state dir** (246 sidecars / 1650 ledger lines before `sl_prune`'s
reachability keep set landed, 19 / 272 after — the split below is identical either way, so
the residual is not an artefact of an unpruned dir), over all 47 distinct ledger cwds, fast
path against the ledger path (`AMUX_PENDING_NO_FAST=1`) — **zero disagreements** in every
row:

| state | answered from sidecars | deferred |
|---|---|---|
| bail on sight (before the scoping) | 0 | 47 |
| scoped to the queried cwd | 23 | 24 |
| scoped, plus the inertness test | 44 | 3 |

**Timing** (`dropped --pending <cwd>`, same dir): a cwd that newly answers went
**153ms → 57ms**; the ledger path it used to fall through to costs 113ms on its own.

**What is left, and what would unlock it.** All 3 remaining cwds bail on condition 1's
placement half — one long-lived shared tmux server whose sidecar carries cwd-unknown lines
that the ledger *does* place in the queried cwd. Placement cannot rule those out and
inertness does not apply (the rows exist), so the next narrowing has to ask whether the
ledger row is **emittable** — `agent != "shell"` and a non-empty `resume_cmd`, the two
tests the ledger path applies to its own rows. Both facts live on rows this single pass
already reads, but `resume_cmd` sits on a `resume` row while `agent` sits on the `open`
row, so it means joining two rows per window inside the scan. Revisit when that residual
cost is worth 3 cwds — or sooner if a real project's dot is measurably slow.

## Notes click target can misland if a sibling pane closes mid-prompt

**Status:** deferred — narrow, and the code that would need to change is exactly the code
that avoids a worse hazard (a tmux `command-prompt` template-substitution collision), so
there's no drop-in fix yet.

**Where:** `scripts/notes.sh` → `click` subcommand, the `_cg` target build
(`#{window_id}.#{pane_index}`).

**What:** `pane_index` is positional *within its window*. If another pane in that window
closes while the `command-prompt` (opened by this same click) is still open, tmux
renumbers the survivors, so `_cg` can end up naming a different pane by the time the
prompt's answer runs the deferred `set-option @amux_note_rawN` — the note lands on a
neighbouring pane instead of the one actually clicked. This is the only failure mode in
the notes feature that fails **open** (silently mislands data) rather than failing closed
or loud.

**Why it's fine today:** agentmux agent windows are single-pane by construction — nothing
ever splits one — so there is no sibling pane that could close and trigger a renumber.

**Why there's no queued fix:** the obvious alternative, `#{pane_id}` (`%N`), is *stable*
across renumbering, but it collides with `command-prompt`'s own template substitution
(`%1`-`%9` are replaced by the typed response — this is the exact hazard the long comment
above `_cg` in `notes.sh` already documents and the reason `pane_index` was chosen over
it). A real fix needs a target that is both renumber-stable *and* free of that
substitution collision, which hasn't been identified yet.

**Trigger to revisit:** agentmux windows ever gain more than one pane, or a target is found
that is both stable and substitution-safe.

## `notes.sh`'s selftest cleanup can strand one throwaway dir under dash's SIGINT handling

**Status:** accepted, non-blocking — recorded here as the deferred-work register's home for
the tradeoff, not a bug to fix.

**Where:** `scripts/notes.sh` → `NOTES_SELFTEST` block, `_nt_st_cleanup` (see CLAUDE.md's
Selftests "Fourth invariant" for the full reasoning).

**What:** the cleanup trap is deliberately `EXIT`-only. POSIX-sh bash fires its `EXIT` trap
even on an untrapped `SIGINT`, but `dash` (CI's `/bin/sh`) does not — so a Ctrl-C during
`dash scripts/notes.sh` can leave one `/tmp/nt$$` directory behind. This is specific to
dash; `bin/amux`'s own `EXIT`-only selftest trap never strands anything this way, because
`bin/amux` is bash.

**Why it's accepted:** non-destructive (a single throwaway dir, no live state touched), and
the tempting fix — adding `INT TERM` to the trap list — is the one already ruled out: a
POSIX-sh handler that doesn't itself `exit` lets the shell *resume* afterward, so an
`INT TERM EXIT` list runs cleanup twice, and a second run operating on already-restored
values previously `rm -rf`'d the **user's real** `TMUX_TMPDIR` (the Critical that keeps
`INT`/`TERM` off the list for good).

**Trigger to revisit:** none identified — this is expected to stay accepted permanently
unless dash's SIGINT/EXIT-trap semantics change.

## Repo-wide minimum tmux version is documented, not enforced

**Status:** deferred — the README states the requirement; nothing checks it.

**Where:** `README.md` Prerequisites; the notes feature (`scripts/notes.sh`'s
`command-prompt -l` usage, `tmux/agentmux.conf`'s format/mouse plumbing).

**What:** the README documents `tmux >= 3.6` (verified against the CHANGES file shipped
with tmux 3.7b: `-l` on `command-prompt` shipped in the section headed
`CHANGES FROM 3.5a TO 3.6`). Nothing in the repo — `install.sh`, a selftest, a runtime
check — verifies the installed tmux actually meets that; a user on an older tmux just
hits the notes feature's silent-failure paths (mitigated by the `command-prompt` fallback
message in `notes.sh`'s `click`, but still discovered at click time, not install time).

**Fix when acted on:** add a version check — e.g. in `install.sh`, or an `amux --doctor`-
style command — comparing `tmux -V` against the documented minimum, and warn (not hard-fail,
since most of agentmux works fine on an older tmux) when it's under 3.6.

**Trigger to revisit:** another feature raises the minimum further, or a user reports
hitting the notes-feature silent-failure mode despite the README already stating the
requirement.

## The status-row click path has no automated guard

`NOTES_SELFTEST` covers everything in `scripts/notes.sh` **except the click itself**. It
invokes `click` with a `/dev/null` client tty on purpose, so `command-prompt` fails fast
instead of hanging a headless run — which means the one path a real click takes is the one
path no tracked test executes.

That matters because the defects that path hides are silent. The worst found during
development: `command-prompt` substitutes *all* occurrences of `%1`–`%9` in its template
with the typed response, and the pane id is `%0`, `%1`, `%2`… so a literal pane id in the
target made every tab except the first silently non-functional — no error, no prompt, and
the default `switch-client` didn't run either. It is fixed (the target is now
`#{window_id}.#{pane_index}`, which contains no user-controlled text and no `%N`), but
nothing would catch a regression of that class.

**It is buildable, and has been built and run — the only open question is the dependency.**
A working `expect`-driven suite covering all eight checks below was written and passed 9/9
across repeated runs, including the framed case. What remains is a decision, not a design
problem.

**The technique**, recorded so it is reconstructible from this file alone:

- Exercising a click needs a *genuinely attached* client, because `#{client_tty}` must
  resolve. `expect`'s `spawn tmux attach` gives one, and the load-bearing step is setting
  the pty's size — `stty rows 30 cols 120 < $spawn_out(slave,name)` — because every
  assertion is positional. `script(1)` is **not** a substitute: it allocates a pty but
  exposes no way to set its size or `TERM`, and no client comes up.
- Inject a click as an SGR mouse press/release pair, 1-based, e.g. row 1 of a 30-line
  client showing four status lines is line 28: `\033[<0;10;28M` then `\033[<0;10;28m`.
- **Assert on `tmux show-options`, never on the rendered screen.** This is what removes the
  need for a VT emulator. Positional claims are *stronger* this way, not weaker: typing
  row-distinct text and reading back which `@amux_note_rawN` it landed in verifies the whole
  click → prompt → commit chain terminated in the right row, which screen-scraping alone
  never shows.
- Derive geometry arithmetically — with the status bar at the bottom of an `H`-row client
  showing `N` status lines, `status-format[0]` is line `H-N+1` and row `K` is `H-N+1+K`.
  Note `#{status_lines}` **does not exist in tmux 3.7b**: it expands to empty, which is
  indistinguishable from a real empty value, so derive `N` as `client_height -
  window_height` instead.

**Two traps that make a harness silently test nothing**, both of which must be hard aborts
rather than comments. First, the binding hardcodes `~/.agentmux/scripts/notes.sh`; on a
dev box that path is a symlink to the *install*, so a harness testing a working tree must
rewrite it and then assert via `list-keys -T root` that the binding really points where it
means to. Second, the `client-attached` hook reaches `update_colors.sh`, which resets
`status 4` back to `status on` for any session lacking `@autoagent 1` — so assert the client
actually renders four status lines *after* attaching, and note the hook is async, so a
measurement taken too early reports the pre-hook value and every later click misses.

**What would unlock landing it:** an accepted **test-only** dependency on `expect`. It ships
at `/usr/bin/expect` on macOS and needs one install line on a Linux CI runner. The
`shellcheck` precedent is the closest existing case — a tool the project requires for
development without it becoming a runtime dependency — with one caveat that does not apply
to a linter: a self-skipping *regression test* stops protecting you wherever it skips, so CI
would have to fail on a
skip rather than pass.

Until then the click path is verified by hand. What to exercise, in priority order: a click
opens a prompt at all (the silent-failure gate); clicking row 2 lands in row 2; `fix #42`
stores raw and re-prefills as `fix #42`, not `fix ##42`; a note containing a comma survives
a click-then-Enter; a far-right click on an empty row still opens that row's prompt (proves
the `#{p400:…}` padding); window-list clicks still switch windows; Escape cancels without a
message. All seven, plus the framed (`amux --frame`) case, were verified passing against
this implementation.
