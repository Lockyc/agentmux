#!/bin/sh
# notes.sh — per-tab notes across four status rows: three that swap with the
# AI summary, plus one always-on note line.
#
# Rows 1-3 (status-format[1..3]) show either the LM summary (@amux_rowN,
# pushed by tmux-status.sh) or the user's notes (@amux_noteN), chosen by the
# @amux_notes pane-option flag. This script owns the notes side only; it never
# touches @amux_rowN, so the summary pipeline runs untouched and toggling back
# shows a CURRENT summary rather than a stale one. Row 4 (status-format[4]) is
# a fourth, always-on note line outside that swap — it never reads @amux_notes
# and is identical in summary and notes mode. Because row 4 is always visible,
# rows 1-3 are click-INERT while the summaries are showing (a click there does
# nothing rather than swapping the summaries away under the cursor); once
# notes mode is on, rows 1-3 click and edit exactly as before.
#
# Two options per row is deliberate: @amux_note_rawN holds what the user typed
# (the command-prompt prefill source), @amux_noteN holds the escaped display
# value. Escaping in place would make every edit re-escape its own output
# ("fix #42" -> "fix ##42" -> "fix ####42").
#
# HOOK-PATH helper: invoked from a key binding, so $TMUX is inherited and bare
# `tmux` is correct. Do NOT use the CLI-path $(_amux_agent_sock) + `env -u TMUX`
# pattern here — that is for helpers called from the bin/amux process.
#
# Test: NOTES_SELFTEST=1 sh scripts/notes.sh

# Note-row indicator. Leads EVERY row that is currently showing a note — rows 1-3
# while notes mode is on, and row 4 always — so the mark reads as "this row is a
# note row" rather than as a property of one particular row. A row whose note is
# empty still carries it, which is what makes the set of note rows legible at a
# glance instead of looking like blank filler.
NT_MARK='✎ '
# Shown on row 1 when notes mode is on and all three notes are empty.
#
# STYLED WITH AN ATTRIBUTE, NEVER A COLOUR. A fixed `fg=colour240` was
# unreadable on most of the bar palette: the row's background is a per-session
# shade (@l2bg) spanning the whole 256-colour cube, so one hardcoded grey is
# low-contrast against much of it. `#[dim]` instead inherits the fg that
# status-format already resolved for the row (@l2fg — chosen as legible against
# @l2bg by construction) and only dims it, so it is readable on every palette
# entry and degrades to plain readable text where dim is unsupported.
#
# It cannot be made adaptive with a format instead: `#{?…}` inside a substituted
# OPTION VALUE is not expanded (verified — only `#{E:…}` expands, and using that
# on these rows would also expand format directives inside USER NOTE TEXT, which
# is exactly what the `#`-doubling in _nt_esc exists to prevent).
#
# Carries a style directive of OUR OWN — added after escaping, never escaped.
NT_HINT='#[dim]✎ click a row to write a note'
# Shown on row 4 (the always-on note line) when slot 4 is empty. Separate from
# NT_HINT because the two empty-states are independent: NT_HINT is about slots
# 1-3 and only ever appears in notes mode, while this one is on screen from
# launch and is the discovery path into writing a note at all. Carries a style
# directive of OUR OWN — added after escaping, never escaped itself.
#
# ON SCREEN FROM LAUNCH IS NOT SOMETHING THIS SCRIPT ACHIEVES BY ITSELF.
# _nt_render is reachable only from a click or `prefix N`, and neither is on the
# launch path — so a freshly launched tab has no pane-level @amux_note4 and row 4
# would draw as blank padding. bin/amux publishes THIS string as the SESSION-level
# @amux_note4 default when `[notes] row` is on, asking for it via the `hint`
# subcommand below so the literal stays here alone. tmux resolves
# pane->window->session->global, so a rendered pane shadows the default and the
# two can never disagree.
NT_HINT4='#[dim]✎ click to add a note'

# Row 4's button slot, at the START of the row. Left, not right, because the
# #{p400:…} pad that makes an empty row clickable across the full width consumes
# the line — a right-aligned control would be pushed off screen by it.
#
# The slot carries its OWN trailing space and is emitted at a constant width by
# _nt_btn, so status-format[4] substitutes it with no `#{pN:…}` pad. That is
# deliberate: a pad in the conf would be a second place the width lives, and the
# two would drift. The width being constant is what stops the note text shifting
# as the button changes state — with a note it offers copy+clear, after a clear
# it offers undo, and with neither it is blank.
#
# Row 4 only. Rows 1-3 share their line with the AI summary, so a slot there
# would either indent every summary permanently or appear and vanish on each
# `prefix N` — a shifting layout for a control that applies in one mode only.
# All three states are the SAME WIDTH, including the blank one — that is what
# "constant" means above, and the blank state is two spaces rather than an empty
# string on purpose: an empty slot would let the note text jump two columns left
# the moment a row has nothing to copy, which is exactly the layout instability
# the fixed slot exists to prevent. A click on the blank slot is a no-op.
NT_COPY='⧉ '
NT_UNDO='↩ '
NT_BTN_NONE='  '

# The prompt shown on a row while it is being edited, e.g.
#   note 4  esc=cancel  enter=save>
#
# IT NAMES ITS OWN EXITS, and that is the entire reason the string is not just
# "note 4>". tmux SWALLOWS ALL MOUSE INPUT while a command-prompt is open (see
# the footgun at the command-prompt call below), so a click into a note row that
# the user does not notice reads as a LOCKED INTERFACE — keystrokes stop
# reaching the pane and nothing on screen says how to get out. The prompt text
# is the only channel tmux leaves open, so it has to carry the answer. Esc
# cancels without writing; Enter commits.
#
# ASCII ONLY, and NO COMMA. The comma is load-bearing: `command-prompt -p` takes
# a COMMA-SEPARATED LIST of prompts (man tmux), so a single comma here would
# silently open a SECOND prompt after the first. ASCII because tests/mouse
# matches these exact bytes on the pty.
_nt_prompt() {
  printf 'note %s  esc=cancel  enter=save>' "$1"
}

# _nt_row <mouse_status_range> -> 1|2|3 on stdout, or nothing.
# tmux sets mouse_status_range to the bare `X` of range=user|X, but accept a
# `user|` prefix too so this cannot break if that ever changes. Anything that
# is not one of our three ranges (a window-list or status-left click) prints
# nothing — the caller treats that as "not a note click" and does nothing.
_nt_row() {
  case "$1" in
    amuxnote1|user\|amuxnote1) printf '1' ;;
    amuxnote2|user\|amuxnote2) printf '2' ;;
    amuxnote3|user\|amuxnote3) printf '3' ;;
    amuxnote4|user\|amuxnote4) printf '4' ;;
    *) : ;;
  esac
}

