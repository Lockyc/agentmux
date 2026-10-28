---
type: decision
links:
  - rel: part-of
    to: CLAUDE.md
    note: the architecture-direction record CLAUDE.md's Layout table points into
research:
  bears-on: >-
    The zero-emulator direction: warden as the client for Rex sessions, libghostty as its
    terminal, tmux and amux retired. News is anything that moves the unlock in "Not yet: warden
    as a Rex client", changes Rex's API/events/pricing, or changes the libghostty embedding API
    (`ghostty.h`) or the terminal-state pieces (snapshot, OSC 7501) warden consumes.
  sources:
    - name: Superlogical devlog
      check: https://www.superlogical.com/updates/rss.xml
      note: the bare domain 308-redirects to www (curl -L); the Rex docs serve raw Markdown at /rex/docs/<page>.md
    - name: Hashimoto's and Superlogical's X posts
      check: curl -A <browser UA> https://api.fxtwitter.com/2/profile/<mitchellh|superlogical>/statuses (one post, quote included, at /status/<id>)
      note: >-
        x.com fails TLS. X is the primary channel. The hachyderm.io API (browser user-agent,
        /api/v1/accounts/lookup?acct=mitchellh) is only a partial mirror and missed every post
        from 10-11 to 10-15. Charts are media URLs with no alt text, so read them as images.
    - name: Other Superlogical staff on X
      check: the fxtwitter route above, for almonk (Alasdair Monk) and pearkes (Jack Pearkes)
      note: Activity Mode and beta-wave news surfaced through these accounts before the company's
    - name: Hashimoto's blog
      check: https://mitchellh.com/feed.xml
      note: the OSC 7501 rationale and the Ghostty-leaving-GitHub plan were posted here, not on the devlog
    - name: Rex docs
      check: >-
        the page list in https://www.superlogical.com/rex/docs/llms.txt (whole text at
        llms-full.txt); https://www.superlogical.com/rex/docs/search.json?q=attach (also
        q=protocol) shows whether the unlock has been documented
      note: >-
        docs change without a devlog post. The community MCP server
        (superlogical.com/rex/community-mcp, user-scope MCP `superlogical`) carries the beta
        Discord's feedback, #backlog and #changelog. It signs in through a Discord account that
        is in the test program, so an agent can read it only after a human has authenticated it
    - name: Superlogical GitHub org
      check: gh api orgs/superlogical/repos --jq '.[].full_name'
      note: the org exists with no public repos; a first repo is the likely home for code, a protocol spec or a license
    - name: YouTube devlogs
      check: yt-dlp --flat-playlist --playlist-end 5 --print '%(id)s %(title)s' https://www.youtube.com/channel/UC0gjVbm7HY5GzDTo5NbQruA/videos
      note: >-
        the channel's RSS feed (/feeds/videos.xml?channel_id=…) returns 404 with or without a
        browser user-agent, and the page is an SPA; the flat listing gives no upload dates, so
        compare ids against the ledger. Transcripts via yt-dlp --write-auto-subs (the
        cookie-rotation warning is noise). The @Mitchellh3 handle does not resolve.
    - name: Hacker News
      check: https://hn.algolia.com/api/v1/search_by_date?query=superlogical&tags=story (also query=rex, query=OSC 7501)
      note: news.ycombinator.com rate-limits; items via /api/v1/items/<id>
    - name: Ghostty releases
      check: gh api repos/ghostty-org/ghostty/tags --jq '.[:3][].name'
      note: >-
        the GitHub "release" is only the rolling tip; tags carry the versions. warden vendors a
        main commit, not a release, so the main compare below is the source that matters
    - name: libghostty embedding API since warden's vendored commit
      check: >-
        gh api repos/ghostty-org/ghostty/compare/<commit>...main for include/ghostty.h,
        src/apprt/embedded.zig, src/terminal/snapshot/; <commit> is in warden's
        crates/warden-app/vendor/PROVENANCE.md
    - name: libghostty PRs (snapshot, OSC 7501, multiplexer)
      check: gh search prs --repo ghostty-org/ghostty --merged-at '>=<as-of>'
      note: >-
        Ghostty plans to leave GitHub (mitchellh.com, 2026-04-28; destination not yet named),
        keeping a read-only mirror at the current URL. Once it moves, this search goes silent,
        while the tag and compare checks keep working on the mirror. A sudden empty result means
        the project has moved, not that work has stopped
    - name: OSC 7501 in the layers between agent and warden
      check: >-
        gh search issues --repo tmux/tmux 7501 and gh api repos/tmux/tmux/tags; grep 7501 in
        https://raw.githubusercontent.com/anthropics/claude-code/main/CHANGELOG.md and in gh
        release list -R openai/codex
      note: >-
        whether an agent under amux emits at all depends on tmux answering the query and on
        the agent's emit rules (see "Agent status reaches warden from Rex")
    - name: Press
      check: web search "Superlogical Rex" (The Register, InfoWorld, XenoSpectrum have covered it)
