#!/usr/bin/env bash
# agentmux.sh — shell integration for agentmux (bash/zsh).
# Source from ~/.zshrc or ~/.bashrc:
#   source ~/.agentmux/shell/agentmux.sh
#
# Thin wrapper: all amux logic lives in bin/amux. This file only defines the
# `amux` function and wires zsh tab-completion.
#
# Override the executable path: export AGENTMUX_BIN=<path>

AGENTMUX_BIN="${AGENTMUX_BIN:-$HOME/.agentmux/bin/amux}"

amux() { "$AGENTMUX_BIN" "$@"; }

# Zsh completion: amux <tab> completes agent names and -<flag> shortcuts.
if [ -n "${ZSH_VERSION:-}" ]; then
  _amux_zsh_complete() {
    if (( CURRENT == 2 )); then
      local -a _amux_comps
      _amux_comps=("${(@f)$("$AGENTMUX_BIN" --complete 2>/dev/null)}")
      compadd -- "${_amux_comps[@]}"
    fi
  }
  compdef _amux_zsh_complete amux
fi
