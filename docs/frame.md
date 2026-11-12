---
type: reference
description: The --frame side-terminal layout — prefixes, the split left column, per-directory overrides, and managing frames.
links:
  - rel: part-of
    to: README.md
  - rel: see-also
    to: docs/config.md
---

# Side-terminal layout (`--frame`)

`amux --frame [agent] [session]` puts a persistent scratch terminal in the left
pane beside amux in the right. There are **three status bars**: a thin full-width outer bar (the
frame, showing the project + clock), and a per-pane bar under each side — the left
terminal's own tab bar and amux's.

- The **left pane is its own dedicated tmux**: its own tab bar, and it **never dies** —
  exit the shell and it respawns.
- **Prefixes:** the frame uses `C-f` ("f" for frame — `C-f h`/`l` focus left/right,
  `C-f j`/`k` move within the split left column, `C-f H`/`L` resize, `C-f 0` reset the
  split back to `[frame] left`, `C-f Q` quit, `C-f d` detach), overridable via
  `[frame] prefix`. The two inner tmuxes use their
  own prefix (`C-b` by default, or amux's `[amux] prefix` for the right pane), which
  the frame passes through to whichever pane is focused: left → the terminal's tabs,
  right → amux. A stray `prefix d` on either pane is harmless — the pane re-attaches
  in place rather than vanishing (use `C-f d` to detach the whole frame). The `[amux]`
  and `[frame]` prefixes must differ; a colliding `[amux] prefix` is ignored (with a
  warning).
- Set the left-pane width with `[frame] left = <percent>` (default `30`).
  Optionally split the left column top/bottom with `[frame] left_vertical_split =
  <percent>` (the top region's height, `10`–`90`; unset = single left pane). The
  top region is plain shells above the scratch pane (whose tab bar stays at the
  bottom), under both `--frame` and `--term`. Reach the top shells with the mouse,
  `C-f j`/`k`, or the terminal's own `C-b` pane keys; a top shell
  closes on `exit` like any plain shell (only the scratch pane respawns). Stack more
  than one shell in the top region with `[frame] left_top_panes = <count>` (`1`–`6`,
  default `1`, equal-height, full-width; needs `left_vertical_split`) — e.g.
  `left_vertical_split = 30` + `left_top_panes = 3` stacks three small shells above a
  larger scratch terminal. Two more layout fields:
  `[frame] focus` picks which pane starts focused — `"agent"` (right, the default)
  or `"terminal"` (the left column); `[frame] status_position` places the frame's
  outer status bar at `"bottom"` (default) or `"top"`. Frame
  config applies when the frame **and its scratch terminal** are **created** — both
  persist and keep their layout, so after changing it, tear them down
  (`C-f Q` or `amux --frame-kill <session>`, both of which drop the terminal as
  well) and relaunch. Killing only the agent session leaves the wrapper, which
  reattaches at the old size.
- **Open frames by default.** Set `[frame] default = true` to make a bare `amux`
  (run from a plain terminal) behave like `amux --frame`; use `amux --no-frame` for
  a one-off plain launch. Inside an existing tmux it is refused, as `amux --frame`
  is — see **Nesting inside tmux** below, including the `allow_nested` opt-in that
  lifts it.
- **Nesting inside tmux.** By default `--frame` refuses to run inside an existing
  tmux: the frame is its own tmux server, so nesting it stacks prefixes (your outer
  `C-b`, the frame's `C-f`, the scratch terminal's). Advanced users already living
  in tmux can opt in with `[frame] allow_nested = true`, which lifts the refusal
  for `--frame` and for `default = true` alike.
- **Per-directory overrides.** Any `[frame]` field can be overridden for a
  directory (and its subtree) with a `[frame.dirs."<path>"]` block — same
  matching as an agent's `dirs` (`~` expands, longest path wins), resolved
  per-field, falling back to the base `[frame]` values. e.g. a taller split that
  starts focused on the terminal in one project:
  ```toml
  [frame.dirs."~/code/myproject"]
  left_vertical_split = 30
  focus = "terminal"
  ```
- **Reattaching.** Run the same `amux --frame <session>` again (a closed pane is
  rebuilt).
- **Three sessions per project.** `<session>` (your agent), `<session>-frame` (the
  wrapper), and `<session>-term` (the left terminal) each run on their own per-project
  tmux server, so a busy agent in one project never slows another. **None of them
  shows up in a plain `tmux ls`** — use `amux --sessions` (agents) and `amux --frames`
  (frames) instead.
- **Managing frames:**
  - Leave the frame from inside: `C-f d` (detach, all kept) or `C-f Q` (quit the
    wrapper; the agent survives, reattach later).
  - `amux --frames` — list active frames.
  - `amux --frame-kill [session]` — tear down a frame: both the wrapper and its
    left terminal (default: current dir's), or, when no frame is up, the scratch
    terminal `--term` started; tear it down this way to relaunch it with a changed
    `[frame]` layout. The agent session keeps running.
  - `amux --kill [session]` — kill the whole project: the **agent** session plus
    its frame and terminal (default: current dir's). Use this instead of a raw
    `tmux kill-session` so nothing is left orphaned. `amux --sessions` lists the
    exact session names.
  - `amux attach <name>` — attach to an agent session by name from any directory;
    useful when you're not
    currently `cd`'d into that project.
