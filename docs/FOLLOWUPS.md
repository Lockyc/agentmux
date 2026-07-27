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

## `--pending` still defers to the ledger for the cwds of sidecar-less servers

**Status:** deferred — roughly half the cwds on a real state dir now answer from the
sidecars; the rest defer on a condition that is *not* a migration target and needs its own
design. This is a speed ceiling, never a correctness one: a deferral is the ledger path
answering, which is always right.

**Where:** `<state>/live/*.windows` + their `.sock` companions, produced by `_sl_snapshot`;
consumed by `_sl_pending_fast` in `scripts/session_log.sh`.

**What — THREE independent conditions make a query unanswerable from the sidecars alone,
and every one of them is scoped to the queried cwd** (an unresolvable sidecar belonging to
another project must never suppress the answer here — see the presence-dot footgun in
CLAUDE.md, and the `t6:` selftest block that pins each shape as a pair):

1. **Legacy line shape** (`exit 3`). The current shape is 4 tab-separated fields (window
   id, cwd, agent, resumable); sidecars written before the enrichment change carry a bare
   window id per line, so that window's cwd is unknown. The **ledger** places it, by
   `(socket_path, server_pid, window_id)`, and the `.sock` companion is the join back to
   the socket path. It defers only where the join cannot rule the window out: the ledger
   puts it in *this* cwd, or the ledger does not name it at all **and** names its server
   for this cwd.
2. **Missing `.sock` companion** (`exit 4` / `return 2`). The filename only *hashes* the
   socket, so the companion is the only way back to the socket path — without it neither
   the liveness probe nor that ledger join can run. It defers where the probe would have
   run: a candidate row in this cwd, or the sidecar of a ledger server named for this cwd.
3. **A ledger server with no sidecar at all** (`exit 4`). The ledger names a (socket, pid)
   for the queried cwd that `live/` cannot see — a crash at launch, where `sl_open` writes
   the row and the follow-up `_sl_snapshot` liveness query then fails. The ledger path
   offers all of that server's windows, so the sidecars genuinely cannot answer. This one
   is **not** a migration target: writing a sidecar for such a server would invent
   membership and silently convert the deferral into "no drop".

**Measured on a real 232-sidecar / ~1600-line state dir**, over all 47 distinct ledger
cwds, fast path against the ledger path (`AMUX_PENDING_NO_FAST=1`) — **zero disagreements**
in every row:

| state | answered from sidecars | deferred |
|---|---|---|
| bail on sight (before the scoping) | 0 | 47 |
| scoped to the queried cwd | 23 | 24 |
| scoped, and the legacy residue also deleted | 23 | 24 |

Read the last two rows together: the 11 residual legacy lines now cost **nothing** — the
same 23 cwds answer with or without them, because every one of those windows sits on some
other project's server. What caps the win at 23 is condition 3 alone.

**Timing** (`dropped --pending <cwd>`, same dir): a cwd that answers went **103ms → 37ms**.
A cwd that defers went **~160ms → ~175ms** — a real, accepted regression: scoping means
reading every sidecar and the ledger *before* concluding "cannot answer", where the old
code aborted at the first legacy line it saw. It buys the 37ms case, and it is the case
that grows as residue drains.

**What is left, and why it does not drain.** The 24 deferring cwds all trace to one
long-lived shared tmux server whose sidecar carries hand-created windows the ledger has no
`open` row for. `migrate` deliberately refuses to enrich those (a guessed row would be a
wrong answer), and the server is already dead so it is never re-snapshotted — the only exit
is `sl_prune`, which self-gates on `AGENTMUX_LOG_MAX_LINES` (default 2000) and does not run
while the ledger sits at ~1600 lines.

**Do NOT just delete the residual sidecars.** It is the tempting one-line unblock and it is
wrong: an **absent** sidecar means "dead server predating this feature → offer ALL its
windows" (`sl_dropped`'s `*` branch), so deleting one converts a server that currently
offers nothing into one that offers every window it ever had. That is precisely the ghost
resurrection the sidecars exist to prevent. (It is also now pointless — the table above
shows it changes no answer.)

**Fix when we act on it:** the remaining lever is condition 3, and it is not a sidecar
question — the fast path would have to reproduce what the ledger path does with a
sidecar-less server (treat every window it ever opened as open at death) from a raw scan
rather than the `jq` fold. That is a real design, not a narrowing, and it is only worth it
if the sidecar-less population stops being dominated by one legacy server. A cheaper
half-measure first: have `sl_prune` run on age as well as line count, so dead-server
residue leaves on its own.

**Trigger to revisit:** the answer/defer split, measured directly rather than inferred from
on-disk counts (both remaining conditions are per-cwd, so no file-level counter can see
them) —

```sh
sh - <<'SH'
awk '/^# ---- dispatch ----$/{exit} {print}' scripts/session_log.sh > /tmp/sl.$$
AGENTMUX_SESSION_LOG=1 . /tmp/sl.$$; rm -f /tmp/sl.$$
SD=$HOME/.local/state/agentmux; export AGENTMUX_STATE_DIR="$SD"
jq -r 'select(.cwd)|.cwd' "$SD/sessions.jsonl" | sort -u | while IFS= read -r c; do
  _i=$(_sl_pending_fast "$c"); rc=$?
  s=$(AMUX_PENDING_NO_FAST=1 sl_dropped --pending "$c" | grep -c .)
  printf '%s\t%s\t%s\n' "$rc" "$s" "$c"
done | awk -F'\t' '
  {n++; if ($1==2) d++; else a++
   if (($1==0 && $2!=1) || ($1==1 && $2!=0)) { bad++; print "DISAGREE: " $0 }}
  END { printf "answered=%d deferred=%d of %d; disagreements=%d\n", a+0, d+0, n, bad+0 }'
SH
```

`disagreements=0` is the invariant — anything else is a correctness bug, not a speed one,
and outranks every number beside it. A falling `answered` count means new unenrichable
residue is accumulating; run `session_log.sh migrate` (idempotent) before concluding
anything from it.