# _nt_btn_row <mouse_status_range> -> 4 for row 4's BUTTON range, else nothing.
# Separate from _nt_row on purpose: the two ranges sit on the same status line
# and mean different things, so a click must resolve to exactly one of them.
# Only row 4 has a button (see NT_COPY).
_nt_btn_row() {
  case "$1" in
    amuxcopy4|user\|amuxcopy4) printf '4' ;;
    *) : ;;
  esac
}

# _nt_esc <text> -> text with every '#' doubled.
# status-format re-parses the value it substitutes, so an unescaped '#' in a
# note ("fix #42", "PR #7") would be read as a format directive.
_nt_esc() {
  printf '%s' "$1" | sed 's/#/##/g'
}

# _nt_display <row> <raw1> <raw2> <raw3> <raw4> -> the finished display string.
# Raws 1-3 are all passed because row 1's content depends on whether any of
# THOSE THREE exists (the empty-state hint). Raw 4 is passed separately and is
# read only by row 4.
_nt_display() {
  _d_r=$1; _d_1=$2; _d_2=$3; _d_3=$4; _d_4=$5
  # Row 4 — the always-on note line. Answered FIRST and from slot 4 alone: it
  # is not part of the rows-1-3 empty-state below, and it never reads
  # @amux_notes, so its content is identical in summary and notes mode.
  if [ "$_d_r" = 4 ]; then
    if [ -z "$_d_4" ]; then
      printf '%s' "$NT_HINT4"
    else
      # NT_MARK is prepended AFTER escaping: it is our directive, not user text.
      # Row 4 always carries it, so the row reads as a note rather than as a
      # fourth summary row.
      printf '%s%s' "$NT_MARK" "$(_nt_esc "$_d_4")"
    fi
    return 0
  fi
  if [ -z "$_d_1" ] && [ -z "$_d_2" ] && [ -z "$_d_3" ]; then
    # Nothing written yet: one dim hint on row 1 so notes mode never looks
    # broken and the rows advertise that they are clickable.
    [ "$_d_r" = 1 ] && printf '%s' "$NT_HINT"
    return 0
  fi
  # NT_MARK is prepended AFTER escaping: it is our directive, not user text.
  # EVERY row carries it, empty or not — the mark identifies a note row, so
  # marking only the first one made rows 2 and 3 read as blank filler rather
  # than as writable rows.
  case "$_d_r" in
    1) printf '%s%s' "$NT_MARK" "$(_nt_esc "$_d_1")" ;;
    2) printf '%s%s' "$NT_MARK" "$(_nt_esc "$_d_2")" ;;
    3) printf '%s%s' "$NT_MARK" "$(_nt_esc "$_d_3")" ;;
  esac
}

# _nt_btn <raw> <prev> -> the button slot's display string.
# Three states, one slot: something to copy, something to restore, or neither.
# `raw` wins when both are set — a row holding a note offers copy+clear, and the
# undo only surfaces once the clear has actually emptied it.
_nt_btn() {
  if   [ -n "$1" ]; then printf '%s' "$NT_COPY"
  elif [ -n "$2" ]; then printf '%s' "$NT_UNDO"
  else                   printf '%s' "$NT_BTN_NONE"
  fi
}

# _nt_prev <pane> <row> -> that row's previous (cleared) note, for undo.
_nt_prev() {
  tmux show-options -p -v -t "$1" "@amux_note_raw_prev$2" 2>/dev/null
}

# _nt_copy <text> — put <text> on the tmux paste buffer AND, where one exists,
# the system clipboard.
#
# BOTH, because the clear that follows is destructive and the two have different
# failure modes. `load-buffer` is part of tmux itself, so it always succeeds and
# is the backstop that makes the clear safe (paste with `prefix ]`). The system
# clipboard is what the user actually means by "copy", but every route to it can
# fail QUIETLY — a missing copier, or OSC 52 needing passthrough on each tmux
# layer, which under `--frame` is two deep (the same nesting trap documented for
# OSC 777 in tmux-status.sh). So the clipboard is best-effort on top, never the
# only copy.
#
# Text arrives on STDIN, never argv: a note is user text and argv is world
# readable via ps. The copier list is ordered macOS, Wayland, X11 — all of them
# OS-provided rather than dependencies to install, so this adds none (the repo's
# runtime deps stay toml2json + jq); where none exists the tmux buffer still has
# it and the feature degrades rather than breaking.
_nt_copy() {
  printf '%s' "$1" | tmux load-buffer - 2>/dev/null
  if   command -v pbcopy  >/dev/null 2>&1; then printf '%s' "$1" | pbcopy 2>/dev/null
  elif command -v wl-copy >/dev/null 2>&1; then printf '%s' "$1" | wl-copy 2>/dev/null
  elif command -v xclip   >/dev/null 2>&1; then printf '%s' "$1" | xclip -selection clipboard 2>/dev/null
  fi
  return 0
}

# _nt_raw <pane> <row> -> that row's raw (unescaped) note text.
_nt_raw() {
  tmux show-options -p -v -t "$1" "@amux_note_raw$2" 2>/dev/null
}

# _nt_render <pane> — recompose all four display options from the raws.
# Rows 1-3 are all rewritten every time because row 1's content depends on
# whether any of them exists (the empty-state hint). Row 4 is rewritten
# unconditionally too: it is cheap, and it means the value is already correct
# if the fourth row is switched on later without a fresh edit.
_nt_render() {
  _rp=$1
  _r1=$(_nt_raw "$_rp" 1); _r2=$(_nt_raw "$_rp" 2); _r3=$(_nt_raw "$_rp" 3)
  _r4=$(_nt_raw "$_rp" 4)
  for _i in 1 2 3 4; do
    tmux set-option -p -t "$_rp" "@amux_note$_i" \
      "$(_nt_display "$_i" "$_r1" "$_r2" "$_r3" "$_r4")" 2>/dev/null
  done
  # Row 4's button slot, recomputed from the same raws so it can never disagree
  # with what the row is showing (a copy button beside an empty row, or an undo
  # beside a note that was never cleared).
  tmux set-option -p -t "$_rp" @amux_btn4 \
    "$(_nt_btn "$_r4" "$(_nt_prev "$_rp" 4)")" 2>/dev/null
  tmux refresh-client -S 2>/dev/null
}

