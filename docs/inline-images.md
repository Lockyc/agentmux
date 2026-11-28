---
type: decision
links:
  - rel: part-of
    to: CLAUDE.md
    note: the inline-images trap CLAUDE.md names
---

# Inline images are not a tmux problem

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
