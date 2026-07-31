# lib.tcl — shared driver for the expect status-bar-note suite.
#
# Sourced by main.exp and frame.exp. run.sh has already built the isolated
# servers and asserted the two setup traps; this file only drives clicks and
# asserts on tmux OPTION VALUES.
#
# WHY NO SCREEN EMULATOR. Reading the rendered status bar would need a VT
# emulator in Tcl. It is not needed: every
# positional claim ("this click hit ROW 2") is proved by typing text that is
# DISTINCT PER ROW and reading back which @amux_note_rawN it landed in — an
# assertion on tmux's own state, not on a repaint we re-simulated. The pty
# stream is still used, but only for what expect is actually good at: waiting
# for a byte sequence to appear (the `note N>` prompt) with a timeout, and
# grepping the whole transcript for a string that must never appear
# ("needs tmux 3.6+"). Neither needs a cursor model.
#
# SYNCHRONISATION IS POLLED, NOT SLEPT, wherever the state is observable:
#   waitopt   polls a tmux option until it takes an expected value
#   wp        waits for the prompt's bytes on the pty (expect's own timeout)
#   pane_echo polls capture-pane until typed text lands in the PANE
# The one place polling cannot see the state is "tmux has finished repainting
# after a command-prompt commit" — no option changes, no bytes are promised.
# `settle` covers it by consuming the pty until it has been QUIET for a second,
# which adapts to load rather than guessing. That is not cosmetic: clicking
# while the repaint is still in flight silently drops the click (measured — a
# click sent ~10ms after an Enter-commit produced no prompt at all, three runs
# out of three, and the same click after a settle produced one every time).

set mtroot  [lindex $argv 0]
set mtsockA [lindex $argv 1]
set mtsockB [lindex $argv 2]
set mtwork  [lindex $argv 3]
set mtout   [lindex $argv 4]

set mtres  "$mtout/results.tsv"
set mtlog  "$mtout/[file rootname [file tail $argv0]].pty.log"

set env(TERM) "xterm-256color"
set env(TMUX_TMPDIR) $mtwork
set env(AGENTMUX_STATE_DIR) "$mtwork/state"
unset -nocomplain env(TMUX)

log_user 0
match_max 400000
# -a: log_user is 0, and without -a expect logs nothing to the file either.
log_file -a -noappend $mtlog

# --- tmux plumbing ---------------------------------------------------------
# catch, so a tmux error surfaces as a failed assertion rather than killing the
# run with a Tcl stack trace.
proc tmA {args} { catch {exec tmux -L $::mtsockA {*}$args} out; return $out }
proc tmB {args} { catch {exec tmux -L $::mtsockB {*}$args} out; return $out }

# opt <name> [pane] — a PANE option read through the format chain, which is the
# same lookup status-format[1..3] uses.
proc opt {name {pane ""}} {
    if {$pane eq ""} { set pane $::mtpane }
    return [tmA display-message -p -t $pane "#{$name}"]
}

