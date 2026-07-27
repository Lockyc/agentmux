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

## `sh test.sh` writes into the REAL session state dir

**Status:** deferred — pre-existing, harmless per run, but it means the suite is not
hermetic and it slowly inflates the state the presence poll has to scan.

**Where:** `bin/amux`'s selftest — the `amux-win0style-selftest-$$` and
`amux-ensure-selftest-$$` blocks. They launch real agent windows on real tmux servers, and
unlike the neighbouring blocks they never point `AGENTMUX_STATE_DIR` at a throwaway dir.

**What:** `scripts/session_log.sh`'s own selftest is scoped and cleaned up (a `mktemp -d`
`AGENTMUX_STATE_DIR`, **exported** so the real tmux servers it starts inherit it, removed by
its EXIT trap), and two of the amux blocks do the same (`_rstate`, `_ln_state`). The two
named above do not, so every `sl_open` they trigger lands in the user's real state dir.
Measured over one `sh test.sh`: `~/.local/state/agentmux/sessions.jsonl` +2 lines and
`live/` +4 entries, all naming `/private/tmp/amuxtest-<pid>/…` sockets.

**Why it matters:** the suite mutates production state, so a test run is not repeatable
against a clean baseline and cannot be run on a machine you care about without side
effects. The residue is also the input to `sl_dropped`'s per-server liveness sweep, so it
is not inert — every stale server left behind is one more `_sl_server_live` probe on the
slow path.

**Fix when we act on it:** export one `mktemp -d` `AGENTMUX_STATE_DIR` from `test.sh` for
the whole run and delete it at the end, so every selftest *and* every process any of them
spawns resolves to a throwaway dir by default rather than each block remembering to scope
itself. Then assert it: capture `wc -l` of the real ledger before and after a full run and
fail if it moved.

**Trigger to revisit:** the real state dir grows visibly from test runs, or someone needs a
repeatable-from-clean test baseline.

## `--pending` still defers to the ledger on a real state dir

**Status:** deferred — the `--pending` fast path is correct today (it defers rather than
guesses) and `migrate` has drained everything it may soundly touch, but the speedup is
still not realised: a small unenrichable residue keeps every poll on the ledger path.

**Where:** `<state>/live/*.windows` + their `.sock` companions, produced by `_sl_snapshot`;
consumed by `_sl_pending_fast` in `scripts/session_log.sh`.

**What — THREE independent conditions, each of which alone forces a deferral.** They are
checked in this order, and the first one hides the ones after it, which is what made this
look like a single shape-only problem:

1. **Legacy line shape** (`exit 3`). The current shape is 4 tab-separated fields (window
   id, cwd, agent, resumable); sidecars written before the enrichment change carry a bare
   window id per line. `_sl_pending_fast` treats *any* line with fewer than 4 fields as
   "this server's cwds are unknown" and bails for the **whole query** — the bail is global,
   not per-sidecar, so one legacy line anywhere in `live/` sends every poll to the ledger.
2. **Missing `.sock` companion** (`exit 4` / `return 2`). The filename only *hashes* the
   socket, so the companion is the only way back to the socket path — without it neither
   the liveness probe nor the ledger join can run.
3. **A ledger server with no sidecar at all** (`exit 4`). The ledger names a (socket, pid)
   for the queried cwd that `live/` cannot see — a crash at launch, where `sl_open` writes
   the row and the follow-up `_sl_snapshot` liveness query then fails. The ledger path
   offers all of that server's windows, so the sidecars genuinely cannot answer. This one
   is **not** a migration target: writing a sidecar for such a server would invent
   membership and silently convert the deferral into "no drop".

**Measured on a real 227-sidecar / ~1600-line state dir**, classifying all 47 distinct
ledger cwds by which condition fires:

| state | answered from sidecars | bail: legacy (1) | bail: sidecar-less server (2/3) |
|---|---|---|---|
| before `migrate` | 0 | 47 | 0 |
| after `migrate` | 0 | 47 | 0 |
| after `migrate`, residue also removed | 23 | 0 | 24 |
| after `migrate` but companions reverted | 0 | 0 | 47 |

