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
circulation (`@Mitchellh3`) does not resolve; the cookie-rotation warning `yt-dlp` prints is
noise, the subtitles still land. The ledger's last entry carries the as-of date for
everything below it.

What *is* agent-fetchable, for the next status check (so it starts from the ledger below,
not from a fresh web search): `mitchellh.com/writing/superlogical`, `superlogical.com`,
press coverage (The Register, InfoWorld, XenoSpectrum's 2026-08-01 architecture write-up),
and Hacker News through `hn.algolia.com/api/v1/items/<id>` (`search_by_date?query=superlogical
&tags=story` lists new mirrors) — the site itself rate-limits. **The X posts are readable
through the Mastodon API, not the mirror pages**: `hachyderm.io/@mitchellh.rss` and the
`/@mitchellh/<id>` pages hang up, but `curl` with a browser user-agent against
`hachyderm.io/api/v1/accounts/lookup?acct=mitchellh` → `/api/v1/accounts/<id>/statuses`
returns the cross-posted text, and each status's `media_attachments[].url` (on
`media.hachyderm.io`) serves the attached charts, which carry no alt text and must be read
as images. That route is how the 2026-09-02 numbers below were captured.

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
  company sells is the control plane, not the wire format — and, per the 2026-09-02 server
  devlog in the ledger, not the server either: that is self-hosted.
- **Feature velocity is an explicit part of the argument**, and tmux's lack of kitty
  graphics is the case study Hashimoto uses for it.

Treat all of the above as design intent, not a shipped contract — nothing exists to adopt
yet. The ledger below is the record of what has and hasn't happened; append to it rather
than re-deriving the state from the web.

### Status ledger

- **2026-07-29** — company announced (`mitchellh.com/writing/superlogical`); the beta
  waitlist opens at `superlogical.com`. Co-founders: Jack Pearkes (HashiCorp's first
  employee), Alasdair Monk, Hector Simpson. US$10M seed led by Notable Capital with Amplify
  Partners; angels include Patrick Collison, Tobi Lütke, Aaron Levie, Guillermo Rauch and
  Armon Dadgar. This bears on the paid-product point in *What this changes here*: it is a
  venture-scale play, so the paid layer is the lock-in risk, as assumed there — which layer
  that is was narrowed on 2026-09-02, below.
- **2026-07-30 → 08-01** — the architecture devlog and X thread transcribed above.
- **2026-08-28** (X; the Hacker News mirror *Basic Superlogical Demo* is dated 08-30, and a
  YouTube upload of the same three minutes, titled *Superlogical Pre-Alpha Demo*, followed
  on 09-02) — first public demo: the macOS app, basic functionality only, pitched on speed.
  What it shows: a sub-half-second cold launch into an interactive session, and the same
  after quitting the client and reopening it against several live workloads (btop, htop,
  a counter that kept counting while the client was closed); named sessions ("work"),
  created and switched from the client; **native scrolling with a native scroll bar**, the
  client-owns-the-viewport point made visible; vertical tabs exist alongside horizontal.
  The server in the demo is local. Hashimoto's clarifications alongside it: not macOS-only;
  the web client is "very functional" and gets its own demo later; which platforms are
  stable enough for the *initial* public release is still undecided; and (08-30) "all the
  terminal-specific work is going into libghostty so everyone can benefit, e.g. the
  terminal binary snapshot."
- **2026-09-02** — *Superlogical Server Memory Optimizations Overview* (X post with four
  charts + an 11-minute devlog, YouTube `T5gV6anSt-4`). Two things it settles:
  - **The server is self-hosted, not a service.** Hashimoto's words: "when I say server,
    it's a fully self-hosted thing. It's not a service. It's built into the Mac app" — a
    fresh install starts a local server invisibly, and the same server binary "runs
    anywhere", Linux included. The stated vision is a server on every machine, host and
    pod you have. So the paid layer is the control plane (accounts, sharing, remote
    resolution), not the thing the PTYs run in; the *What this changes here* bullet on
    lock-in is updated accordingly.
  - **Benchmarks exist, and they are about memory at agent scale.** The scale argument:
    agents spawn terminals and attach as clients in numbers no multiplexer was designed
    for, so the target is "hundreds of people, hundreds of thousands of agents". Numbers
    (macOS 26.6.2, Apple M4 Max, `phys_footprint`; zellij "default" is out-of-the-box,
    "plugin-free" removes all plugins; lower is better):

    | Measure | tmux 3.5a | Superlogical | zellij 0.45.0 plugin-free | zellij 0.45.0 default |
    | --- | --- | --- | --- | --- |
    | Server start, one session | 2.50 MiB | 10.6 MiB | 35.3 MiB | 53.6 MiB |
    | Per empty 80×24 terminal | 15 KiB | 68 KiB | 2.30 MiB | 7.88 MiB |
    | Per 80×24 terminal filled with 10,000 lines | 4.89 MiB | 407 KiB | 22.7 MiB | — |
    | Per client connection, 50 filled terminals | 157 KiB | 85 KiB | 21.7 MiB | 1.56 GiB |

    Hashimoto's own reading: tmux's empty states are "excellent" and he expects to match
    them; Superlogical wins once terminals have content or clients attach; zellij's
    per-client cost comes from its default tab/status bar being wasm plugins instantiated
    per tab, one runtime each, and not reclaimed on close. The mechanisms behind the
    Superlogical column, because two of them are libghostty capabilities rather than
    server ones:
    - **Terminal parking.** A terminal idle for 60 s on *PTY read* (typing into it does
      not count) has its entire emulator state — screen, scrollback, modes — written to
      disk as an encrypted **binary snapshot**, and is then kept alive only by a
      file-descriptor watch. This happens with clients attached: ten idle shells in an
      open app are ten parked terminals. Unparking a 64 MB compressed scrollback is quoted
      at ~200 µs excluding disk, decoded streaming. A client attaching to a parked
      terminal is served the snapshot straight from disk without unparking. The
      snapshot/restore is libghostty's ("the only terminal technology within a multiplexer
      that supports that"), which is the capability the 08-30 reply above says lands
      upstream.
    - **PTY parking.** Throughput comes from one blocking OS thread per PTY (re-verified:
      pooling PTY fds into kqueue/epoll/io_uring costs measurable latency — Ghostty is the
      reference). At server scale that thread is the expensive part, so an idle *or
      unobserved* PTY is moved into a single evented poller (a 5–10 % throughput cost
      taken only when no human is watching) and moved back on activity.
    - **Client buffer parking.** The per-client pipeline buffers are freed once a client
      goes idle after its initial sync and reallocated on the next burst.

    The follow-ups he named for the same harness: IO throughput, CPU, security (the
    snapshot encryption, "secrets in scrollback"), and GNU screen added as a comparison
    (09-03, on request).
