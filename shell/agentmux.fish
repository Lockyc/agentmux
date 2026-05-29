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
