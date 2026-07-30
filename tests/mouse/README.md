---
type: reference
links:
  - rel: part-of
    to: CLAUDE.md
    note: the mouse-click suite CLAUDE.md's Layout and Selftests sections point into
---
# tests/mouse — the status-bar click suite

End-to-end verification that **real mouse clicks on the tmux status bar** drive the
notes feature: `expect` drives a genuinely attached pty client, injects SGR mouse
events, and asserts on tmux's own option values.

It exists because `scripts/notes.sh`'s `NOTES_SELFTEST` covers everything **except
the click path** — it deliberately invokes `click` with a `/dev/null` client tty so
`command-prompt` fails fast instead of hanging a headless run. So the one path a
real click takes is the one path no other test executes, and the defects that path
hides are silent. The worst example: `command-prompt` substitutes *all* occurrences
of `%1`–`%9` in its template with the typed response, and pane ids are `%0`, `%1`,
`%2`… so a literal pane id in the target made every tab except the first silently
non-functional — no error, no prompt, and the default `switch-client` didn't run
either. The fix (`#{window_id}.#{pane_index}`, which contains no `%N`) is what
tests 1–9 running on `%1` rather than `%0` verify.

## Running it

```bash
bash tests/mouse/run.sh                       # from any cwd; no arguments
AMUX_MOUSE_VERBOSE=1 bash tests/mouse/run.sh  # print every assertion, not just failures
AMUX_MOUSE_BREAK=<guard> bash tests/mouse/run.sh   # negative-test a guard (below)
```

`bash test.sh` runs it as the last aggregate check. It is **slower than the other
selftests — ~1 minute** — because it drives real pty clients and must settle between
clicks (see *Synchronisation*), so prefer running it directly while iterating.

Output: a `[PASS]/[FAIL]` line per check plus a table; exit 0 only if all 11 pass.
Full pty transcripts land in `tests/mouse/last-run/` (generated, gitignored).

## Dependencies

`expect` and `tmux` — `expect` is a **test-only** dependency in the same sense as
`shellcheck`: needed to develop agentmux, never to run it. The runtime dependencies
are still only `toml2json` + `jq`. `expect` ships at `/usr/bin/expect` on macOS and
is one apt package on Linux.