---

# Multiplexer direction — warden and Rex replace tmux and amux

Durable record of the architectural direction, and the external evidence behind it.
Start here before proposing a change to the frame layer, the socket/nesting model, or
anything that would add a fourth tmux layer, a second session backend, or new architecture to amux.

**Transcribed, not linked, on purpose.** The primary sources are YouTube videos and X threads,
which agent tooling reads only through the routes in the frontmatter's `research:` watch list,
so a bare link would be a dead end for the next agent. The ledger's last entry carries the as-of
date for everything below it; a status check runs the watch list from there.

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
  Armon Dadgar. It is a venture-scale play, so the paid layer is the lock-in risk; which layer that is was
  narrowed on 2026-09-02, below.
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
    resolution), not the thing the PTYs run in.
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
- **2026-09-14** — *Superlogical Pre-Alpha Demo: CLI* (YouTube `9fcfDF8SBnc`, 7½ minutes;
  cross-posted to X/Mastodon the same day, no HN mirror). The CLI binary is **`rex`**,
  the same name as the server. Its data model, as shown: a **session** holds **windows**
  (tabs), a window holds **blocks**, and each block has a type (`terminal` is the only one
  shown), an id and a label (`shell` is the default label). What the demo does with it:
  - **Create and arrange from outside the client.** `rex` creates a named session running a
    command, adds a labelled block to it (it lands as a split), and **moves** a block relative
    to another ("move nvim below shell") without disturbing the running process; `rex block
    close` and session kill work too. Every change shows up at once on every connected client.
  - **Scripting primitives.** `wait` blocks until a named block's process completes; a
    `--keep-open` flag keeps the finished block on screen (by default it disappears).
  - **Introspection.** `inspect` on a session reports its id, label, focused window, window
    count and **connected clients** (the CLI and the Mac app each count as one); block listing
    and block inspect return ids, types, labels and metadata.
  - **Every block exposes its own methods and events.** A terminal block's `process` method
    returns the child process and, separately, the **foreground process** (a shell running
    nvim reports both), or exit information once it has exited. A per-session **event stream**
    emits client-connected, block size-changed, block-closed, layout-changed and, from the
    terminal block itself, **child-exited**.
  - **More than the GUI exposes.** Per the help output: send input, simulate key presses and
    mouse movement, and capture the screen as text, HTML or other formats. Hashimoto's claim is
    that anything the graphical client does, the CLI does, plus more; he pitches it at editors
    and agent tools.
- **2026-10-05** — *Public testing is beginning* (`superlogical.com/updates/public-testing-beginning`).
  The product is named **Rex** — the server and CLI names from 09-08/09-14 are the product's.
  Invites go to the mailing list in growing waves, the whole list "in less than a month";
  testing is **macOS app only** (it self-hosts its own Rex server and connects to other Rex
  servers). Rex servers already run on Linux and Windows and clients exist for iOS, Linux and
  Windows "at varying stages of readiness", outside the test. ~50 private testers before this.
  Pricing: "Rex is and will always be free" — no account, fully self-hostable, no data seen; the
  Rex clients and servers "are not going to be directly monetized". The commercialization plan
  is unannounced, promised before the stable release, which will be a contact-free download.
  Still no public code, wire-protocol spec or license.
