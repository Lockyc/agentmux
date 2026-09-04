---
type: decision
links:
  - rel: part-of
    to: CLAUDE.md
    note: the architecture-direction record CLAUDE.md's Layout table points into
---

# Multiplexer direction — why amux stops being the terminal in the middle

Durable record of the architectural direction, and the external evidence behind it.
Start here before proposing a change to the frame layer, the socket/nesting model, or
anything that would add a fourth tmux layer or a second session backend.

**Transcribed, not linked, on purpose.** The primary sources are a YouTube channel and
X threads. Agent web-fetch tooling cannot read either (YouTube returns the SPA footer;
`x.com` fails TLS host verification), so a link here would be a dead end for the next
agent exactly as it was for this one. Video transcripts were pulled with `yt-dlp
--write-auto-subs` from channel `UC0gjVbm7HY5GzDTo5NbQruA` — note the handle in
circulation (`@Mitchellh3`) does not resolve. Facts below are as of 2026-09-04.

## What Superlogical is doing

Superlogical (Mitchell Hashimoto, announced 2026-07-29) is building a server-side
terminal multiplexer on libghostty. The parts that bear on amux, from the
*Superlogical Terminal Multiplexer High-Level Architecture* devlog:

- **No emulator in the middle.** A traditional multiplexer sits between the terminal
  emulator and the PTY, so terminal bytes are parsed twice and screen state is
  materialized twice. Superlogical's server owns the authoritative session state and
  **tees raw PTY bytes to every client**, rather than sending screen diffs the way
  tmux/zellij/screen do. Clients parse independently — "synchronized distributed finite
  state machines" — so a slow server does not slow a client's rendering, and a
  miscompiling client corrupts only its own view, never the authority.
- **Attach is a snapshot frame, then the raw stream.** On connect the server pauses PTY
  processing, sends a custom binary protocol frame carrying just enough state to render
  (visible screen, dimensions, cursor/mouse), then a `ready` frame; the client is
  interactive at that point. Scrollback streams in afterwards, newest-to-oldest, showing
  a loading state until it lands.
- **Input is serialized to the authority** — one writer, many readers.
- **The client owns the viewport.** Per-client scroll and selection. tmux's shared
  scroll across attached clients is called out by name as the thing this fixes.
- **Splits are native and one-to-one with a PTY.** Each split is a native tab / window /
  split with **its own connection**; there is deliberately no multiplexing *within* a
  window. Native apps ship for macOS/iOS, web and mobile.
- **A compatibility mode is kept, not avoided.** For a terminal that does not speak the
  protocol, Superlogical puts a libghostty terminal in the middle and accepts that this
  is "architecturally identical" to a traditional multiplexer.
- **The binary protocol is open.** "If it's not libghostty, it's still a binary protocol
  anyone can parse," and it lives predominantly in MIT-licensed libghostty. What the
  company sells is the hosted server and control plane, not the wire format.
- **Feature velocity is an explicit part of the argument**, and tmux's lack of kitty
  graphics is the case study Hashimoto uses for it.

No public code, protocol spec, license, price or date exists yet. Treat all of the above
as design intent, not a shipped contract.

## What this changes here

The direction is **not** "replace tmux with something". It is: *reduce the number of
terminal emulators between the host client and each PTY.* Today a framed agent is two
(frame + agent); an unframed one is one; Superlogical's native path is zero.

That reframing settles several things that were previously arguable:

- **The frame layer stops being warden's path.** warden already embeds one libghostty
  surface per PTY behind its `TerminalSurface` seam, which is the same design
  Superlogical describes for splits — so warden's own native splits replace the frame's
  fixed two-pane layout, and nesting drops 2 → 1 for local use. Every invariant of the
  form *"re-assert this terminal feature on the frame socket too"* (`extkeys`, `sync`,
  `hyperlinks`, `allow-passthrough`, the per-layer OSC 777 wrap counted by
  `_tmux_nest_depth`, and `bin/amux`'s re-assertion on every `--frame` because that
  server never re-reads its `-f` file) stops applying to that path.
- **`--frame` is kept, not deleted.** It is amux's compatibility mode — standalone
  terminals, `amux @host` over ssh, and non-macOS — and Superlogical ships the same
  concession for the same reason. Deleting it to "finish the migration" would trade a
  supported public surface for tidiness; the no-legacy-hangers-on rule does not reach a
  path that still has its own users.
- **A second session backend needs a seam before it needs an implementation.** amux's
  durable assets — config, agent adapters, the session ledger, restore, fork, remote
  resolution — are not tmux-specific, but they currently assume tmux everywhere. The
  seam is what lets `zmx` or Superlogical's protocol drop in as a backend rather than
  force a rewrite, and it is cheapest to build now, while tmux is the only implementation.
  This is also the whole of the answer to Superlogical being a paid product: the protocol
  is open and the client half is in libghostty, so the lock-in risk is the hosted server,
  which a seam contains.
- **Status rows and notes are chrome painted into a terminal grid.** In a client-owns-
  the-viewport model that chrome belongs to the client, which is where warden's sidebar,
  tab-row dots and presence indicators already live. Migrating it is the expensive half
  of removing the agent tmux layer, and is what makes that layer removable at all.

**Not yet:** removing the agent tmux layer. It is blocked on the chrome migration above
and on a backend that provides the ledger's open/close events; revisit once the seam
exists and warden renders at least the note row. Nothing here argues for adopting
Superlogical — there is no artifact to adopt. The unlock is a published protocol or
client.

## Inline images are not a tmux problem

Recorded because the wrong fix looks right: the visible symptom is "images don't render
in an agent pane", the adjacent code is tmux terminal-features, and adding more of them
is both plausible and useless.

**Claude Code cannot display inline images in any terminal, multiplexed or not.** Three
of the four layers are closed inside the agent, all upstream of tmux: the markdown
renderer sanitizes OSC 1337 / APC graphics out of model and tool output; Bash tool stdout
is captured as text and never reaches the PTY; and a direct PTY write is overwritten by
the TUI's alternate-screen repaint, which has no row accounting for image height. Both
upstream issues (anthropics/claude-code#36476, #54546) are closed as duplicates with no
fix. Reported workarounds either flicker at 1 Hz rewriting base64 forever or, in the
scroll-region case, corrupt terminal state permanently.

So tmux is the *last* layer and the only open one, and `allow-passthrough` plus kitty
Unicode placeholders is necessary-but-not-sufficient — it governs images from other
programs (yazi, chafa, plotting tools) in a pane, never Claude Code's own output. The
only shape that works for agent-produced images is **out-of-band**: render into a surface
the agent's TUI does not own.

That is now cheap for warden specifically: libghostty gained kitty graphics protocol
support (~270-line PR, per the *Libghostty Kitty Graphics Protocol Support* devlog),
with PNG decoding as an optional runtime-swappable `sys` callback so libghostty keeps its
zero-runtime-dependency property, direct-RGB working without it, a conservative default
image budget for embedders, and file/shared-memory transfer mediums opt-in. warden embeds
libghostty, so the out-of-band surface is a warden pane, with no tmux involvement at all.

**Open, unrelated to the above:** `tmux/term.conf` has no `allow-passthrough on`, unlike
`frame.conf` and `agentmux.conf`. That is a genuine gap for non-agent image tooling in
the scratch pane.
