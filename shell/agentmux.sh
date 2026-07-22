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

# Zsh completion: amux <tab> completes agent names and -<flag> shortcuts; the
# session arg of --kill/--frame-kill/--probe/attach completes live agentmux session names.
if [ -n "${ZSH_VERSION:-}" ]; then
  _amux_zsh_complete() {
    if (( CURRENT == 2 )); then
      local -a _amux_comps
      # zsh-only block; shellcheck parses it as bash and misreads the (@f) flag.
      # shellcheck disable=SC2296
      _amux_comps=("${(@f)$("$AGENTMUX_BIN" --complete 2>/dev/null)}")
      compadd -- "${_amux_comps[@]}"
    elif (( CURRENT == 3 )); then
      # Second arg of --kill/--frame-kill/--probe/attach is a session name. A case (not a
      # zsh [[ == (a|b) ]] glob) keeps shellcheck — which parses this as bash — happy.
      # words is a zsh completion special array, set by the completion system.
      # shellcheck disable=SC2154
      case "${words[2]}" in
        --kill|--frame-kill|--probe|attach)
          local -a _amux_sess
          # shellcheck disable=SC2296
          _amux_sess=("${(@f)$("$AGENTMUX_BIN" --complete-sessions 2>/dev/null)}")
          compadd -- "${_amux_sess[@]}"
          ;;
      esac
    fi
  }
  compdef _amux_zsh_complete amux
fi