- **2026-10-06** — **OSC 7501, the Program Status Protocol** (spec rev 0.2 at
  `superlogical.com/rex/docs/build/program-status`, rationale at
  `mitchellh.com/writing/program-status-osc7501`). The first *published* protocol, but a terminal
  escape sequence, not the Rex wire protocol: a program reports its own state to the terminal
  over the pty — `OSC 7501 ; state=…:kind=…:app=…:progress=…:msg=<b64> ST`. States `idle` /
  `working` / `done` / `blocked` (`kind=permission|question|auth`) / `error`, plus `clear`; each
  report replaces its record whole; hierarchical `id`s (`build/test`) give a program several
  records at once. `working`/`blocked` drop on process exit or the next OSC 133 A prompt;
  `done`/`error` survive both until the terminal decides the user has seen them. Detection is the
  `OSC 7501 ; ? ST` echo (send `CSI c` after it to avoid a timeout).
  Implemented in Rex and in **libghostty-vt** (ghostty-org/ghostty#14560); the embedding API in
  `ghostty.h` has no action for it, so the Ghostty app ignores it and warden can't see it.
  Proof-of-concept emitters exist (plugins/forks) for Claude Code, Codex, Terraform and Homebrew,
  nothing upstreamed. Hashimoto's pitch is the
  "agentic inbox" — he counts 250+ orchestrators guessing agent state from titles/screens
  (Herdr's 16 Claude Code title-regex rules as the example) — which is exactly what amux's
  probe and warden's attention/presence dots do today. Rex shows it as session-picker
  indicators, spinners/blocked glyphs on unfocused tab headers, and a Lua
  `terminal.program_status_changed` event; a push-to-mobile inbox is planned. Unlike OSC 9/777 it
  is state, not a one-shot event, and the pty carries it over ssh and through containers with no
  socket bridging — though through tmux it still needs passthrough per layer, like OSC 777.
- **2026-10-07** — two X/Mastodon posts, no devlog.
  - **OSC 7501 adoption, 24 h in:** integrated in Amp, Factory, TUIOS and libghostty; "verbal
    support and in-progress PRs" from **Claude Code**, cmux, Codex, Herdr, OpenCode and Pi. A
    Claude Code PR is the emitter amux would otherwise have to write as a hook — nothing has
    shipped in Claude Code yet.
  - **Rex server scalability** (alpha builds; Ubuntu 24.04, 16 CPUs, 64 GiB; two charts, read as
    images): **10,000 active terminals in 3.85 GiB** anonymous RSS (server + all terminals, dash
    shells, 1,000 numbered lines each), **1.16 GiB** once idle 60 s and snapshotted; 1,000
    terminals ≈ 0.4 / 0.14 GiB. Bash instead of dash adds ~423 KiB per shell. Shell-command round
    trip with 1,000 terminals open: median/p99 0.29/0.52 ms with none busy, 1.30/4.50 ms with 10
    busy, 1.58/15.24 ms with 100 busy (`date` every 0.1 s; machine CPU 0.2 / 1.6 / 13.6 %). Target
    is 100,000. Two mechanisms named: a C trampoline that unshares the fd table after fork (Linux
    sizes it to the highest open fd's power of two — 512 KiB per terminal beyond ~5,000), and PTY
    parking now triggering on **2 s** without read activity into a shared epoll thread (the 09-02
    devlog described parking idle-or-unobserved PTYs; this is the concrete threshold). No
    comparison against other multiplexers this time, deliberately.
- **2026-10-09** — status check: no new posts, videos or devlog since 10-07. Recorded here because
  the ledger had missed it: the **Rex user docs are public** at `superlogical.com/rex/docs` (the
  OSC 7501 spec is one page of them; the download itself is behind the invite login). They make
  the 09-14 CLI demo a documented surface:
  - **Self-describing server API.** `rex api list` / `describe` / `call`: named methods
    (`session.create`, `session.view`, `session.new_split`, `block.close`, `*.set_label`, …),
    each carrying a JSON Schema for input and output plus examples, and `--json` dumps the whole
    catalogue "for generating bindings". Blocks expose methods of their own
    (`com.superlogical.terminal.format` captures the screen, plus `.pwd` and `.title`). The CLI
    and Lua (`rex.call`, `rex.session.*`, `rex.on`/`rex.wait`) are both derived from the
    connected server's catalogue. Every id (`session:<uuid>`, `block:<uuid>`) is stable and never
    reused; labels are mutable. Every terminal gets `REX_SESSION`/`REX_BLOCK`/`REX_SERVER` in its
    environment, and `-S <host>` points a command at a remote server.
  - **A published event list.** Session events (`window_*`, `block_created`/`block_closed`,
    `client_connected`/`disconnected`/`connection_changed`, `session_view_changed`); terminal
    events (`child_exited` with exit code, `pwd_changed`, `title_changed`, `bell`,
    `process_changed` with the foreground process, `desktop_notification`, `progress_report`,
    `clipboard_written`, `program_status_changed`/`removed`); server events (`session_created`/
    `destroyed`, `client_joined`/`left`). `rex events --json` streams them as JSON lines.
  - **Scripting contract.** `rex run|split --wait`, `rex wait --for <dur> <block>`, `--keep-open`,
    and fixed exit codes (3 = target not found or ambiguous, 4 = server unreachable).
  - What's still missing: the client↔server wire protocol, code and a license. The API is RPC
    reached through the `rex` binary, `server.version` reports `0.1.0`, and a `method_not_found`
    error is documented as the expected result when a server is older than the docs.
  - **No third-party Rex client is announced.** Rex's clients are its own libghostty-based apps.
    The 07-29 post says Ghostty's "mission, governance, license, technical goals, and roadmap do
    not change". "Ghostty is the client" is Hacker News speculation, not a statement from
    Hashimoto. Asked on Mastodon (08-30) whether it would be part of Ghostty rather than a
    separate app, his whole answer was "Time will show". Nothing more is on record. The route into other
    terminals is libghostty: terminal-side pieces such as the binary snapshot are upstreamed
    there. Attaching from a terminal that doesn't speak the protocol is the architecture
    devlog's compatibility mode, which the docs don't cover.
  - **What libghostty has, as of this check:** the binary snapshot format (#13534, 07-31, marked
    experimental: "the format can and will change"; its stated uses include multiplexers),
    PTY-stream continuation tracking for replay (#13544, 08-01, "for me, this is used for
    multiplexers"), a snapshot-decode option to compress history (#14500, 10-01, C API
    `ghostty_snapshot_decoder_*`) and OSC 7501 (#14560). Those are the terminal-state halves a
    Rex client needs. The Rex wire protocol itself (attach, input, events) and any client code
    are not in the repo. Ghostty main also re-labels `ghostty.h` "libghostty-internal", tailored
    to the macOS app and "not designed for external use", and says external embedders should use
    libghostty-vt. warden embeds `ghostty.h`.
  - **Reception.** The July announcement drew 796 points and 406 comments on HN. Enthusiasm
    centred on Hashimoto's track record and the Ghostty non-profit. Skepticism centred on VC money
    for "a tmux clone", the investor list, and a pitch too vague to say what it builds. No Ghostty
    conflict-of-interest worry surfaced. The October beta posts drew no HN discussion at all; beta
    talk is on Discord, behind the invite. OSC 7501 got real debate (HN 141 points, Lobsters 35):
    - Windows Terminal maintainers split, from "I trust the folks at ghostty to be sane" to
      "smells like NIH".
    - Cargo will wait for adoption.
    - Critics called it AI-agent-specific, or argued for APC or systemd's OSC 3008 instead.
    - No kitty, WezTerm, foot or iTerm2 maintainer has responded.
    - Spec rev 0.3 (10-07): an absent `progress` now means indeterminate, and emitting without
      feature detection is allowed.

    Hashimoto (08-28): "we're not launching any hosted services". There's a Linux CLI server and
    a NixOS module, and Tailscale is built into the server.
- **2026-10-13** — status check: no devlog or video since 10-07 (the X posts are under 10-16). Two
  things landed:
  - **Claude Code emits OSC 7501**, shipped in v2.1.295 (10-08): "terminals that implement it can
    show whether Claude Code is working, waiting on you, or done". The hook amux would otherwise
    write exists upstream, but it only emits once the terminal answers `OSC 7501 ; ?` (its startup
    probe; no env var forces it on, `CLAUDE_CODE_DISABLE_TERMINAL_TITLE` turns it off). tmux 3.7c
    answers nothing (tested: a pane sending the query plus `CSI c` gets only the DA reply), so
    Claude Code under any tmux layer never emits. The Ghostty app drops `program_status` in its
    termio `StreamHandler`, query included, so a bare warden tab doesn't get it either.
  - **Spec rev 0.4** (10-10): the `?` query reply may now list the supported states and kinds, so a
    program can fall back from a later-revision state; terminfo `Pst` is removed. libghostty-vt
    follows in ghostty-org/ghostty#14630 (merged 10-10).
- **2026-10-15** — status check: no Superlogical devlog, YouTube upload or HN story since 10-07.
  Ghostty: no release since v1.3.1 (03-13). Since warden's vendored `b115e45`, `ghostty.h`
  gained only `ghostty_surface_paste_text` (paste protection for injected text; additive — warden's
  `cmd` injection deliberately stays on `ghostty_surface_text`), and snapshot decoding gained
  page-capacity validation (#14595). Still no `program_status` embedding action.
- **2026-10-16** — X posts from 10-11 to 10-15. None of them reached Mastodon. Still no devlog or
  video, and no Ghostty release. Nothing has touched `ghostty.h`, `embedded.zig` or the snapshot
  code since 10-15.
  - **Activity Mode** (10-11, @superlogical, quoted by Hashimoto): a Rex view of active and idling
    processes and agents, with metadata, for quick switching. It is built on OSC 7501.
    Hashimoto: "not as simple as 'program has activity lets show an attention icon.' Lots of
    heuristics and other signals as input to decide what exactly to show when." The design bar
    was an activity inbox the team would actually use instead of a noisy one. Testers were
    admitted in waves of 50–100 at that point.
  - **OSC 7501 adoption** (10-13): kitty implements it and shows it in the tab title, Grok Build
    shipped support, and Codex merged it. That makes Claude Code and Codex the two agents amux
    runs that now emit it.
  - **Rex iOS app** (10-12): the first build is in App Store review. iOS testing follows approval.
  - **Agents driving Rex across machines** (10-15): a tester's agent ran benchmarks on another
    person's Mac and brought both results back to compare. Superlogical plans evals so any
    harness can use Rex in few turns.
  - **Beta waves** (10-15): 250 invited the week of 10-05, about 2,000 the week of 10-12, and a
    1,000-person wave started on 10-15, in signup order. Almost 50,000 are still waiting, and
    wave size grows as stability holds.
  - **Ghostty main, 140 commits past warden's `b115e45`** (10-09). One embedding-API change in
    meaning: `OPEN_URL` kind `unknown` (regex-matched link text) is now documented as untrusted,
    like `osc8` (#14683, 10-13). The struct layout is unchanged. Ghostty.app has gated `osc8`
    since 08-05 and now gates `unknown` too: http/https/mailto with a host or address open,
    custom schemes ask first, and executable `file:` targets and control or bidi characters
    are refused. The policy is Swift in the macOS app, not libghostty; warden ports it in
    `surface/link.rs`. warden revendored to `b3dc3d7` (main, 10-15) the same day, which brings
    a fix for a use-after-free when scrollback
    prunes the cursor page (#14686), pty and terminal resizes synchronized (#14706), and
    CVDisplayLink start and stop moved to the main thread (#14691). The tmux control-mode viewer
    fixes and the libghostty-vt C API additions (prompt navigation, OSC 7501 rev 0.4,
    hierarchical context) don't reach `ghostty.h`.
- **2026-10-18** — status check: nothing since 10-16 beyond another 1,000 beta invites (X, 10-16).
  No devlog, video, HN story or new press; no Ghostty release; main is 11 commits past warden's
  `b3dc3d7` with none touching `ghostty.h`, `embedded.zig` or the snapshot code.
- **2026-10-19** — no Superlogical devlog, video, X post or HN story since 10-18. Ghostty main is
  18 commits past `b3dc3d7`, with none touching `ghostty.h`, `embedded.zig` or the snapshot code.
  This check added the sources above and found three things the ledger had missed:
  - **tmux declined OSC 7501** (tmux/tmux#5713, opened 10-09, closed 10-13). nicm: "This seems
    premature… between pane titles, OSC 9 progress bars and OSC 133 we have enough coverage of
    this kind of thing for the moment, let's see if this one takes off." tmux 3.8 (10-08) doesn't
    answer the query, so Claude Code still never emits under amux. A third-party patch onto tmux
    master (`autonomous-low-noise/tmux@4a77824`, 10-18) answers the query and keeps each pane's
    record as `pane_ps_*` formats. Nothing ships it.
  - **Ghostty is leaving GitHub** (mitchellh.com, 04-28). The destination is still in talks with
    "multiple providers (both commercial and FOSS)", the move will be incremental, and a read-only
    mirror stays at the current URL. As of today, PRs still merge on GitHub.
  - **The Rex docs have grown to 22 pages.** New since 10-09: a built-in agent skill for Claude Code
    and Codex (open tabs, split panes, read a screen, drive connected apps), and a read-only MCP
    server over the docs and the beta Discord's feedback, open to Discord members. There's still
    nothing on attach, the wire protocol or a license. The privacy page says Rex has no account or
    license checks. What the pages add for a warden client, beyond the 10-09 entry:
    - **Status can be pulled as well as streamed.** The terminal block has a `program_status`
      method that returns the current records. So a client that attaches late reads the state
      directly instead of replaying events. The other terminal methods are `format`, `process`,
      `pwd`, `title`, `size`, `write`, `reset`, `resize`, `set_theme` and `list_dir`.
    - **The `rex events --json` shape.** Each line is `{type, payload}`. A session event comes
      wrapped in `session_event` (adding `session_id`), and a terminal event is wrapped again in
      `block_event` (`block_id`, `creator_name`, `name`, `payload`). `program_status_changed`
      carries `id`, `record` and `reason`. Unknown events and fields are to be ignored, because new
      versions add them.
    - **Clients define the UI actions.** `pane.split`, `client.tab.*` and the rest come from the
      connected client (`rex -C <client> actions`), not from the server. A CLI or script can drive
      the Mac app only when Remote Control is on in the app's settings.
    - **Terminal options match warden's tab model.** They are `command`, `shell` (`none` execs the
      command directly), `cwd`, `initial_input` (text typed in at start, like warden's `cmd`) and
      `exit.on_completion`. Layouts are binary splits with a ratio. There are also floating layers,
      unplaced (detached) blocks, and server-side block plugins (`--block-dir`).
    - **Transport.** Local connections use a Unix socket. Remote ones use HTTP(S) on 443 or 7297,
      with callers identified only by Tailscale or the local peer uid. The docs call password and
      key auth **planned, "including support for existing SSH keys"**. That contradicts the 09-08
      demo's claim that SSH keys already work. The personal server starts on any `rex` command and
      exits about 10 s after its last session and connection close. Rex ships its own `xterm-rex`
      terminfo.
    - **The Linux server can't be installed yet, even by testers.** Its docs were written first.
      The 10-05 and 10-09 Linux mentions describe internal builds.
    - **Rex can configure Claude Code.** `rex skill setup` installs a `rex` skill in `~/.claude/skills`
      and adds a session-start hook to `~/.claude/settings.json`. The hook tells the agent its Rex
      session and has it name the session after its task.
    - **The release changelog is only in the beta Discord's #changelog**, which is readable through
      the community MCP. There's no public changelog page.
- **2026-10-24** — X posts only. There's still no devlog, video, new docs page or HN discussion,
  and the GitHub org has no repos. The attach and protocol searches of the docs still return
  nothing.
  - **Rex API compatibility across versions** (Hashimoto, 10-19, shipped in a preview release).
    Clients and servers of different versions now interoperate forwards and backwards. Each API
    change is recorded as a rule on a JSON pointer (RFC 6901). For each message, the rules between
    two versions compile lazily into a trie keyed by path tokens. A streaming JSON editor rewrites
    a message in one forward pass and copies untouched subtrees straight to the wire. Identical
    rule chains are interned, so a broadcast event is translated once per distinct chain rather
    than once per client. The API is at revision 4. A simulated 10,000-revision chain upgrades a
    20 KB body in about 35 µs. This was the gate on the Linux test program. For a warden client,
    it means a `rex events --json` consumer built against one server version keeps working
    against newer servers.
  - **The Linux server test program started** (10-21) with 100 people drawn from existing testers.
    The docs now say only members of a Linux testing wave can install it. 5,000 more joined the
    macOS beta the same day, about 7,500 that week, or roughly 15 % of the waitlist so far.
  - **The Rex iOS app is in external testing** (10-22), with dedicated iPad and iPhone Duo support.
    It will be free on the App Store.
  - **Kitty graphics now work over remote Rex sessions** (10-23), including image files that live
    on the remote host. Rex intercepts the file-based Kitty commands and resends the data to remote
    clients as in-band chunks, at under 1 % IO cost to everything else. The upstream half is in
    libghostty: the binary snapshot format now carries Kitty images, placements and pixels
    (ghostty-org/ghostty#14801, 10-21), restoring the layout before READY and the pixel data after
    it. #14776 and #14780 add a Kitty animation tick to the libghostty-vt C API and resolve Kitty
    placeholders in the render state. warden's surface already renders Kitty graphics, so none of
    this changes warden's own image path.
  - **Ghostty main moved to Zig 0.17** (#14519, 10-20; `minimum_zig_version = "0.17.0"`). Main is
    148 commits past warden's `b3dc3d7`. `ghostty.h` is unchanged. `embedded.zig` changed only
    through the treewide Zig 0.17 renames (`dupeZ` → `dupeSentinel`, `@intFromEnum` →
    `@backingInt`, and similar), so its behaviour is the same. warden revendored to `8ef0ec1`
    (main, 10-24) the same day, built on Zig 0.17.0. There's still no
    `program_status` embedding action. On the VT side, #14793 rejects OSC 7501 reports with
    malformed ids. Still no Ghostty release since v1.3.1.
  - **OSC 7501 adoption:** Rune 1.3 (10-23, HN 50 points) lists OSC 7501 support. Nothing new
    from tmux (#5713 stays closed, and 3.8 is still the latest tag), Claude Code or Codex.
- **2026-10-28** — X posts and a Ghostty release. There's still no devlog, YouTube upload or GitHub
  repo. The attach and protocol searches of the docs still find nothing about attaching.
  - **Ghostty v1.4.0 shipped** (10-27, tag commit `83fb956`; HN 600 points). It's the first release
    since v1.3.1. v1.4.0 is 61 commits past warden's vendored `8ef0ec1`, and main is 68 past it.
    `ghostty.h` and `embedded.zig` are unchanged in both. Only the snapshot code moved
    (`src/terminal/snapshot/screen.zig`, `terminal.zig`). Hashimoto's highlights: Kitty graphics
    fully conformant, animation included; scrollback compression (~90 % on average) and 50–90 %
    less memory overall; the Kitty clipboard protocol; macOS 27 support; `ghostty +ssh` installs
    terminfo on remote hosts. The release came with **13 security advisories**, published 10-27.
    Some of them are fixed only after warden's `8ef0ec1`, and those reach warden:
    - GHSA-w9q4-5jvv-mcv4: memory corruption when a screen clear prunes the cursor page (`e257bb4`).
    - GHSA-jqr7-69mm-v35h: a crash when narrowing a very wide page (`0af5c9e`).
    - GHSA-hp9c-qp4q-cpw3: a crash from zero-sized panes in a tmux control-mode layout (`bf14ea1`).
      Any program that writes to the terminal can trigger it, and the crash takes down the whole
      process.
    - GHSA-2r63-vmw6-3m3c: the zsh shell integration writes OSC 7 with `print`, so a crafted
      directory name can inject any escape sequence (an OSC 52 clipboard write, for example)
      (`ebd4499`). warden ships that script in `vendor/resources/ghostty/shell-integration/`.

    The use-after-free (GHSA-qjfx) and Kitty clipboard (GHSA-3r5j) fixes are already in
    `8ef0ec1`. The macOS link, OSC 8, drag-and-drop and file-open advisories are against the
    Ghostty app's Swift code, so they don't apply to warden. Its own link screening is in
    `surface/link.rs`. The libghostty-build tag `ghostty-8ef0ec1` is still the latest, so
    revendoring starts at its `GHOSTTY_REF`.
  - **libghostty's status** (Hashimoto, 10-27). It now builds and runs CI for Apple platforms,
    Windows, Linux, FreeBSD, Android, WebAssembly and freestanding targets. It has bindings in most
    languages. Its users include Herdr, cmux, the Ghostel Emacs terminal and Antithesis' fuzzing,
    and Neovim has verbally accepted it as its terminal core (neovim/neovim#39773). **libghostty 1.0,
    with a declared ABI stability, is planned "in the next few months".** The post doesn't say
    whether that stability covers `ghostty.h`, which main labels libghostty-internal. Every example
    in it embeds the VT core.
  - **JetBrains IDEs run on libghostty from 2026.3** (10-27). It replaces JediTerm. libghostty does
    the parsing and holds terminal state, and the IDE does its own rendering. That makes it another
    libghostty-vt embedder, which doesn't change `ghostty.h`.
  - **Rex docs: 24 pages.** FreeBSD server install is documented next to Linux, and both are still
    limited to Linux testing waves. The Rex UI tour (Alasdair Monk, X, 10-27, a 6½-minute video,
    not transcribed) covers pane management, process and agent activity, themes and animation. An
    iPhone Duo redesign is due for testers the week of 10-26.
  - Nothing new from tmux (#5713 stays closed, 3.8 is the latest tag), Claude Code or Codex on OSC
    7501, and no new press.
  - **warden's maintainer is in the macOS test program**, which grants the beta Discord. Its #info
    pin (Hashimoto, 09-09, so the Discord predates the 10-05 public wave) is the test program's
    terms. Testers may say they're testing and share screenshots. They may not share access or
    invite anyone. Testing covers the macOS app only, and it self-hosts a Rex server and connects
    to other Rex servers. The Linux server is "Server only", and #alpha-registration enrolls
    testers for other platforms as they open. **Don't host a Rex server publicly or without
    Tailscale**, because "there are significant security risks in doing so at this time". The
    default is local connections only, and Tailscale is the only supported way to expose a
    server. The short-term priorities are the iOS client, **Rex as a full SSH replacement on
    Linux**, and remote-host file copies, port forwarding and socket sharing. Feedback goes in
    #feedback-mac, and accepted items move to #backlog. The pin also gives the community MCP
    setup: `claude mcp add -s user --transport http superlogical
    https://www.superlogical.com/rex/community-mcp`.
  - **First read of the community MCP** (#changelog and #feedback, through 10-27). Releases are
    split by platform: Mac `0.1.0-preview.22`, Linux Server `preview.9`, plus separate iOS and CLI
    builds. Several ship a week. A tester reported API revision 5 on 10-22, one revision past the
    10-19 post. What bears on the unlock:
    - **A third-party client attaches today, through an undocumented method.** `data.connect`
      issues single-use tickets. A tester building an Emacs front end (Roost, which today shows
      tmux sessions through `tmux -C`) reports that their own client can attach, stream, type,
      resize and reattach with it. The stream opens with a **GHOSTSNP** frame, libghostty's binary
      snapshot, followed by the raw stream. That is the architecture devlog's attach, reachable from
      outside Superlogical's apps. The docs search finds nothing on `data.connect`. The tester's
      blocker was the snapshot itself: Emacs's terminal can't decode GHOSTSNP, and `format` with
      `vt` isn't tied to a position in the stream. They asked for the opening screen as VT and for
      a stdio attach (VT out, input in) that an editor runs as a subprocess. The request was
      deferred on 10-23.
    - **`rex attach` is gone.** It was the text-mode client, attaching inside the calling shell,
      which is the compatibility mode. It was removed in `preview.18` (10-21) "because it was
      incomplete and confusing people". Hashimoto: "Rex attach is gone for now."
    - **Driving the GUI client from outside works through Lua.** With Remote Control on, `rex do
      -e 'rex.client.queue("session.select", {session_id = …})'` moves the Mac app to a session.
      The client keeps its own focus state, and the server's focus state is advisory.
    - **Agent orchestration is meant for Lua.** An orchestrator wanted harness integration
      (readiness, prompt submission, conversation ids). Hashimoto said it "can and should be
      solved using our Lua scripting". There's no Lua method to report program status on a
      block's behalf yet. Status comes only from the block's own OSC 7501.
    - **OSC 7501 rough edges**, from testers running Codex, omp and Claude Code. OSC 133 prompt
      marks from omp drop its `working` record. Idle Codex returns no `program_status` record on a
      24-hour clock. Both are deferred. Rex shows status from remote tmux sessions only when the
      agent runs locally.

## What this changes here

**The destination is warden as the client and Rex as the session backend, with amux
retired.** The measure of progress is the number of terminal emulators between the host
client and each PTY. Today a framed agent has two (frame + agent) and an unframed one has
one. Rex's native path has zero. tmux leaves when Rex takes over sessions. amux leaves too,
because everything it does is either something Rex does natively or something warden owns
as the client.

- **The frame layer stops being warden's path.** warden already embeds one libghostty
  surface per PTY behind its `TerminalSurface` seam, which is the split model Superlogical
  describes, so warden's native splits replace the frame's fixed two-pane layout. Every
  invariant of the form *"re-assert this terminal feature on the frame socket too"*
  (`extkeys`, `sync`, `hyperlinks`, `allow-passthrough`, the per-layer OSC 777 wrap counted
  by `_tmux_nest_depth`, `bin/amux`'s re-assertion on every `--frame`) stops applying to
  that path.
- **amux is the bridge until Rex can host warden's sessions, and gets no new
  architecture.** No backend seam and no second session backend: those only paid off if
  amux outlived tmux. Fixes and small features to the tmux path stay worthwhile because it
  is what runs today. `--frame` keeps serving standalone terminals and remote hosts until
  amux retires.
- **Where each amux capability goes when amux retires:**

  | amux today | After |
  | --- | --- |
  | sessions that outlive the client, the session ledger, restore | Rex server-side sessions (persistent, parked when idle) |
  | `amux @host` over ssh/et/mosh | Rex servers on each host, reached with `-S <host>` / the client's remote sessions |
  | agent state in tab names, OSC 777 attention | OSC 7501 from the agent itself, read from Rex's `program_status_changed` events |
  | presence probe (`amux --probe`) | Rex `session_created`/`destroyed` and `child_exited` events |
  | directory-based agent selection, per-agent launch commands | warden's per-tab `cmd` cascade |
  | AI summary status lines, the note row | no home decided; warden chrome or dropped |

  The lock-in point lives here too. Rex's client and server are free, self-hosted,
  account-free and not directly monetized (2026-10-05), so the venture-funded risk is the
  unannounced commercial layer. warden reads Rex through its documented API and events,
  which keeps that layer optional.
- **Agent status reaches warden from Rex, not from the terminal.** Claude Code emits OSC
  7501 only to a terminal that answers its query (ledger, 2026-10-13). Rex answers it. tmux
  and the Ghostty app don't. So under amux nothing emits, and amux doesn't grow a 7501
  emitter for a layer that is going away. Under Rex, warden subscribes to `rex events --json`
  and renders the states as chrome, which is where warden's sidebar and tab-row dots already
  live. The events are raw states. Deciding what deserves attention takes a policy on top,
  which Rex's own Activity Mode builds from heuristics (ledger, 2026-10-16), and warden would
  have to write its own. The `ghostty.h` action matters only for plain tabs outside Rex (warden's
  `docs/FOLLOWUPS.md`).

**Not yet: warden as a Rex client.** Rex's wire protocol and client code aren't published.
An undocumented API method, `data.connect`, already lets a third-party client attach to a
block: a GHOSTSNP snapshot, then the raw stream, with input and resize going back (ledger,
2026-10-28). warden can't take that stream, though. `ghostty.h` has no way to load a snapshot
into a surface or to feed a surface from anything but its own PTY. Relaying the stream through a
subprocess in the surface's PTY would also need the opening screen as VT, and Superlogical
deferred that request on 10-23. The text-mode `rex attach`, which was the compatibility mode,
was removed on 10-21. The control side is already reachable: `rex` drives sessions and streams
events as a subprocess (ledger, 2026-10-09). warden's maintainer is in the macOS test program
(ledger, 2026-10-28), so that side can be tested against a real Rex server now. **Unlock:**
`data.connect` (or its successor) documented as a supported client protocol, plus either a
`ghostty.h` way to drive a surface from a snapshot and an external stream, or a VT opening screen
for a relay subprocess. Revisit when any of these moves. Until then, amux and tmux stay the
session layer.

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
