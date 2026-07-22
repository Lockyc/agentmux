# agentmux — task runner
#
# Thin wrapper: `test.sh` is the aggregate gate (shellcheck + `fish -n` + every
# selftest) and stays the single source of truth for what the gate runs. This file
# only gives it the house `just gate` name — it must never re-encode the target list
# or the benign-finding filter that live in test.sh.
#
# For a targeted run while changing one script, invoke that script's own selftest
# directly with its VAR=1 form — see CLAUDE.md "Selftests".

# `default` pipes `just --list` through a small stock-perl filter that clips long recipe
# docs to your terminal width (…) instead of wrapping. Self-contained — no external files;
# falls back to plain `just --list` where perl is absent. Edit the recipes below, not this.
# List available recipes
default:
    @if command -v perl >/dev/null 2>&1; then just --color always --list | perl -CS -Mutf8 -lpe 'BEGIN{($w)=`stty size 2>/dev/null </dev/tty`=~/ (\d+)/; $w||=100; $col=(-t STDOUT && !exists $ENV{NO_COLOR})} s/\e\[[0-9;]*m//g unless $col; (my $v=$_)=~s/\e\[[0-9;]*m//g; if(length($v)>$w){my($o,$n)=("",0); while(length && $n<$w-1){ if($col && s/^(\e\[[0-9;]*m)//){$o.=$1}else{s/^(.)//;$o.=$1;$n++} } $_=$o."…".($col?"\e[0m":"")}'; else just --list; fi

# Non-mutating pre-merge gate: shellcheck + fish -n + every selftest (delegates to test.sh)
gate:
    bash test.sh

# Micro-benchmark the presence-probe hot path: cost of `dropped --pending` for a cwd that is
# NOT in the ledger (the common `[[window.root]]` case) vs one that IS, over a large synthetic
# ledger. warden forks this per session-less tab every 5s; `sl_dropped`'s fast-path gate
# short-circuits the absent-from-ledger case. The recipe IS the generator (seeds its own ledger).
bench:
    #!/usr/bin/env bash
    set -euo pipefail
    dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
    export AGENTMUX_STATE_DIR="$dir" AGENTMUX_SESSION_LOG=1
    ledger="$dir/sessions.jsonl"; : > "$ledger"
    # 60 dead-server windows across 60 distinct dirs (/w/p1../w/p60).
    for i in $(seq 1 60); do
      printf '{"ts":%d,"event":"open","socket_path":"/s/%d","server_pid":%d,"session":"p%d","window_id":"@1","window_name":"claude","cwd":"/w/p%d","agent":"work"}\n' $((100+i)) "$i" $((9000+i)) "$i" "$i" >> "$ledger"
      printf '{"ts":%d,"event":"resume","socket_path":"/s/%d","server_pid":%d,"window_id":"@1","label":"d%d","resume_cmd":"claude --resume d%d"}\n' $((101+i)) "$i" $((9000+i)) "$i" "$i" >> "$ledger"
    done
    echo "ledger lines: $(wc -l < "$ledger")"; runs=50
    echo "== absent cwd (/w/does-not-exist) x$runs =="
    time for _ in $(seq $runs); do SESSION_LOG_BOOT_EPOCH=1 sh scripts/session_log.sh dropped --pending /w/does-not-exist >/dev/null; done
    echo "== present cwd (/w/p30) x$runs =="
    time for _ in $(seq $runs); do SESSION_LOG_BOOT_EPOCH=1 sh scripts/session_log.sh dropped --pending /w/p30 >/dev/null; done