# render — run notes.sh's render as a HOOK-path caller would ($TMUX set), so the
# harness never reimplements the display-value computation it is asserting on.
proc render {{pane ""}} {
    if {$pane eq ""} { set pane $::mtpane }
    set sp [tmA display-message -p {#{socket_path}}]
    set ::env(TMUX) "$sp,0,0"
    catch {exec sh "$::mtroot/scripts/notes.sh" render $pane}
    unset ::env(TMUX)
}

# --- the edit prompt -------------------------------------------------------
# ASKED OF notes.sh, never restated here. Every prompt assertion below is an
# exact BYTE match on the pty — including prefill adjacency
# ("<prompt>fix #42", which is what proves -l's literal prefill is not
# comma-split) — so a literal in this file would be a second home for the string
# and would go stale the moment the product's wording changed, with the suite
# still red for a reason that looks like a product bug. Same single-sourcing
# run.sh already uses for `hint 4`. Resolved ONCE at load: four execs, not four
# per assertion.
foreach _r {1 2 3 4} {
    set PROMPT($_r) [exec sh "$mtroot/scripts/notes.sh" prompt $_r]
    if {$PROMPT($_r) eq ""} {
        puts stderr "scripts/notes.sh prompt $_r printed nothing — every prompt assertion would match the empty string"
        exit 2
    }
}
unset _r
proc promptstr {row} { return $::PROMPT($row) }

# --- pty driving -----------------------------------------------------------
proc settle {{secs 1}} { expect -timeout $secs -re {.+} {exp_continue} timeout {} }

# SGR mouse: 1-based col;row, button 0, press then release.
proc click {col row} {
    settle 1
    send -- "\033\[<0;$col;${row}M\033\[<0;$col;${row}m"
}

proc esc   {} { send -- "\033" }
proc enter {} { send -- "\r" }
proc typed {t} { send -- $t }

# wp <exact> — wait for the prompt's literal bytes. MATCH / TIMEOUT.
proc wp {s {secs 8}} { expect -timeout $secs -ex $s { return MATCH } timeout { return TIMEOUT } }

# noprompt — assert NO note prompt appears within <secs>. Returns 1 if none did.
# All four rows are matched, from the product's own strings (see promptstr): a
# hand-written regex here would stop matching the moment the wording changed and
# this check would then pass VACUOUSLY, reporting "no prompt opened" for a prompt
# that did open.
proc noprompt {{secs 3}} {
    expect -timeout $secs \
        -ex [promptstr 1] { return 0 } \
        -ex [promptstr 2] { return 0 } \
        -ex [promptstr 3] { return 0 } \
        -ex [promptstr 4] { return 0 } \
        timeout { return 1 }
}

# waitopt — poll an option until it equals <want>. Returns polls used, or -1.
proc waitopt {name want {pane ""} {tries 120}} {
    for {set i 0} {$i < $tries} {incr i} {
        if {[opt $name $pane] eq $want} { return $i }
        after 100
    }
    return -1
}

# pane_echo — type <token> + Enter and poll the PANE's contents for it. Proves
# the keystrokes reached the pane's shell, i.e. that no command-prompt is open
# to swallow them. A positive, bounded check; the alternative ("the option did
# not change") passes identically when the click never happened.
proc pane_echo {token {pane ""} {tries 80}} {
    if {$pane eq ""} { set pane $::mtpane }
    send -- "$token\r"
    for {set i 0} {$i < $tries} {incr i} {
        if {[string match "*$token*" [tmA capture-pane -p -t $pane]]} { return 1 }
        after 100
    }
    return 0
}

# logtext — the whole pty transcript, for "this string never appeared" checks.
proc logtext {} {
    if {![file exists $::mtlog]} { return "" }
    set f [open $::mtlog rb]
    set d [read $f]
    close $f
    return $d
}

# --- geometry --------------------------------------------------------------
# DERIVED ARITHMETICALLY, then VERIFIED by clicking (see main.exp's preflight).
# With the status bar at the bottom of an H-row client showing N status lines,
# status-format[0] sits on line H-N+1 and status-format[K] on H-N+1+K. Note
# that #{status_lines} does NOT exist as a format variable in tmux 3.7b (it
# expands to the empty string, indistinguishably from a real empty value), so N
# is taken as client_height - window_height.
#
# <top> is the 0-based screen line the client's own top edge sits on: 0 for a
# client attached straight to a terminal, and the containing pane's #{pane_top}
# for a client nested inside another tmux (the framed case).
proc rowline {k height nstatus {top 0}} {
    return [expr {$top + $height - $nstatus + 1 + $k}]
}
proc wlline {height nstatus {top 0}} {
    return [expr {$top + $height - $nstatus + 1}]
}

# --- check bookkeeping -----------------------------------------------------
set mtfail 0

proc chk {num name} {
    set ::cnum $num
    set ::cname $name
    set ::cok 1
    set ::cdetail {}
}
proc eq {label got want} {
    set good [expr {$got eq $want}]
    if {!$good} { set ::cok 0 }
    lappend ::cdetail [format "%-4s %s: got\[%s\] want\[%s\]" [expr {$good ? "ok" : "FAIL"}] $label $got $want]
    return $good
}
proc ok {label cond {got ""}} {
    set good [expr {$cond ? 1 : 0}]
    if {!$good} { set ::cok 0 }
    lappend ::cdetail [format "%-4s %s%s" [expr {$good ? "ok" : "FAIL"}] $label \
        [expr {$got eq "" ? "" : " -> $got"}]]
    return $good
}
proc note {label} { lappend ::cdetail "..   $label" }

proc chkend {} {
    set tag [expr {$::cok ? "PASS" : "FAIL"}]
    if {!$::cok} { incr ::mtfail }
    set f [open $::mtres a]
    puts $f "$::cnum\t$::cname\t$tag"
    close $f
    puts stderr [format "\n  \[%s\] %3s  %s" $tag [expr {$::cnum == 0 ? "pre" : $::cnum}] $::cname]
    foreach d $::cdetail {
        if {[string match "FAIL*" $d] || [info exists ::env(AMUX_MOUSE_VERBOSE)]} {
            puts stderr "          $d"
        }
    }
    return $::cok
}

# --- state -----------------------------------------------------------------
set SUMMARY(1) "ROWONE-AAA"
set SUMMARY(2) "ROWTWO-BBB"
set SUMMARY(3) "ROWTHREE-CCC"

proc reset_to_summary {} {
    foreach i {1 2 3 4} {
        tmA set-option -up -t $::mtpane "@amux_note_raw$i"
        tmA set-option -up -t $::mtpane "@amux_note$i"
    }
    foreach i {1 2 3} {
        tmA set-option -p  -t $::mtpane "@amux_row$i" $::SUMMARY($i)
    }
    tmA set-option -up -t $::mtpane @amux_notes
    # DELIBERATELY DOES NOT RENDER. Unsetting the pane-level options leaves the
    # pane in exactly the state a freshly launched tab is in: nothing has ever
    # called notes.sh on it, so row 4's value comes from the SESSION-level
    # @amux_note4 default run.sh publishes the way bin/amux does at launch.
    # A render here would MASK the launch state — it writes a pane-level
    # @amux_note4 and every "row 4 shows its hint" assertion would then pass
    # whether or not the product puts the hint on screen by itself, which is
    # precisely the bug that shipped. Any check that needs rows 1-3 rendered
    # calls `notes_mode` (which renders) or `render` explicitly.
}

# Enter notes mode. Rows 1-3 are click-INERT while the summaries are up (the
# click that used to enter this mode was retired), so any test that clicks rows
# 1-3 must come through here first. Sets the flag directly rather than sending
# `prefix N`: the key is a separate surface with its own test, and going through
# it would make every note test depend on it.
proc notes_mode {} {
    tmA set-option -p -t $::mtpane @amux_notes 1
    render
}
