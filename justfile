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

# Times `dropped --pending` (warden's per-tab presence poll) for a cwd with no drop vs one
# with a drop, first on the live-set sidecar fast path warden actually hits, then on the
# ledger fallback (AMUX_PENDING_NO_FAST=1). The config has no [log] table and the session
# log is not forced on, so `_sl_enabled` is timed as a real poll runs it. The recipe IS
# the generator (seeds its own ledger, sidecars and config).
# Micro-benchmark the presence-probe hot path (sidecar fast path vs ledger fallback)
bench:
    #!/usr/bin/env bash
    set -euo pipefail
    dir=$(mktemp -d); trap 'rm -rf "$dir"' EXIT
    export AGENTMUX_STATE_DIR="$dir" AGENTMUX_CONFIG="$dir/amux.toml" SESSION_LOG_BOOT_EPOCH=1
    unset AGENTMUX_SESSION_LOG
    printf '[[agents]]\nname = "work"\ncmd = "claude"\n' > "$AGENTMUX_CONFIG"
    ledger="$dir/sessions.jsonl"; : > "$ledger"; mkdir -p "$dir/live"
    # 60 dead-server windows across 60 distinct dirs (/w/p1../w/p60), each with the
    # live-set sidecar (+ .sock companion) its server wrote before it died.
    for i in $(seq 1 60); do
      printf '{"ts":%d,"event":"open","socket_path":"/s/%d","server_pid":%d,"session":"p%d","window_id":"@1","window_name":"claude","cwd":"/w/p%d","agent":"work"}\n' $((100+i)) "$i" $((9000+i)) "$i" "$i" >> "$ledger"
      printf '{"ts":%d,"event":"resume","socket_path":"/s/%d","server_pid":%d,"window_id":"@1","label":"d%d","resume_cmd":"claude --resume d%d"}\n' $((101+i)) "$i" $((9000+i)) "$i" "$i" >> "$ledger"
      side="$dir/live/$(printf '/s/%d' "$i" | cksum | cut -d' ' -f1)-$((9000+i)).windows"
      printf '@1\t/w/p%d\twork\t1\n' "$i" > "$side"; printf '/s/%d\n' "$i" > "$side.sock"
    done
    echo "ledger lines: $(wc -l < "$ledger" | tr -d ' '), sidecars: $(ls "$dir"/live/*.windows | wc -l | tr -d ' ')"
    for cwd in /w/p30 /w/does-not-exist; do
      echo "$cwd answers: '$(sh scripts/session_log.sh dropped --pending "$cwd")' (fast) / '$(AMUX_PENDING_NO_FAST=1 sh scripts/session_log.sh dropped --pending "$cwd")' (fallback)"
    done
    runs=50
    for mode in fast fallback; do
      nofast=""; [ "$mode" = fallback ] && nofast=1
      echo "== $mode: drop present (/w/p30) x$runs =="
      time for _ in $(seq $runs); do AMUX_PENDING_NO_FAST=$nofast sh scripts/session_log.sh dropped --pending /w/p30 >/dev/null; done
      echo "== $mode: no drop (/w/does-not-exist) x$runs =="
      time for _ in $(seq $runs); do AMUX_PENDING_NO_FAST=$nofast sh scripts/session_log.sh dropped --pending /w/does-not-exist >/dev/null; done
    done
