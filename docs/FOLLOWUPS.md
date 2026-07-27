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

## Most sidecars on disk are still the legacy single-field shape

**Status:** deferred — the `--pending` fast path is correct today (it defers rather than
guesses), but its speedup is not yet realised in practice.

**Where:** `<state>/live/*.windows`, produced by `_sl_snapshot`; consumed by
`_sl_pending_fast` in `scripts/session_log.sh`.

**What:** sidecars written before the enrichment change carry a bare window id per line;
the current shape is 4 tab-separated fields (window id, cwd, agent, resumable). The fast
path treats *any* line with fewer than 4 fields as "this server's cwds are unknown" and
returns 2 (cannot answer) for the WHOLE query — one legacy sidecar anywhere in `live/`
sends every poll to the ledger. Measured on a working machine: 143 of 222 sidecars were
legacy, so the fast path never actually answered a single poll.

**Why it matters:** the fast path exists because the ledger fold is warden's hot loop —
one `--pending` poll per session-less tab every few seconds. Measured against a real state
dir: ~145ms per poll through the ledger versus ~30-45ms answered from sidecars. Until the
legacy shape drains, every poll pays the ledger price and the work is invisible.

**Fix when we act on it, either:** (a) let it drain naturally — a legacy sidecar is
rewritten in the enriched shape by the next `_sl_snapshot` for that server, and `sl_prune`
deletes the ones whose pid has left the ledger, so the population turns over within the
retention window; or (b) a one-shot enrichment migration that rewrites/deletes the legacy
files up front. (b) is only worth it if the drain is measured to be slow — a legacy file
belongs to a server that is usually already dead, and a dead server is never re-snapshotted,
so those specific files only leave via `sl_prune`.

**Trigger to revisit:** count them —
`awk -F'\t' 'FNR==1 && NF<4 {n++} END{print n+0}' ~/.local/state/agentmux/live/*.windows`.
If that is still a large fraction after a couple of retention windows, the natural drain
is not happening and (b) is the answer.
