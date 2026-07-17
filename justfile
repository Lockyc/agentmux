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