case "${1:-}" in
  hint)
    # `hint 4` prints row 4's empty-state hint on stdout. One of this file's two
    # exports of a display literal (see `prompt` below): bin/amux publishes it as
    # the session-level
    # @amux_note4 default at launch (see NT_HINT4 above), and needs the value
    # without restating it. Touches no tmux — safe to call from the CLI path,
    # which has no ambient $TMUX.
    #
    # Only row 4 is exported. Rows 1-3's hint (NT_HINT) is reachable only in notes
    # mode, which is only ever entered through `toggle` — and `toggle` always
    # renders, so those rows have no un-rendered launch state to cover.
    [ "${2:-}" = 4 ] && printf '%s' "$NT_HINT4"
    exit 0
    ;;
  prompt)
    # `prompt <row>` prints that row's edit prompt. tests/mouse asserts on the
    # prompt's exact bytes — including PREFILL ADJACENCY ("<prompt>fix #42") —
    # and asks for them here rather than restating them, so the suite cannot
    # drift from what the product actually shows. Touches no tmux, so it is safe
    # from the CLI path, which has no ambient $TMUX.
    case "${2:-}" in 1|2|3|4) _nt_prompt "$2" ;; esac
    exit 0
    ;;
  render)
    [ -n "${2:-}" ] || exit 0
    _nt_render "$2"
    exit 0
    ;;
  toggle)
    [ -n "${2:-}" ] || exit 0
    _tp=$2
    # Ask tmux the SAME question status-format[1..3]'s #{?@amux_notes,…} asks
    # (tmux/agentmux.conf) — never `show-options -p -v` + `[ -n … ]`, which
    # LOOKS equivalent and is not. Two disagreements, both real: (1) truthiness
    # — the literal string "0" is FALSE to `#{?…}` but "on" to `[ -n … ]`; (2)
    # scope — `show-options -p` reads the PANE level only (prints nothing, even
    # with a option set at any wider scope), while `#{?…}` resolves the full
    # pane->window->session->global chain. Concretely: a user's
    # `~/.agentmux/user.agent.tmux.conf` (this repo's CLAUDE.md advertises that
    # file as "user settings win over our defaults", sourced last by every
    # agent socket) setting `set -g @amux_notes 1` puts the renderer in notes
    # mode on every tab, but the old `show-options -p` test read that pane as
    # OFF — so toggle-on set the pane to 1 (still on) and toggle-off UNSET it,
    # falling back to the same global 1 (still on): `prefix N` could never turn
    # it off, and since `_nt_render` never ran either, all three rows went
    # blank. Fix: use `display-message` + `#{?…}` to read the SAME resolved
    # value the renderer uses, and always WRITE an explicit pane-level value —
    # never `-up` unset — since a pane-level 0 correctly SHADOWS a wider-scope
    # 1 in tmux's format-option lookup chain (verified).
    if [ "$(tmux display-message -p -t "$_tp" '#{?@amux_notes,1,}' 2>/dev/null)" = 1 ]; then
      tmux set-option -p -t "$_tp" @amux_notes 0 2>/dev/null
    else
      tmux set-option -p -t "$_tp" @amux_notes 1 2>/dev/null
    fi
    _nt_render "$_tp"
    exit 0
    ;;
  click)
    # click <pane> <mouse_status_range> <client_tty>
    _cp=${2:-}; _cr=$(_nt_row "${3:-}"); _ct=${4:-}
    [ -n "$_cp" ] || exit 0

    # THE BUTTON, resolved before the note ranges: it shares row 4's status line
    # and a click belongs to exactly one of the two.
    #
    # One control, two actions, chosen by state — copy+clear when the row holds a
    # note, undo when a previous one is waiting. That pairing is what makes the
    # clear safe to offer at all: it is one click from destroying a note, so the
    # text goes to the clipboard AND the tmux buffer AND @amux_note_raw_prev4
    # before it is cleared, and the same button restores it. A blank slot (no
    # note, nothing to restore) is a no-op.
    _cb=$(_nt_btn_row "${3:-}")
    if [ -n "$_cb" ]; then
      _bcur=$(_nt_raw "$_cp" "$_cb"); _bprev=$(_nt_prev "$_cp" "$_cb")
      if [ -n "$_bcur" ]; then
        _nt_copy "$_bcur"
        tmux set-option -p -t "$_cp" "@amux_note_raw_prev$_cb" "$_bcur" 2>/dev/null
        tmux set-option -up -t "$_cp" "@amux_note_raw$_cb" 2>/dev/null
      elif [ -n "$_bprev" ]; then
        tmux set-option -p -t "$_cp" "@amux_note_raw$_cb" "$_bprev" 2>/dev/null
        # The undo is spent — one level, not a stack. Leaving it would make the
        # button flip-flop between copy and undo forever, which reads as a toggle
        # and would let a stale note reappear long after it was cleared.
        tmux set-option -up -t "$_cp" "@amux_note_raw_prev$_cb" 2>/dev/null
      fi
      _nt_render "$_cp"
      exit 0
    fi

    # Not one of our ranges (window list, status-left): do nothing. The binding
    # already routed the default behaviour elsewhere.
    [ -n "$_cr" ] || exit 0
    # THE RETIREMENT. Rows 1-3 are click-INERT while the summaries are showing:
    # row 4 (always a note) is the click target in summary mode, so a click on a
    # summary row must not swap the summaries away under the cursor. In notes
    # mode rows 1-3 edit exactly as before. Row 4 is always live and never
    # touches @amux_notes.
    #
    # Same tmux-format-semantics test as `toggle` above, and for the identical
    # reason — never `show-options -p -v` + `[ -n … ]` here; see the long comment
    # on the `toggle` case for the truthiness/scope trap it hides.
    #
    # Note this SWALLOWS the click rather than falling through to the default
    # `switch-client -t =` — deliberate: an inert row should do nothing at all.
    if [ "$_cr" != 4 ] && \
       [ "$(tmux display-message -p -t "$_cp" '#{?@amux_notes,1,}' 2>/dev/null)" != 1 ]; then
      exit 0
    fi
    # Resolve the pane to a PLACEHOLDER-FREE target before any of it reaches
    # the command-prompt TEMPLATE below. The binding passes #{pane_id}
    # (%0, %1, %2, …), and per `man tmux`: "the first occurrence of the string
    # `%%` and all occurrences of `%1` ... up to `%9`" inside that template are
    # replaced by the typed response — so `-t %1` silently becomes
    # `-t <whatever the user typed>` on every pane but %0, and both the
    # set-option and the run-shell re-render break the same way.
    # #{window_id}.#{pane_index} (e.g. "@0.0") is built from two tmux-internal
    # identifiers, neither user-controlled: window_id is always `@<n>`, and
    # pane_index is numeric. Do NOT use session_name here — tmux 3.7 permits
    # `%`, `'`, `,`, spaces, `:` and `.` in a session name, so a session named
    # e.g. "%1" would reintroduce the exact placeholder collision this target
    # exists to avoid, just via the session name instead of the pane id. Bail
    # rather than proceed with a broken target if it can't be resolved (e.g.
    # the pane vanished mid-click).
    _cg=$(tmux display-message -p -t "$_cp" '#{window_id}.#{pane_index}' 2>/dev/null)
    [ -n "$_cg" ] || exit 0
    # Absolute path to this script, for the command-prompt template below: the
    # template is executed by tmux, whose cwd is not ours. Guard the `cd`
    # failing (a stale/removed install dir) rather than silently falling back
    # to a broken "/notes.sh" — and single-quote it where it lands in the
    # template, since it is interpolated there UNQUOTED and an install path
    # containing a space would otherwise split into extra template tokens.
    _self_dir=$(cd "$(dirname "$0")" 2>/dev/null && pwd) || exit 0
    [ -n "$_self_dir" ] || exit 0
    NT_SELF=$_self_dir/$(basename "$0")
    # Render before prompting so the display options exist even on a pane that
    # has never rendered (e.g. the first click of a session).
    _nt_render "$_cp"
    # Open the prompt ON THE ROW BEING EDITED. `message-line` sets which status
    # line carries messages and the command prompt; tmux's default is 0, which
    # is our WINDOW LIST — so editing any note covered the tab bar while you
    # typed, and the row you clicked sat untouched below it. Our rows sit at
    # status-format[1..4] and message-line takes 0-4, so the row number IS the
    # line number and no mapping is needed.
    #
    # Set, never restored: there is no hook for the prompt being dismissed with
    # Escape (only the commit template runs), so a restore would only fire on
    # some exits and leave the value inconsistent on others. Leaving it is
    # harmless and self-correcting — every click sets it to the row it is about
    # to edit, and the only other things drawn on that line are amux's own
    # occasional one-line messages, which are transient and equally readable
    # there. It is a SESSION option, so this never leaks between projects.
    tmux set-option -t "$_cp" message-line "$_cr" 2>/dev/null
    # THE POPUP, and it goes BEFORE the prompt — not after it, and not beside
    # it. The prompt below already names its exits, but that only helps once you
    # look at the status bar; this makes the click itself unmissable. Read
    # note_popup.sh's header before moving this line: the ordering is forced by
    # three measurements, not by taste.
    #
    #   * A live popup takes ALL of the client's input — the command-prompt gets
    #     nothing while one is up, so a popup opened OVER the prompt eats the
    #     note text (verified: "abc" + Enter landed nowhere at all).
    #   * `tmux command-prompt` BLOCKS this script until the prompt is
    #     dismissed, so a popup opened on the line after it would appear only
    #     once editing was over.
    #   * The prompt survives a popup, so opening the popup first costs nothing.
    #
    # SYNCHRONOUS on purpose: display-popup blocks its caller until the popup
    # closes, and that is exactly the sequencing wanted here — the prompt opens
    # as the popup goes away. Nothing is held up by it, because this whole
    # script already runs under the binding's `run-shell -b`.
    #
    # Best-effort, and it must stay that way: a missing note_popup.sh, an
    # unresolvable client (the selftest passes /dev/null) or a tmux that cannot
    # open a popup must all fall through to the prompt below rather than losing
    # the edit. Single-quoted where the path lands in the command string, for
    # the same reason NT_SELF is: tmux hands the string to a shell.
    NT_POPUP=$_self_dir/note_popup.sh
    if [ -n "$_ct" ] && [ -r "$NT_POPUP" ]; then
      tmux display-popup -c "$_ct" -E \
        "bash '$NT_POPUP' '$_cr' '$_cg'" 2>/dev/null
    fi
    # %%% (see below) escapes quotation marks (and `\ $ ; ~`) in the typed
    # response, so it is stored literally and cannot inject a tmux command.
    #
    # -l: -I's prefill is otherwise a COMMA-SPLIT list (per `man tmux`), so a
    # note like "ask sam, then deploy" would prefill only "ask sam" and a
    # click-then-Enter would silently truncate it. -l treats it literally.
    #
    # %%%, not %%: per `man tmux`, "%%% is like %% but any quotation marks are
    # escaped." %% substitutes the typed response RAW — verified to silently
    # strip quotes, expand the user's own env vars (a note reading "$HOME"
    # stores the expanded path), and permit tmux command/shell injection
    # through a crafted `"` in the note text riding a second `set-option`/
    # `run-shell` in on the same click.
    # Minimum tmux is 3.6 (README Prerequisites) — `-l` above doesn't exist
    # before it. On an older tmux the mode flip and `_nt_render` above already
    # ran, so a silent failure here would leave the tab stuck showing the
    # empty-state hint with no way to tell WHY the prompt never opened. The
    # `||` fires only on that parse-time rejection (an unrecognised `-l`
    # errors immediately, before the prompt ever blocks on user input — this
    # is not reachable on a supported tmux), so it can't fire from the user
    # merely dismissing the prompt.
    # FOOTGUN: A CLICK CANNOT DISMISS THIS PROMPT, and the fix that looks right
    # is inert. tmux swallows ALL mouse input while a command-prompt is open — a
    # `bind -T root MouseDown1Status` to close it installs cleanly, appears in
    # `list-keys`, and is NEVER invoked. Verified on tmux 3.7b driving a real pty
    # client with SGR mouse sequences: the identical click fires the binding
    # before the prompt opens and again after it closes, and not once while it is
    # open. There is no prompt key table to bind into either — tmux has only
    # root, prefix, copy-mode and copy-mode-vi. Esc cancels and the commit
    # template never runs (verified), which is why _nt_prompt names it. Only a
    # display-popup behaves the other way (an outside click DOES reach the
    # bindings while the popup stays open), so click-to-dismiss would mean
    # replacing this prompt outright — not adding a binding to it.
    tmux command-prompt -t "$_ct" -l -I "$(_nt_raw "$_cp" "$_cr")" -p "$(_nt_prompt "$_cr")" \
      "set-option -p -t '$_cg' @amux_note_raw$_cr \"%%%\" ; run-shell \"sh '$NT_SELF' render '$_cg'\"" \
      2>/dev/null || \
      tmux display-message -t "$_ct" "notes: click-to-edit needs tmux 3.6+" 2>/dev/null
    exit 0
    ;;
  *)
    # An UNRECOGNIZED subcommand (a future typo, e.g. a misspelled selftest
    # child "rende") is a no-op — it must not fall through to the
    # NOTES_SELFTEST block below with the flag still inherited, or it would
    # re-run the entire selftest (which spawns tmux servers and more children)
    # from what was meant to be a single leaf call. NO subcommand at all is
    # different: that's the documented entry point ("Test: NOTES_SELFTEST=1 sh
    # scripts/notes.sh"), so an empty "$1" falls through on purpose.
    [ -n "${1:-}" ] && exit 0
    ;;
