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

## A keyboard path to edit a note

**Status:** deferred — clicking already covers writing/editing a note; nothing yet opens
the prompt from the keyboard.

**Where:** `scripts/notes.sh` → `click` subcommand; the binding lives in
`tmux/agentmux.conf`.

**What:** clicking is currently the *only* way to write or edit a note — `prefix N`
toggles which rows are shown, but nothing opens the `note N>` prompt from the keyboard.
Pre-existing since the notes feature shipped, but more noticeable now that the always-on
fourth row puts a note line on screen from launch rather than only after `prefix N`.

**Fix when acted on:** small, and needs no new state — a `bind-key` that runs `notes.sh
click` for a chosen row with `#{client_tty}`, exactly as the mouse binding does. The
prompt, prefill, escaping and render paths are already there and row-agnostic; only the
binding is missing.

**Trigger to revisit:** none identified yet. The open question when picked up is only
which key, and whether it targets row 4 (the always-visible one) or prompts for a row
number.

## A popup to advertise note edit mode — ruled out by tmux, not deferred

**Status:** attempted and reverted (the popup shipped briefly and was taken back out).
Recorded because the idea is an obvious one to re-reach for, and the reason it cannot work
is invisible until you measure it.

**Where:** would live at the `command-prompt` call in `scripts/notes.sh`'s `click` case.

**What:** clicking a note row opens a `command-prompt` on that row. An unnoticed click
therefore reads as a locked interface, which is why the prompt names its exits (see
`_nt_prompt`). The natural next step is a `display-popup` shown *alongside* the prompt as a
passive "you are editing" indicator. **tmux does not permit it.** Measured on tmux 3.7b
driving a real pty client:

- **A live popup takes ALL of the client's input.** With one on screen the command-prompt
  receives nothing, no root-table binding of any kind fires (pane click, status click and
  plain keypress each failed to run their binding), and nothing reaches the pane. A popup
  shown over an open prompt eats the note instead of advertising it — typing `abc` then
  Enter with one up left the note option empty and the text reached neither prompt nor
  shell.
- **`tmux command-prompt` blocks its caller** until the prompt is dismissed, so opening the
  popup on the following line runs only once editing is already over.
- **`display-popup` also blocks its calling command client**, so it can only be opened
  asynchronously (from a binding, or `run-shell -b`).

That leaves popup-*first* as the only workable order, and it costs more than it buys: an
extra keystroke on every note edit, and a lost first character when you type straight away
(the dismissing key is consumed by the popup's `read`). A short auto-dismiss is not a
softer version — it swallows whatever was typed during it instead of consuming one key.

**A liveness proxy trap that cost three wrong answers:** `pgrep` on the popup's own `sleep`
reports orphaned children as alive, and a popup body calling bare `tmux` may resolve a
*different* server than the one under test. Both make a closed popup look open. Use an
option the popup sets on entry and clears from an `EXIT` trap, sanity-check that the proxy
reads "alive" immediately after opening, and drive it from `tests/mouse`'s attach sequence
(the `stty` and settle are load-bearing) rather than a hand-rolled one.

**Trigger to revisit:** tmux gaining a non-modal overlay — one that renders without taking
the client's input. Nothing short of that changes the result; it is tmux's behaviour, not a
shape we failed to find.
