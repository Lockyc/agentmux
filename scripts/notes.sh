#!/bin/sh
# notes.sh — per-tab notes in the three summary status rows.
#
# The three rows (status-format[1..3]) show either the LM summary (@amux_rowN,
# pushed by tmux-status.sh) or the user's notes (@amux_noteN), chosen by the
# @amux_notes pane-option flag. This script owns the notes side only; it never
# touches @amux_rowN, so the summary pipeline runs untouched and toggling back
# shows a CURRENT summary rather than a stale one.
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
    *) : ;;
  esac
}

# _nt_esc <text> -> text with every '#' doubled.
# status-format re-parses the value it substitutes, so an unescaped '#' in a
# note ("fix #42", "PR #7") would be read as a format directive.
_nt_esc() {
  printf '%s' "$1" | sed 's/#/##/g'
}

# _nt_display <row> <raw1> <raw2> <raw3> -> the finished display string.
# All three raws are passed because row 1's content depends on whether ANY note
# exists (the empty-state hint replaces it when none do).
_nt_display() {
  _d_r=$1; _d_1=$2; _d_2=$3; _d_3=$4
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

# _nt_render <pane> — recompose all three display options from the raws.
# All three are rewritten every time because row 1's content depends on whether
# ANY note exists (the empty-state hint).
_nt_render() {
  _rp=$1
  _r1=$(_nt_raw "$_rp" 1); _r2=$(_nt_raw "$_rp" 2); _r3=$(_nt_raw "$_rp" 3)
  for _i in 1 2 3; do
    tmux set-option -p -t "$_rp" "@amux_note$_i" \
      "$(_nt_display "$_i" "$_r1" "$_r2" "$_r3")" 2>/dev/null
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
    if [ -n "$(tmux show-options -p -v -t "$_tp" @amux_notes 2>/dev/null)" ]; then
      tmux set-option -up -t "$_tp" @amux_notes 2>/dev/null
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
    # Resolve the pane to a PLACEHOLDER-FREE target before any of it reaches
    # the command-prompt TEMPLATE below. The binding passes #{pane_id}
    # (%0, %1, %2, …), and per `man tmux`: "the first occurrence of the string
    # `%%` and all occurrences of `%1` ... up to `%9`" inside that template are
    # replaced by the typed response — so `-t %1` silently becomes
    # `-t <whatever the user typed>` on every pane but %0, and both the
    # set-option and the run-shell re-render break the same way.
    # session:window.pane never collides with a %N token. Bail rather than
    # proceed with a broken target if it can't be resolved (e.g. the pane
    # vanished mid-click).
    _cg=$(tmux display-message -p -t "$_cp" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)
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
    # Clicking a SUMMARY row is the discovery path into notes mode.
    [ -n "$(tmux show-options -p -v -t "$_cp" @amux_notes 2>/dev/null)" ] || \
      tmux set-option -p -t "$_cp" @amux_notes 1 2>/dev/null
    _nt_render "$_cp"
    # A typed '"' terminates the set-option argument early and the command
    # errors, leaving the note unchanged — it fails safe. Not worth an escaping
    # layer for a scratchpad; see the spec's Known limitation.
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
    tmux command-prompt -t "$_ct" -l -I "$(_nt_raw "$_cp" "$_cr")" -p "note $_cr>" \
      "set-option -p -t '$_cg' @amux_note_raw$_cr \"%%%\" ; run-shell \"sh '$NT_SELF' render '$_cg'\"" \
      2>/dev/null
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
  ck disp-hint1  "$(_nt_display 1 '' '' '')" "$NT_HINT"
  ck disp-hint2  "$(_nt_display 2 '' '' '')" ''
  ck disp-hint3  "$(_nt_display 3 '' '' '')" ''

  # --- _nt_display: any content -> hint gone, mark leads row 1 -------------
  ck disp-r1     "$(_nt_display 1 'deploy blocked' 'ask sam' '')" "${NT_MARK}deploy blocked"
  ck disp-r2     "$(_nt_display 2 'deploy blocked' 'ask sam' '')" 'ask sam'
  ck disp-r3     "$(_nt_display 3 'deploy blocked' 'ask sam' '')" ''
  # Row 1 empty but others filled: mark still shows, so the mode stays visible.
  ck disp-mark   "$(_nt_display 1 '' 'ask sam' '')" "$NT_MARK"
  # Escaping is applied by _nt_display, on user text only.
  ck disp-esc    "$(_nt_display 2 '' 'fix #42' '')" 'fix ##42'
  ck disp-esc1   "$(_nt_display 1 'PR #7' '' '')"   "${NT_MARK}PR ##7"

  # Feeding display output back in DOES double-escape — which is exactly why
  # the raw text is kept in a separate option and _nt_display is only ever
  # given raws. This asserts the hazard is real, so the two-option split can
  # never be "simplified" away without a red test.
  ck disp-reesc  "$(_nt_display 2 '' "$(_nt_display 2 '' 'fix #42' '')" '')" 'fix ####42'

  # --- tmux-touching blocks ------------------------------------------------
  # Isolated under a throwaway TMUX_TMPDIR, reaped on every exit path via the
  # trap below — the user's shared /tmp/tmux-<uid>/ must never be used:
  # kill-server ends the process but macOS leaves the socket FILE behind, so a
  # selftest socket name would strand an orphan every run. Short literal dir:
  # a mktemp -d path plus a socket name can exceed the 104-char AF_UNIX limit.
  if command -v tmux >/dev/null 2>&1; then
    _ot=${TMUX_TMPDIR-}; _ot_set=${TMUX_TMPDIR+set}
    _otm=${TMUX-}; _otm_set=${TMUX+set}
    TMUX_TMPDIR=/tmp/nt$$; export TMUX_TMPDIR; mkdir -p "$TMUX_TMPDIR"
    _sk=nt$$
    # Reap the throwaway dir/server and restore TMUX*/TMUX_TMPDIR on EVERY
    # exit path, not just the fall-through at the end of this block — a
    # signal mid-block must not strand /tmp/nt$$ (exactly what leaked 1387
    # dirs before this was a trap).
    _nt_st_cleanup() {
      tmux -L "$_sk" kill-server 2>/dev/null
      rm -rf "$TMUX_TMPDIR"
      if [ "$_otm_set" = set ]; then TMUX=$_otm; export TMUX; else unset TMUX; fi
      if [ "$_ot_set" = set ]; then TMUX_TMPDIR=$_ot; export TMUX_TMPDIR; else unset TMUX_TMPDIR; fi
    }
    trap '_nt_st_cleanup' EXIT INT TERM

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
    ck tm-off  "$(_get @amux_notes)" ''

    # A click on a NON-note range must not enter notes mode. On its own this
    # passes identically whether click does anything at all — see tm-click
    # below for the positive counterpart that actually exercises the happy
    # path.
    env -u NOTES_SELFTEST sh "$0" click "$_pane" 'window|@3' /dev/null 2>/dev/null
    ck tm-noclick "$(_get @amux_notes)" ''

    # A click on an amuxnoteN range DOES enter notes mode. Safe on this
    # clientless throwaway server: command-prompt's target client ("/dev/null")
    # can't resolve, so it errors (suppressed) rather than hanging, and the
    # mode-flag flip that precedes it in `click` still runs.
    env -u NOTES_SELFTEST sh "$0" click "$_pane" 'user|amuxnote2' /dev/null 2>/dev/null
    ck tm-click "$(_get @amux_notes)" '1'
    # Reset so it doesn't leak into the rowsafe assertion below.
    tmux -L "$_sk" set-option -up -t "$_pane" @amux_notes 2>/dev/null

    # The summary options are never touched by any of the above.
    _set @amux_row1 'ai summary'
    env -u NOTES_SELFTEST sh "$0" render "$_pane" 2>/dev/null
    ck tm-rowsafe "$(_get @amux_row1)" 'ai summary'

    _nt_st_cleanup
    trap - EXIT INT TERM
  fi

  [ "$fail" = 0 ] && echo "selftest OK"
  exit "$fail"
fi

exit 0