esac

if [ "${NOTES_SELFTEST:-}" = "1" ]; then
  fail=0
  ck() { # ck <label> <got> <want>
    [ "$2" = "$3" ] || { echo "$1 FAIL got[$2] want[$3]" >&2; fail=1; }
  }

  # --- _nt_row: range argument -> row number -------------------------------
  ck row-bare    "$(_nt_row amuxnote2)"      "2"
  ck row-prefix  "$(_nt_row 'user|amuxnote3')" "3"
  ck row-one     "$(_nt_row amuxnote1)"      "1"
  # A click on the window list must NOT parse as a note click.
  ck row-window  "$(_nt_row 'window|@3')"    ""
  # shellcheck disable=SC2016
  ck row-session "$(_nt_row 'session|$0')"   ""
  ck row-empty   "$(_nt_row '')"             ""
  # Only rows 1-3 exist.
  ck row-oob     "$(_nt_row amuxnote9)"      ""
  ck row-junk    "$(_nt_row amuxnoteX)"      ""

  # --- _nt_esc: '#' is doubled, nothing else changes -----------------------
  ck esc-hash    "$(_nt_esc 'fix #42')"      'fix ##42'
  ck esc-multi   "$(_nt_esc 'a#b#c')"        'a##b##c'
  ck esc-none    "$(_nt_esc 'plain text')"   'plain text'
  ck esc-quote   "$(_nt_esc "sam's cert")"   "sam's cert"
  ck esc-empty   "$(_nt_esc '')"             ''

  # --- _nt_display: all three empty -> hint on row 1, others blank ---------
  ck disp-hint1  "$(_nt_display 1 '' '' '' '')" "$NT_HINT"
  ck disp-hint2  "$(_nt_display 2 '' '' '' '')" ''
  ck disp-hint3  "$(_nt_display 3 '' '' '' '')" ''

  # --- _nt_display: any content -> hint gone, mark leads row 1 -------------
  ck disp-r1     "$(_nt_display 1 'deploy blocked' 'ask sam' '' '')" "${NT_MARK}deploy blocked"
  ck disp-r2     "$(_nt_display 2 'deploy blocked' 'ask sam' '' '')" "${NT_MARK}ask sam"
  ck disp-r3     "$(_nt_display 3 'deploy blocked' 'ask sam' '' '')" "$NT_MARK"
  # Row 1 empty but others filled: mark still shows, so the mode stays visible.
  ck disp-mark   "$(_nt_display 1 '' 'ask sam' '' '')" "$NT_MARK"
  # Escaping is applied by _nt_display, on user text only.
  ck disp-esc    "$(_nt_display 2 '' 'fix #42' '' '')" "${NT_MARK}fix ##42"
  ck disp-esc1   "$(_nt_display 1 'PR #7' '' '' '')"   "${NT_MARK}PR ##7"

  # Feeding display output back in DOES double-escape — which is exactly why
  # the raw text is kept in a separate option and _nt_display is only ever
  # given raws. This asserts the hazard is real, so the two-option split can
  # never be "simplified" away without a red test.
  ck disp-reesc  "$(_nt_display 2 '' "$(_nt_display 2 '' 'fix #42' '' '')" '' '')" "${NT_MARK}${NT_MARK}fix ####42"

  # --- _nt_display row 4: the always-on note line --------------------------
  # Row 4 reads ONLY slot 4. Both independence directions are asserted below,
  # because the whole point of the row is that it does not participate in the
  # rows-1-3 empty-state or the mode swap.
  ck disp4-hint  "$(_nt_display 4 '' '' '' '')"          "$NT_HINT4"
  ck disp4-text  "$(_nt_display 4 '' '' '' 'ship it')"   "${NT_MARK}ship it"
  ck disp4-esc   "$(_nt_display 4 '' '' '' 'fix #42')"   "${NT_MARK}fix ##42"
  # A note in slot 4 must NOT suppress row 1's own hint …
  ck disp4-indep1 "$(_nt_display 1 '' '' '' 'ship it')"  "$NT_HINT"
  # … and notes in slots 1-3 must NOT fill row 4.
  ck disp4-indep2 "$(_nt_display 4 'deploy blocked' 'ask sam' 'x' '')" "$NT_HINT4"

  # --- _nt_row: slot 4 -----------------------------------------------------
  ck row-four    "$(_nt_row amuxnote4)"        "4"
  ck row-four-p  "$(_nt_row 'user|amuxnote4')" "4"

  # --- the row-4 button: three states, one slot ----------------------------
  ck btn-copy    "$(_nt_btn 'ship it' '')"        "$NT_COPY"
  ck btn-undo    "$(_nt_btn '' 'ship it')"        "$NT_UNDO"
  ck btn-none    "$(_nt_btn '' '')"               "$NT_BTN_NONE"
  # A note wins over a waiting undo: a row holding text offers copy+clear, and
  # the undo only surfaces once the clear has actually emptied it.
  ck btn-both    "$(_nt_btn 'new' 'old')"         "$NT_COPY"
  # Every state is the SAME WIDTH — an empty slot would shift the note text two
  # columns the moment a row has nothing to copy.
  ck btn-width   "$(printf '%s%s%s' "$NT_COPY" "$NT_UNDO" "$NT_BTN_NONE" | wc -m | tr -d ' ')" "6"
  # The button range must not resolve as a note range, or a click would edit the
  # note instead of copying it (both sit on row 4's line).
  ck btnrow-4    "$(_nt_btn_row amuxcopy4)"       "4"
  ck btnrow-pfx  "$(_nt_btn_row 'user|amuxcopy4')" "4"
  ck btnrow-note "$(_nt_btn_row amuxnote4)"       ""
  ck row-notbtn  "$(_nt_row amuxcopy4)"           ""


  # --- `hint 4`: the single source bin/amux publishes at launch ------------
  # Run as a CHILD (not by calling the case arm in-process) so this covers the
  # dispatch too — that is the surface bin/amux actually uses. Asserted against
  # the same NT_HINT4 _nt_display returns, so the launch-time default and the
  # rendered empty state can never drift apart silently.
  ck hint4       "$(env -u NOTES_SELFTEST sh "$0" hint 4)"  "$NT_HINT4"
  ck hint4-eq-disp "$(env -u NOTES_SELFTEST sh "$0" hint 4)" "$(_nt_display 4 '' '' '' '')"
  # Only row 4 is exported; anything else prints nothing rather than guessing.
  ck hint4-other "$(env -u NOTES_SELFTEST sh "$0" hint 1)"  ""
  ck hint4-none  "$(env -u NOTES_SELFTEST sh "$0" hint)"    ""

  # --- `prompt <row>`: the second export, and it must NAME ITS EXIT --------
  # Run as CHILDREN (not by calling _nt_prompt in-process) so the dispatch is
  # covered too — that is the surface tests/mouse actually uses.
  ck prompt-1     "$(env -u NOTES_SELFTEST sh "$0" prompt 1)" "$(_nt_prompt 1)"
  ck prompt-4     "$(env -u NOTES_SELFTEST sh "$0" prompt 4)" "$(_nt_prompt 4)"
  # Pins row 1's exact bytes against a hardcoded literal — a regression alarm on
  # the wording itself, distinct from prompt-1/prompt-4 above (which only prove
  # the CHILD dispatch matches an in-process _nt_prompt call with the SAME
  # argument, so a _nt_prompt that ignored "$1" would still pass both of those).
  ck prompt-bytes "$(_nt_prompt 1)" "$(printf 'note 1  esc=cancel  enter=save>')"
  # Rows must actually DIFFER, or a click on row 2 could not be told from row 4
  # on the pty — this is the missing cross-row check prompt-1/prompt-4/
  # prompt-bytes above don't cover: each of those fixes $1 and never compares
  # two rows against each other, so a _nt_prompt that ignored "$1" entirely
  # would pass all three identically.
  ck prompt-distinct "$([ "$(_nt_prompt 1)" != "$(_nt_prompt 2)" ] && echo distinct)" "distinct"
  # Anything that is not one of the four rows prints nothing rather than
  # guessing — same discipline as `hint`.
  ck prompt-none  "$(env -u NOTES_SELFTEST sh "$0" prompt)"   ""
  ck prompt-oob   "$(env -u NOTES_SELFTEST sh "$0" prompt 9)" ""
  # THE POINT OF THE STRING: it advertises the way out. Without this the wording
  # could drift back to a bare "note 4>" with every other check still green.
  ck prompt-names-esc "$(_nt_prompt 4 | grep -c 'esc=cancel')" "1"
  # A COMMA would split `command-prompt -p` into TWO prompts (man tmux).
  ck prompt-no-comma  "$(_nt_prompt 4 | tr -cd ',' | wc -c | tr -d ' ')" "0"

  # --- tmux-touching blocks ------------------------------------------------
  # Isolated under a throwaway TMUX_TMPDIR, reaped by the EXIT trap below —
  # the user's shared /tmp/tmux-<uid>/ must never be used:
  # kill-server ends the process but macOS leaves the socket FILE behind, so a
  # selftest socket name would strand an orphan every run. Short literal dir:
  # a mktemp -d path plus a socket name can exceed the 104-char AF_UNIX limit.
  if command -v tmux >/dev/null 2>&1; then
    _ot=${TMUX_TMPDIR-}; _ot_set=${TMUX_TMPDIR+set}
    _otm=${TMUX-}; _otm_set=${TMUX+set}
    # Captured ONCE and never reassigned — this, not the live TMUX_TMPDIR
    # variable, is what _nt_st_cleanup removes. See the footgun below.
    _nt_st_dir=/tmp/nt$$
    TMUX_TMPDIR=$_nt_st_dir; export TMUX_TMPDIR; mkdir -p "$TMUX_TMPDIR"
    _sk=nt$$
    # Reap the throwaway dir/server and restore TMUX*/TMUX_TMPDIR, so the
    # fall-through at the end of this block is not the only path that cleans
    # up (1387 dirs leaked before this was a trap).
    #
    # Coverage is shell-dependent and deliberately NOT total: /bin/sh (bash
    # in POSIX mode) runs an EXIT trap when it dies from an untrapped SIGINT,
    # but dash does NOT — so under CI's dash, a Ctrl-C here strands one
    # /tmp/nt$$. That is accepted: it is non-destructive, and it is specific
    # to POSIX-sh scripts run under dash. It does NOT match bin/amux's
    # behaviour — bin/amux is bash, and bash DOES fire its EXIT trap on an
    # untrapped SIGINT, so it never strands anything this way. The shared
    # precedent with bin/amux is only the trap-LIST shape (EXIT only, no
    # INT/TERM); see the next paragraph for why that shape, not this
    # dash-specific stranding, is what's being followed.
    #
    # Do NOT "fix" it by adding INT TERM to the trap list. That is the
    # tempting move and it caused a Critical: a handler that does not itself
    # exit lets POSIX sh RESUME after it, so cleanup ran twice — and the
    # second run, operating on the already-restored values, rm -rf'd the
    # USER'S real TMUX_TMPDIR and left $TMUX pointing at a live server while
    # child processes were still writing. The idempotency guard below now
    # makes a double call harmless, but EXIT-only is what keeps the resume
    # from happening at all. A stranded temp dir is the cheaper failure.
    #
    # EXIT-only, and idempotent by construction — this function MUST be safe
    # to call twice. POSIX sh resumes execution after a trap handler that
    # doesn't itself exit, so an `INT TERM` trap list here would run this
    # function once from the signal and again from the explicit call near the
    # end of this block. A prior version restored TMUX_TMPDIR to the user's
    # real value on its first call and then `rm -rf`'d "$TMUX_TMPDIR" on its
    # second call — deleting the user's REAL socket directory. Two
    # independent fixes close that for good: `_nt_st_dir` is captured once and
    # never touched by the restore lines, so the `rm -rf` target can never
    # become the user's real dir even if this runs N times; and the
    # `_nt_st_done` guard makes every call after the first a no-op, so it's
    # safe even if a future edit reintroduces a signal trap.
    _nt_st_done=0
    _nt_st_cleanup() {
      [ "$_nt_st_done" = 1 ] && return 0
      _nt_st_done=1
      tmux -L "$_sk" kill-server 2>/dev/null
      rm -rf "$_nt_st_dir"
      if [ "$_otm_set" = set ]; then TMUX=$_otm; export TMUX; else unset TMUX; fi
      if [ "$_ot_set" = set ]; then TMUX_TMPDIR=$_ot; export TMUX_TMPDIR; else unset TMUX_TMPDIR; fi
    }
    trap '_nt_st_cleanup' EXIT

    tmux -L "$_sk" -f /dev/null new-session -d -s t 2>/dev/null
    _pane=$(tmux -L "$_sk" display-message -p '#{pane_id}' 2>/dev/null)
    _get() { tmux -L "$_sk" show-options -p -v -t "$_pane" "$1" 2>/dev/null; }
    _set() { tmux -L "$_sk" set-option -p -t "$_pane" "$1" "$2" 2>/dev/null; }

    # The subcommands under test are HOOK-PATH code: they call bare `tmux`
    # (no -L) and rely on $TMUX to resolve the server, exactly as they would
    # when tmux itself invokes them from a real key binding. This shell is not
    # attached to our throwaway session, so $TMUX must be faked to match it —
    # otherwise bare `tmux` falls back to resolving $TMUX (if this shell
    # already has a real one, e.g. this very test running inside a live
    # agentmux pane) or, failing that, socket name "default" (never "$_sk"),
    # so it would silently write into a DIFFERENT server: either a real live
    # session (verified: an early un-isolated run of this exact test wrote
    # @amux_note1 onto this session's own pane %0) or nothing at all. `-L`
    # always outranks $TMUX, so the `_get`/`_set` helpers above are unaffected
    # by the fake value. Save/restore mirrors the TMUX_TMPDIR pattern above.
    # The socket path is asked of tmux itself (single-sourced the same way
    # session_log.sh's tests do it) rather than hand-built from TMUX_TMPDIR's
    # layout, which is an assumption about tmux's internals, not a contract.
    _sk_real=$(tmux -L "$_sk" display-message -p '#{socket_path}' 2>/dev/null)
    TMUX="$_sk_real,0,0"; export TMUX

    # Every child invocation below strips NOTES_SELFTEST defensively: the
    # dispatch `case` above exits 0 on every spelled and misspelled
    # subcommand, but a future typo in a selftest child must not be able to
    # re-arm the fallthrough into this very selftest block with the flag
    # still inherited from this process's own environment.

    # render with no raws set -> hint on row 1, rows 2/3 emptied. Seed row 2
    # with a stale, non-empty value first: `show-options -v` on an unset user
    # option prints nothing, so asserting '' afterward would pass identically
    # whether render actually cleared it or it was simply never set.
    _set @amux_note2 stale
    env -u NOTES_SELFTEST sh "$0" render "$_pane" 2>/dev/null
    ck tm-hint1 "$(_get @amux_note1)" "$NT_HINT"
    ck tm-hint2 "$(_get @amux_note2)" ''

    # render escapes '#' from the raw into the display option.
    _set @amux_note_raw2 'fix #42'
    env -u NOTES_SELFTEST sh "$0" render "$_pane" 2>/dev/null
    ck tm-esc  "$(_get @amux_note2)" "${NT_MARK}fix ##42"
    ck tm-mark "$(_get @amux_note1)" "$NT_MARK"
    # The RAW option is never rewritten — it is the prefill source.
    ck tm-raw  "$(_get @amux_note_raw2)" 'fix #42'

    # render is idempotent: re-running must not double-escape.
    env -u NOTES_SELFTEST sh "$0" render "$_pane" 2>/dev/null
    ck tm-idem "$(_get @amux_note2)" "${NT_MARK}fix ##42"

    # toggle flips the mode flag on, then off.
    env -u NOTES_SELFTEST sh "$0" toggle "$_pane" 2>/dev/null
    ck tm-on   "$(_get @amux_notes)" '1'
    # Seed a value toggle-on would never itself produce, so the next assertion
    # proves toggle-off actually clears it rather than merely observing '1'
    # (from the line above) happening to already read as unset.
    _set @amux_notes stale
    env -u NOTES_SELFTEST sh "$0" toggle "$_pane" 2>/dev/null
    # Toggle-off must write an EXPLICIT pane-level "0", never `-up` unset —
    # see the toggle-case comment in notes.sh for why an unset falls through
    # to a wider-scope value the renderer can still see as on.
    ck tm-off  "$(_get @amux_notes)" '0'

    # BLOCKING regression: a GLOBAL @amux_notes 1 (the shape a user's
    # ~/.agentmux/user.agent.tmux.conf overlay would set — CLAUDE.md documents
    # that file as overriding our defaults) must not defeat toggle-off. Clear
    # the pane-level value first so the pane starts genuinely unset, then set
    # the global directly (not via `toggle`, which only ever writes
    # pane-level) so the pane's effective state is "on" via the global alone.
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_notes 2>/dev/null
    tmux -L "$_sk" set-option -g @amux_notes 1 2>/dev/null
    # Confirm the renderer's own test (#{?@amux_notes,…}) reads this pane as
    # ON before toggling — otherwise the assertions below would pass for the
    # wrong reason.
    ck tm-global-on-before \
      "$(tmux -L "$_sk" display-message -p -t "$_pane" '#{?@amux_notes,1,0}' 2>/dev/null)" '1'
    env -u NOTES_SELFTEST sh "$0" toggle "$_pane" 2>/dev/null
    # toggle wrote an explicit pane-level 0 …
    ck tm-global-off-pane "$(_get @amux_notes)" '0'
    # … and that pane-level 0 SHADOWS the still-set global 1 in the exact
    # format expression the renderer uses — this is the fix: the pane really
    # is off, not just "unset and inheriting on" again.
    ck tm-global-off-render \
      "$(tmux -L "$_sk" display-message -p -t "$_pane" '#{?@amux_notes,1,0}' 2>/dev/null)" '0'
    tmux -L "$_sk" set-option -ug @amux_notes 2>/dev/null
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_notes 2>/dev/null

    # A click on a NON-note range must not enter notes mode. On its own this
    # passes identically whether click does anything at all — see the row-4
    # assertion below for the positive counterpart.
    env -u NOTES_SELFTEST sh "$0" click "$_pane" 'window|@3' /dev/null 2>/dev/null
    ck tm-noclick "$(_get @amux_notes)" ''

    # THE RETIREMENT: a click on a SUMMARY row (1-3) while notes mode is OFF is
    # inert. It must not flip the mode, and must not write a note. Seed a value
    # the click would have to overwrite, so "unchanged" cannot pass by never
    # having been set.
    _set @amux_note_raw1 'keep me'
    env -u NOTES_SELFTEST sh "$0" click "$_pane" 'user|amuxnote1' /dev/null 2>/dev/null
    ck tm-inert-mode "$(_get @amux_notes)" ''
    ck tm-inert-raw  "$(_get @amux_note_raw1)" 'keep me'

    # In notes mode the SAME click is live again — the retirement must not
    # disable editing notes 1-3, only the mode-entering side effect.
    _set @amux_notes 1
    env -u NOTES_SELFTEST sh "$0" click "$_pane" 'user|amuxnote2' /dev/null 2>/dev/null
    ck tm-notes-mode-live "$(_get @amux_notes)" '1'
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_notes 2>/dev/null

    # GLOBAL-ON CASE: the click guard must read the SAME resolved value the
    # renderer uses — pane->window->session->global — not `show-options -p` +
    # `[ -n … ]`, which sees only the pane level (the scope half of the
    # truthiness/scope trap documented on `toggle` above). The real case this
    # guards against: a user's ~/.agentmux/user.agent.tmux.conf (sourced last
    # by every agent socket, CLAUDE.md: "user settings win over our defaults")
    # setting `set -g @amux_notes 1` must not leave rows 1-3 permanently inert.
    # Pane-level @amux_notes is already unset from the block above; set the
    # GLOBAL value directly — never via `click`/`toggle`, which only ever
    # write pane-level.
    tmux -L "$_sk" set-option -g @amux_notes 1 2>/dev/null
    # Confirm the guard's own resolved-value expression reads this pane as ON
    # before clicking — same non-vacuity discipline as tm-global-on-before
    # above — otherwise the assertion below could pass for the wrong reason.
    ck tm-click-global-on-before \
      "$(tmux -L "$_sk" display-message -p -t "$_pane" '#{?@amux_notes,1,0}' 2>/dev/null)" '1'
    # Seed a raw note and a STALE display value: only a click that actually
    # passes the guard and runs _nt_render can turn "stale" back into the
    # freshly-rendered value asserted below.
    _set @amux_note_raw1 'global click lives'
    _set @amux_note1 stale
    env -u NOTES_SELFTEST sh "$0" click "$_pane" 'user|amuxnote1' /dev/null 2>/dev/null
    ck tm-click-global-live "$(_get @amux_note1)" "${NT_MARK}global click lives"
    tmux -L "$_sk" set-option -ug @amux_notes 2>/dev/null
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_notes 2>/dev/null
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_note_raw1 2>/dev/null
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_note1 2>/dev/null

    # LITERAL-"0" CASE: the other half of the same trap. `[ -n … ]` reads the
    # literal string "0" as true (it is non-empty); `#{?…}` — what the guard
    # and status-format both use — reads "0" as FALSE. Set @amux_notes to the
    # literal "0" at the PANE level (the scope the guard resolves first),
    # confirm the guard's own expression already reads it as off, then assert
    # the click stays inert.
    _set @amux_notes 0
    ck tm-click-literal-zero-before \
      "$(tmux -L "$_sk" display-message -p -t "$_pane" '#{?@amux_notes,1,0}' 2>/dev/null)" '0'
    _set @amux_note_raw1 'literal-zero-check'
    _set @amux_note1 stale
    env -u NOTES_SELFTEST sh "$0" click "$_pane" 'user|amuxnote1' /dev/null 2>/dev/null
    # If it had run, _nt_render would have turned "stale" into the marked raw
    # (as in tm-click-global-live above) — staying "stale" is what proves the
    # guard exited before render ran.
    ck tm-click-literal-zero-inert "$(_get @amux_note1)" stale
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_notes 2>/dev/null
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_note_raw1 2>/dev/null
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_note1 2>/dev/null

    # Row 4 is live in SUMMARY mode (that is the point) and must NOT flip the
    # mode flag. Safe on this clientless throwaway server: command-prompt's
    # target client ("/dev/null") can't resolve, so it errors (suppressed)
    # rather than hanging, and everything before it in `click` still runs.
    env -u NOTES_SELFTEST sh "$0" click "$_pane" 'user|amuxnote4' /dev/null 2>/dev/null
    ck tm-r4-click-mode "$(_get @amux_notes)" ''
    # THE POPUP IS BEST-EFFORT. This click's target client is "/dev/null", so
    # display-popup cannot open — and the click must still complete rather than
    # hang or bail before the prompt. Two things prove it did: the mode flag
    # above was reached and left alone, and no @amux_popup was left behind (a
    # stale 1 would tell every reader a popup is on screen when none is).
    # The real popup path — it opens, it takes the keyboard, one key closes it,
    # the prompt then opens — is only reachable with a genuinely attached
    # client, so it lives in tests/mouse (check 11).
    ck tm-r4-nopopup "$(tmux -L "$_sk" show-options -qv @amux_popup 2>/dev/null)" ''
    # The path `click` builds for the popup must actually exist next to this
    # file; the guard above turns a missing one into a silent no-popup click.
    ck tm-popup-file "$([ -r "$(dirname "$0")/note_popup.sh" ] && echo yes)" yes
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_note_raw1 2>/dev/null

    # Slot 4 renders from its own raw, and does so in SUMMARY mode (the mode
    # flag was unset just above) — the row is mode-independent by design.
    _set @amux_note_raw4 'ship it'
    env -u NOTES_SELFTEST sh "$0" render "$_pane" 2>/dev/null
    ck tm-r4      "$(_get @amux_note4)" "${NT_MARK}ship it"
    ck tm-r4raw   "$(_get @amux_note_raw4)" 'ship it'
    # Independence: slot 4's content must not suppress row 1's own hint. Rows
    # 1-3 are empty here except raw2, set earlier — clear it first so the
    # rows-1-3 empty-state is the thing under test.
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_note_raw2 2>/dev/null
    env -u NOTES_SELFTEST sh "$0" render "$_pane" 2>/dev/null
    ck tm-r4-indep "$(_get @amux_note1)" "$NT_HINT"
    ck tm-r4-still "$(_get @amux_note4)" "${NT_MARK}ship it"
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_note_raw4 2>/dev/null
    env -u NOTES_SELFTEST sh "$0" render "$_pane" 2>/dev/null
    ck tm-r4-hint "$(_get @amux_note4)" "$NT_HINT4"

    # --- the button: copy+clear, then undo -----------------------------------
    # Driven through the real `click` entry point, not by calling the helpers, so
    # the range dispatch is exercised too.
    _set @amux_note_raw4 'ship it'
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_note_raw_prev4 2>/dev/null
    env -u NOTES_SELFTEST sh "$0" render "$_pane" 2>/dev/null
    ck tm-btn-copy-shown "$(_get @amux_btn4)" "$NT_COPY"
    env -u NOTES_SELFTEST sh "$0" click "$_pane" 'user|amuxcopy4' /dev/null 2>/dev/null
    ck tm-btn-cleared "$(_get @amux_note_raw4)" ''
    ck tm-btn-prev    "$(_get @amux_note_raw_prev4)" 'ship it'
    # The tmux paste buffer is the backstop that makes the destructive clear
    # safe, so assert the text actually landed there — not merely that the note
    # went away.
    ck tm-btn-buffer  "$(tmux -L "$_sk" show-buffer 2>/dev/null)" 'ship it'
    ck tm-btn-row     "$(_get @amux_note4)" "$NT_HINT4"
    ck tm-btn-undo-shown "$(_get @amux_btn4)" "$NT_UNDO"
    # Second press restores it …
    env -u NOTES_SELFTEST sh "$0" click "$_pane" 'user|amuxcopy4' /dev/null 2>/dev/null
    ck tm-btn-restored "$(_get @amux_note_raw4)" 'ship it'
    # … and spends the undo, so the button cannot flip-flop forever.
    ck tm-btn-prev-spent "$(_get @amux_note_raw_prev4)" ''
    ck tm-btn-back-to-copy "$(_get @amux_btn4)" "$NT_COPY"
    # A blank slot is a no-op, not a crash or a stray write.
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_note_raw4 2>/dev/null
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_note_raw_prev4 2>/dev/null
    env -u NOTES_SELFTEST sh "$0" render "$_pane" 2>/dev/null
    env -u NOTES_SELFTEST sh "$0" click "$_pane" 'user|amuxcopy4' /dev/null 2>/dev/null
    ck tm-btn-noop    "$(_get @amux_note_raw4)" ''
    ck tm-btn-noop-b  "$(_get @amux_btn4)" "$NT_BTN_NONE"


    # The summary options are never touched by any of the above.
    _set @amux_row1 'ai summary'
    env -u NOTES_SELFTEST sh "$0" render "$_pane" 2>/dev/null
    ck tm-rowsafe "$(_get @amux_row1)" 'ai summary'

    _nt_st_cleanup
    trap - EXIT
  fi

  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

exit 0
