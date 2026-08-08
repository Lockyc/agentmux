# agentmux.fish — shell integration for agentmux (fish).
# Source from ~/.config/fish/config.fish:
#   source ~/.agentmux/shell/agentmux.fish
#
# Thin wrapper: all amux logic lives in bin/amux. This file only defines the
# `amux` function and wires fish tab-completion.
#
# Override the executable path: set -gx AGENTMUX_BIN <path>

set -q AGENTMUX_BIN; or set -g AGENTMUX_BIN $HOME/.agentmux/bin/amux

function amux --description 'agentmux session launcher'
    command $AGENTMUX_BIN $argv
end

# Disable file completion for amux (session names are free-form, not paths),
# so non-first arguments offer nothing — matching the zsh completer, which
# adds candidates only at CURRENT == 2.
complete -c amux -f
# Complete agent names + -<flag> shortcuts only as the first argument.
# __fish_is_first_arg counts tokens without stripping flags, so (unlike
# __fish_is_nth_token) it mirrors zsh's strict CURRENT == 2: `amux -p <tab>`
# is the session-name slot and offers nothing.
complete -c amux -f -n '__fish_is_first_arg' -a '($AGENTMUX_BIN --complete)'
# Remote hosts complete as whole @tokens in the first-arg slot, beside agents.
complete -c amux -f -n '__fish_is_first_arg' -a '($AGENTMUX_BIN --complete-hosts)'
# Second arg after an @host token is a project on that host, from the local
# completion cache only (a live call would hang the shell on a slow host).
complete -c amux -f -n 'string match -qr "^@" -- (commandline -opc)[2]' \
  -a '($AGENTMUX_BIN --complete-remote (string replace -r "^@" "" (commandline -opc)[2]))'
# After --kill / --frame-kill / --probe / attach, complete live agentmux session names
# (the second arg). The -all variants are distinct tokens, so they don't trigger this.
complete -c amux -f -n '__fish_seen_subcommand_from --kill --frame-kill --probe attach' -a '($AGENTMUX_BIN --complete-sessions)'