**tmux must be >= 3.6.** The suite clicks through `scripts/notes.sh`'s `click` case,
which uses `command-prompt -l` — added in tmux 3.6 (README Prerequisites; verified
against tmux's own `CHANGES`, section "CHANGES FROM 3.5a TO 3.6") — so an older tmux
can't run it at all. `run.sh`'s preflight and `test.sh`'s classification of this block
both parse `tmux -V` and compare against that floor via the single shared
`scripts/tmux_version.sh` (its header documents the parse: a letter suffix like
`3.7b` is a patch release *above* that minor, and an unparseable version string is
treated as capable rather than blocked, since it's far more likely a bleeding-edge
build than an ancient one).

`test.sh` skips this check with a note when `expect`/`tmux` is missing, **or** when an
installed tmux is below 3.6 (the message names the version found) — **except** under
`AGENTMUX_REQUIRE_MOUSE_TESTS=1` (set by CI), where either condition fails the build
instead. A self-skipping *regression test* silently stops protecting you wherever it
skips, unlike an advisory linter, so CI must not be able to pass by skipping it — which
is also why CI's workflow builds tmux from source when the packaged version lags,
rather than relying on apt to already be new enough.

## What it covers

| # | Check |
| --- | --- |
| pre | Five status lines actually render; the row→screen-line arithmetic, verified by clicking (rows 1-3 in notes mode, row 4 in summary mode) |
| 1 | THE RETIREMENT: a click on a summary row (1-3) while notes mode is off is inert — no prompt, no mode flip, no note written |
| 2 | Row 4 — the always-on note line — is the live click target in summary mode, and never touches the mode flag |
| 3 | Once notes mode is on, rows 1-3 click and edit exactly as before (the retirement removed only the mode-entering side effect) |
| 4 | Row mapping — a click on row 2 lands in row 2 |
| 5 | `#` round-trip: stored raw, doubled for display, re-prefilled raw (not `##`) |
| 6 | A note containing a comma survives the prefill round-trip (`command-prompt -l`) |
| 7 | `#{p400:…}` padding makes an empty row clickable across the full width |
| 8 | The `if -F` else branch: window-list clicks still switch windows |
| 9 | Escape cancels, leaving the note and the mode flag intact |
| 10 | The framed (`amux --frame`) case: a click on rows 1, 2, and 4 traverses the outer tmux to the inner server |

## How it works

- **`run.sh`** builds the isolated world (both servers, the path-rewritten confs)
  and asserts the setup guards, then runs the two drivers and prints the table.
- **`main.exp`** — preflight plus checks 1–9, on a pty attached *directly* to the
  agent server.
- **`frame.exp`** — check 10, on a pty attached to the *frame* server, whose pane
  runs the agent client, so every click really traverses both layers.
- **`lib.tcl`** — shared driver: clicks, prompt waits, option polling, bookkeeping,
  plus the `reset_to_summary`/`notes_mode` fixtures that put the pane into a known
  mode before a check clicks rows 1-3 (click-inert in summary mode since the
  retirement).

**A genuinely attached client is required** — the binding's `#{client_tty}` only
resolves for one. `expect`'s `spawn tmux attach` provides it, and the load-bearing
step is sizing the pty with `stty rows N cols M < $spawn_out(slave,name)`, because
every assertion is positional. `script(1)` is **not** a substitute: it allocates a
pty but exposes no way to set its size or `TERM`, and no client comes up.

**Clicks are injected as SGR press/release pairs**, 1-based coordinates:
`ESC [ < 0 ; col ; row M` then `… m`.

**Assertions read `tmux show-options`, never the rendered screen.** That is what
removes any need for a VT emulator, and it is a *stronger* positional check: typing
row-distinct text and reading back which `@amux_note_rawN` it landed in proves the
whole click → prompt → commit chain terminated in the right row, where a screen read
only shows that some bytes appeared on some line. The pty stream is used only for
what `expect` is actually good at — waiting for the `note N>` prompt's bytes, and
grepping the transcript for a string that must never appear.

**Geometry is arithmetic, then verified by clicking.** With the status bar at the
bottom of an `H`-row client showing `N` status lines, `status-format[0]` sits on line
`H-N+1` and row `K` on `H-N+1+K`; in the framed case add the containing pane's
`#{pane_top}`. `#{status_lines}` **does not exist in tmux 3.7b** — it expands to
empty, indistinguishable from a real empty value — so `N` is derived as
`client_height - window_height`. The preflight then clicks each derived line and
types row-distinct text, so an off-by-one fails loudly instead of passing by luck.
Test 6's window-list column is derived the same way, from the expanded
`#{E:status-left}` and window-entry widths.

**Synchronisation is polled wherever the state is observable** — `waitopt` polls an
option, `wp` waits for the prompt's bytes, `pane_echo` polls `capture-pane` until a
typed token reaches the pane (positive proof that no prompt is open to swallow it).
The one thing polling cannot observe is "tmux has finished repainting after a
command-prompt commit": no option changes and no bytes are promised. `settle`
consumes the pty until it has been quiet for a second, which adapts to load.
`expect`'s `-timeout` takes whole seconds only, which is why a run costs ~1 minute.

## Footguns

**A click sent very soon (~10 ms) after an Enter-commit is silently dropped.** It
presents as "row 1 clicks don't work" and looks exactly like a product defect; it is
the harness racing the repaint. Measured: no prompt at all, three runs out of three,
only for a row clicked immediately after a commit — and a prompt every time after a
`settle`. Keep the settle before every click.

**Two traps make a harness of this shape silently test nothing.** Both are *hard
aborts*, not comments, and both are negative-tested via `AMUX_MOUSE_BREAK` so the
guard is seen to fire rather than merely to exist (`rewrite`, `binding`, `autoagent`,
`render` — each must exit 2 with a loud `ABORT` and still reap):

1. **The wrong-code trap.** The binding hardcodes `~/.agentmux/scripts/notes.sh`,
   which on a dev box symlinks to the *install* — so a harness meaning to test a
   working tree tests the install instead, and reports green for code that isn't the
   code under change. The conf is rewritten to absolute paths under the repo root,
   and the rewrite is asserted against `list-keys -T root`: a textual check on the
   file is not enough, because only the live binding says where a click actually goes.
2. **The no-status-rows trap.** The `client-attached` hook reaches
   `update_colors.sh`, which resets a multi-row `status N` to `status on` for any
   session lacking `@autoagent 1`, and drops it to `status 4` without
   `@amux_note_row 1` (which is what selects five lines over four). The harness
   also sets a third option alongside those two — the session-level `@amux_note4`
   hint default, asked of `notes.sh hint 4` the same way `bin/amux` does at launch
   (CLAUDE.md's row-4 footgun) — but that one doesn't affect the line count: skip
   it and the five status lines still render fine, only check 2's hint assertion
   fails. With one status line none of the note rows exist, every click lands on
   the window list, and the suite passes nothing while looking busy. So the
   preflight asserts five status lines actually *render* on the attached client —
   and the hook is **async**, so a measurement taken the moment a client exists
   reads the pre-hook value and every later click misses.

**A fixture that renders before asserting can validate itself instead of the
product.** `reset_to_summary` used to call `render`, invoking `scripts/notes.sh`'s
`_nt_render` on the pane — the very write check 2 exists to prove `bin/amux`
produces WITHOUT a render. `_nt_render` computes `@amux_note4` from scratch just
like a real render would, so check 2 passed whether or not the product ever
published the launch-time default itself — which is exactly how row 4 shipped
blank (CLAUDE.md's row-4 footgun). `reset_to_summary` now deliberately skips the
render (see its own comment in `lib.tcl`), leaving the pane in the genuinely
un-rendered launch state. What stops this from re-forming is that check 2's
assertion is paired, not single: pane-scope `@amux_note4` must be **unset**
(nothing rendered this pane) *and* the format-chain lookup must still resolve to
the hint (so it can only have come from the session-level default) — a fixture
that renders again makes the first half false, so it fails loudly instead of
quietly re-passing.

**`tmux kill-server` returns before its teardown hooks finish.** Destroying the
windows fires `agentmux.conf`'s `window-unlinked` hook, whose
`run-shell "… session_log.sh …"` children are forked by the *dying* server and
outlive both the `kill-server` call and an immediate `rm -rf` — `session_log.sh` then
`mkdir -p`s `$AGENTMUX_STATE_DIR/live` ~0.3 s later, recreating the directory just
deleted. Cleanup therefore waits for those children (they carry `$WORK` in argv),
deletes, then re-checks. The corollary is why `AGENTMUX_STATE_DIR` is exported
**before any server starts** rather than merely around the tests: those writes happen
at *teardown*, so a state dir scoped any later still lets a throwaway server write
into the real `~/.local/state/agentmux/`.

## Isolation

A dev box runs real agentmux sessions, so every run is confined: both servers are
created under a throwaway `TMUX_TMPDIR=/tmp/amuxmt$$` with `$$`-unique `-L` labels
(never the shared `/tmp/tmux-<uid>/`, and `run.sh` refuses to run if `$WORK` would be
it), `AGENTMUX_STATE_DIR` is scoped before they start, and an `EXIT` trap kills both
servers and reaps `$WORK` on every path out — including the aborting ones. The path
is deliberately short: a long dir plus a socket name can exceed the 104-char
`AF_UNIX` limit. No tmux command in this suite names a socket other than its own.
`run.sh` prints the shared-socket count, the real ledger's line count and `live/`
entry count at the end of every run, so a run re-confirms the numbers itself.
