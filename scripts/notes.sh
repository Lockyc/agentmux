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

# Mode indicator, leading row 1 whenever notes mode is on.
NT_MARK='✎ '
# Shown on row 1 when notes mode is on and all three notes are empty. Carries a
# style directive of OUR OWN — added after escaping, never escaped itself.
NT_HINT='#[fg=colour240]✎ click a row to write a note'
# Shown on row 4 (the always-on note line) when slot 4 is empty. Separate from
# NT_HINT because the two empty-states are independent: NT_HINT is about slots
# 1-3 and only ever appears in notes mode, while this one is on screen from
# launch and is the discovery path into writing a note at all. Carries a style
# directive of OUR OWN — added after escaping, never escaped itself.
NT_HINT4='#[fg=colour240]✎ click to add a note'

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
  case "$_d_r" in
    # NT_MARK is prepended AFTER escaping: it is our directive, not user text.
    1) printf '%s%s' "$NT_MARK" "$(_nt_esc "$_d_1")" ;;
    2) _nt_esc "$_d_2" ;;
    3) _nt_esc "$_d_3" ;;
  esac
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
  tmux refresh-client -S 2>/dev/null
}

case "${1:-}" in
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
    # Not one of our ranges (window list, status-left): do nothing. The binding
    # already routed the default behaviour elsewhere.
    [ -n "$_cp" ] && [ -n "$_cr" ] || exit 0
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
    tmux command-prompt -t "$_ct" -l -I "$(_nt_raw "$_cp" "$_cr")" -p "note $_cr>" \
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
  ck disp-r2     "$(_nt_display 2 'deploy blocked' 'ask sam' '' '')" 'ask sam'
  ck disp-r3     "$(_nt_display 3 'deploy blocked' 'ask sam' '' '')" ''
  # Row 1 empty but others filled: mark still shows, so the mode stays visible.
  ck disp-mark   "$(_nt_display 1 '' 'ask sam' '' '')" "$NT_MARK"
  # Escaping is applied by _nt_display, on user text only.
  ck disp-esc    "$(_nt_display 2 '' 'fix #42' '' '')" 'fix ##42'
  ck disp-esc1   "$(_nt_display 1 'PR #7' '' '' '')"   "${NT_MARK}PR ##7"

  # Feeding display output back in DOES double-escape — which is exactly why
  # the raw text is kept in a separate option and _nt_display is only ever
  # given raws. This asserts the hazard is real, so the two-option split can
  # never be "simplified" away without a red test.
  ck disp-reesc  "$(_nt_display 2 '' "$(_nt_display 2 '' 'fix #42' '' '')" '' '')" 'fix ####42'

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
    ck tm-esc  "$(_get @amux_note2)" 'fix ##42'
    ck tm-mark "$(_get @amux_note1)" "$NT_MARK"
    # The RAW option is never rewritten — it is the prefill source.
    ck tm-raw  "$(_get @amux_note_raw2)" 'fix #42'

    # render is idempotent: re-running must not double-escape.
    env -u NOTES_SELFTEST sh "$0" render "$_pane" 2>/dev/null
    ck tm-idem "$(_get @amux_note2)" 'fix ##42'

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