- **2026-09-08** — *Superlogical Remote Sessions Pre-Alpha Demo* (X post + a 6-minute
  YouTube video, `PdwTjSBW6Y8`; transcript pulled the same way as the others). The first
  look at the remote path, and it answers the `amux @host` question more sharply than the
  09-02 "runs anywhere" line did:
  - **The server replaces sshd, it does not tunnel through it.** The multiplexer server is
    named **Rex** in the demo. Adding a remote host (from the client's command palette) makes
    the server perform "a full SSH-style system login" — it shows up in `who`, the login
    shell and per-user limits apply — and Hashimoto runs the demo VPS "with no SSH on this
    machine at all". Identity comes from the transport: the demo connects over Tailscale and
    `whoami` reports the Tailscale identity, the hops taken, and the user being acted as; a
    server-side mapping decides who may act as whom (root included), and pre-existing SSH
    keys are honoured as a method.
  - **One connection, many terminals.** Splits on the remote host ride the same connection.
    Every new session gets a generated two-word name (`drifting-cedar`), renamable; sessions
    and their kill propagate to every attached client at once, and quitting and reopening the
    client lands back in the last session, local or remote.
  - **Mosh-shaped transport, details withheld.** "A lot of the architectural similarities as
    Mosh", "not everything Mosh does", explicitly not ready to describe the protocol or
    transport. The pitch is a cross-country server that feels local.
  - **A CLI is injected into every session**, local and remote (`whoami`, session create /
    kill by id); and a **go-to-directory** palette action (⌘⇧G) opens a new terminal in a
    chosen directory, with the directory listing served over the remote connection too — the
    mechanism is deferred to a future architecture devlog. The stated design rule is that
    everything local works remote and vice versa.
- **As of 2026-09-10** — still waitlist-only. (Re-checked that day against every route named
  at the top of this file — Mastodon statuses, the YouTube channel listing, `mitchellh.com/writing`,
  HN by date, `superlogical.com`: nothing Superlogical since the 09-08 remote demo above.)
  No public code, protocol spec, license, price or release date; the only published numbers
  are the memory set above, and the remote transport and auth model are shown but not
  specified.
  `superlogical.com`'s signup copy promises notice of the beta "and any OSS releases along
  the way", so an open-source drop before the beta is on their roadmap, undated. The unlock
  named under *Not yet* (a published protocol or client) has not fired.

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
  is open, the client half is in libghostty, and (2026-09-02) the server is self-hosted
  and runs on Linux, so the lock-in risk is narrower than first assumed — the control
  plane, not the session host — and a seam contains it either way. A self-hosted server on
  your own remote host is also exactly the shape `amux @host` already assumes, which is why the seam,
  not a rewrite, is the right investment. The 2026-09-08 remote demo sharpens what the seam has
  to own: Superlogical's server *is* the login (no sshd on the host, identity from the transport),
  so remote resolution is a backend's concern, not an ssh hop amux composes in front of one —
  `amux @host`'s ssh assumption belongs behind the seam, not above it.
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

That is cheap for warden specifically — in fact free. The devlog *Libghostty Kitty
Graphics Protocol Support* describes a ~270-line PR against **libghostty-vt**, the
standalone VT library: PNG decoding as an optional runtime-swappable `sys` callback so it
keeps its zero-runtime-dependency property, direct-RGB working without it, a conservative
default image budget for embedders, and file/shared-memory transfer mediums opt-in. Those
are libghostty-vt's terms for an embedder writing its own renderer, and **they are not
warden's**: warden embeds Ghostty's *surface* API, which has rendered kitty graphics all
along. Measured 2026-09-04 against warden's pinned build — a kitty escape written to a
warden tab renders inline for PNG and direct RGB with no warden code and no pin move. The
out-of-band surface is a warden pane, with no tmux involvement at all. Detail:
[warden's `docs/native-splits-direction.md`](https://github.com/lockyc/warden/blob/main/docs/native-splits-direction.md).

**`allow-passthrough` is now uniform across all three sockets**, `term.conf` included. That
buys transit, not managed images: tmux's grid does not track that a pixel region is
occupied, so text overdraws an image and a scroll or redraw loses it. It is parity plus
one-shot viewing for non-agent tooling, and it is deliberately not an image story — which
is why the out-of-band conclusion above stands independent of it.