Read down the last two rows: the `.sock` backfill is **load-bearing** — revert it and all
47 fall to condition 2 — but it buys nothing on its own while condition 1 still fires. That
is the same "fixing one alone achieves nothing" result as before, now with the third
condition visible behind them.

**Where it stands now.** New sidecars are born correct (both facts are written at event
time), and `session_log.sh migrate` backfills old ones from the ledger: on that dir it took
condition 2 to **zero** (180 companions written) and condition 1 from 205 legacy lines in
142 sidecars to **11 lines in 6 sidecars**. Those 11 are the ones `migrate` deliberately
refuses to touch — their window ids have no `open` row in the ledger (windows created by
hand on a shared tmux server, plus `resume`-only rows left by the test suite), and `migrate`
may only add fields it can source, because a guessed row would be a wrong answer and 2 must
never collapse to 1. Because condition 1 bails globally, those 11 lines keep **every** poll
on the ledger: ~180ms per poll before and after, unchanged. The payoff is real once they
are gone — for a cwd that then answers from sidecars, the same query is **58ms against
138ms** — but it is capped at 23 of 47 cwds by condition 3.

**They do not drain on their own.** All six sidecars belong to servers that are already
dead, and a dead server is never re-snapshotted, so the only exit is `sl_prune` — which
self-gates on `AGENTMUX_LOG_MAX_LINES` (default 2000) and does not run at all while the
ledger sits at ~1600 lines.

**Do NOT just delete the residual sidecars.** It is the tempting one-line unblock and it is
wrong: an **absent** sidecar means "dead server predating this feature → offer ALL its
windows" (`sl_dropped`'s `*` branch), so deleting one converts a server that currently
offers nothing into one that offers every window it ever had. That is precisely the ghost
resurrection the sidecars exist to prevent.

**Fix when we act on it, either:** (a) **narrow the bail** — make a legacy line unanswerable
only for the servers the ledger names *for the queried cwd*, rather than for every query.
Sound on the ledger path's own semantics (a server with no row whose `cwd` matches the
scope can never contribute an offered row, so ignoring its unreadable sidecar cannot
disagree with the ledger); it needs the `.windows` scan to record which files were legacy
and test that in the END block instead of `exit 3` on sight. Or (b) **let `migrate` split
the unenrichable case in two** — a window id with *no* `open` row anywhere in the ledger was
never an amux window, and the ledger fold (which requires an `open`) provably cannot offer
it, so writing it as `<wid><TAB><TAB><TAB>` — the exact bytes `_sl_live_windows` itself
writes for a window with no `@amux_cwd` — cannot disagree with the ledger path; only the
case where an `open` row *exists* but its cwd/agent cannot be read raw (JSON-escaped) must
stay legacy. (a) fixes it for every state dir including future residue; (b) keeps the hot
path untouched. Neither lifts condition 3, which caps the win at roughly half the cwds.

**Trigger to revisit:** count conditions 1 and 2, over *every* line (the real code tests
every line, not just the first) —

```sh
awk -F'\t' '
  BEGIN { for (i = 1; i < ARGC; i++) { f = ARGV[i]; s = ""
            if ((getline s < (f ".sock")) <= 0 || s == "") nosock++; close(f ".sock") } }
  NF < 4 { legacy++; badf[FILENAME] = 1 }
  END { n = 0; for (f in badf) n++
        printf "legacy lines=%d in %d sidecars; sidecars with no .sock=%d of %d\n",
               legacy + 0, n, nosock + 0, ARGC - 1 }
' ~/.local/state/agentmux/live/*.windows
```

Anything but `legacy lines=0 … no .sock=0` means `--pending` is still paying the ledger
price. Run `session_log.sh migrate` first (it is idempotent); if the numbers do not move,
what is left is unenrichable and one of the two fixes above is the answer. Condition 3 has
no on-disk counter — it is per-cwd, and shows up as `_sl_pending_fast` returning 2 with no
legacy line and no missing companion.
