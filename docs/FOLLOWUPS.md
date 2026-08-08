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

## `amux attach <name>` is still an unguarded nesting vector

**Status:** deferred — the same hole `_amux_nested_refuse` closed for a plain launch and
`amux @host` is still open on this one path.

**Where:** `bin/amux` → the `attach <name>` case arm (calls `_amux_attach_by_name`), which
does not call `_amux_nested_refuse` the way the plain-launch and `@host` paths do.

**What:** running `amux attach <name>` from inside an existing tmux nests a second tmux
server's session inside the one you're already in — the exact objection
`_amux_nested_refuse` exists to catch, stacking prefixes and burying one status bar inside
another.

**Why it's fine today:** `attach` is a narrower, more deliberate action than a bare launch —
typed by name, from a specific directory, to reach a specific session — so the accidental
nesting a plain `amux` guards against is less likely here. It's also the one path warden's
GUI may itself invoke from inside a tmux pane it already manages; guarding it without first
checking warden's call sites risks refusing a caller that has a legitimate reason to nest.

**Fix when we act on it:** audit warden's `attach` call sites first — if none run from
inside tmux, add the same `_amux_nested_refuse "attach"` guard `@host` and the plain launch
already carry.

**Trigger to revisit:** warden's call sites are audited, or a user reports a nested `amux
attach` stacking prefixes.

## et's own resumption makes the supervise loop mostly inert

**Status:** deferred — expected behaviour of the `et` transport, not a bug.

**Where:** `scripts/remote_attach.sh` → `_ra_supervise`, paired with `scripts/remote.sh`'s
`_rm_classify_exit` for the `et` transport.

**What:** ET reconnects internally on a dropped link, so `_ra_supervise`'s retry loop only
ever sees an `et` process that has already given up — the holding screen and backoff exist
for exactly that case, but on an `et` host they'll rarely trigger, since ET's own
reconnection usually resolves the drop before agentmux's supervise loop gets a turn.

**Why it's fine today:** the loop is still correct when it does fire (a genuinely
unrecoverable `et` failure still shows the holding screen and retries), and `ssh` — the
default transport — has no equivalent internal resumption, so most hosts exercise the loop
normally.

**Fix when we act on it:** none identified — this isn't a defect to fix, just a case where
two reconnection layers (ET's and agentmux's) stack, and the outer one is mostly silent.

**Trigger to revisit:** `et` hosts become the common case and the double layer causes
confusing double-waits (a user sees ET's own reconnect message, then immediately
agentmux's), at which point the two layers may need to be made aware of each other.

## Multi-hop / jump-host roster scans don't reach a further box

**Status:** deferred — narrow, and the common case (a direct host, or one reached via
`ProxyJump`) already works.

**Where:** `scripts/remote.sh` → `_rm_roster_script` and `_rm_preflight_script`, both of
which run `find` against `roots` on the **target** host named by `ssh =`.

**What:** a host reached via ssh's own `ProxyJump`/`ProxyCommand` to hop through a bastion
works fine — ssh handles the hop transparently, and the scripts still run on the final
target. But a host whose *projects* live on a **further** box (the `[[hosts]]` entry names
box A, but the projects it should search for actually live on box B, reachable only from A)
is not handled: the roster and preflight scripts have no second hop to run.

**Why it's fine today:** every host configured so far names its own projects directly —
"a host's roots are local to that host" holds in practice, and `ProxyJump` already covers
the common bastion-access case.

**Fix when we act on it:** would need either a second-hop `ssh` invocation nested inside the
remote script (its own quoting/escaping burden, layered on the existing
`_rm_shquote`/`_rm_remote_cmd` scheme), or a documented convention that `roots` must be
local to the named host.

**Trigger to revisit:** a host's projects stop being local to it — i.e. someone actually
needs a `[[hosts]]` entry whose roots live on a machine other than the one `ssh =` names.

## warden's remote UI is not built

**Status:** deferred — the building blocks exist and are stable; nothing in warden consumes
them yet.

**Where:** `scripts/remote.sh` → `_rm_roster_json` (roster + liveness, joined on directory)
and the local `--sessions-json` contract (`bin/amux` → `_amux_sessions_json`) that a remote
`amux --sessions-json` call answers over ssh.

**What:** warden has no remote-hosts UI yet — no way to browse a `[[hosts]]` host's projects
or see their liveness from inside warden itself. The contracts a future UI would consume
already exist and are exercised by `scripts/remote.sh`'s own selftest (`REMOTE_SELFTEST=1`):
one remote `--sessions-json` call per host, joined against that host's roster by directory.

**Why it's fine today:** `amux @host` is fully usable from a terminal without any warden
integration — the picker (`_ra_pick`) already renders the same roster+liveness join a
warden UI would.

**Fix when we act on it:** build the warden-side UI against `_rm_roster_json`'s existing
shape. The constraint it must honour: **poll a host once, never once per project** — the
whole reason `_rm_roster_json` joins a single remote `--sessions-json` call against the
roster instead of probing per project (see the CLAUDE.md footgun on host-scoped liveness).
A per-project poll reintroduces the network-round-trip-inside-a-poll-loop cost the local
presence dot was rebuilt to remove.

**Trigger to revisit:** work starts on warden's remote UI.

## `_ra_pick_render` pads project names with a fixed width

**Status:** deferred — cosmetic; no crash, just cramped output.

**Where:** `scripts/remote_attach.sh` → `_ra_pick_render`, the `jq` line padding
`.value.name` to 18 characters (`" " * (18 - (. | length))`).

**What:** a project name at or beyond the 18-character pad width runs straight into the
path column with no separating space. `jq`'s `* (negative number)` on a string yields
`null`, not an error, so the row just renders cramped rather than crashing.

**Why it's fine today:** every project name seen in practice is well under 18 characters
(they're repo basenames); the picker is still fully readable, just visually tight for a
long one.

**Fix when we act on it:** clamp the repeat count to a minimum of 0 (or 1, for a guaranteed
single separating space) before multiplying, e.g. `(18 - (. | length) | if . < 1 then 1 else
. end)`.

**Trigger to revisit:** a real project name reaches 18+ characters and the picker's output
is reported as hard to read.
