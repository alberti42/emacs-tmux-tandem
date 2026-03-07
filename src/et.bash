#!/usr/bin/env bash

# emacs-tmux-openfile — open a file in a running Emacs from within tmux.
#
# Defines __emacs-tmux-openfile.et, the real implementation of the et command.
# Sourced by emacs-tmux-openfile.plugin.bash on first call; also executable
# directly as a script.
#
# Note: set -euo pipefail is intentionally omitted from the function body.
# In bash, unlike zsh, shell options set inside a function affect the whole
# session. Errors are handled explicitly instead.

__emacs-tmux-openfile.et() {
  local cmd=$1; shift

  [[ -n ${TMUX-} ]] || { printf '%s\n' "${cmd}: error: not inside tmux" >&2; return 1; }

  local keep_focus=0
  local opt=${1-}

  if [[ $opt == "-k" || $opt == "--keep-focus" ]]; then
    keep_focus=1
    shift
  fi

  opt=${1-}

  if [[ $opt == "--list" ]]; then
    tmux list-panes -F $'#{pane_index}\t#{pane_id}\t#{pane_current_command}\t#{pane_tty}'
    return 0
  fi

  local cmdfile
  cmdfile=$(tmux show-options -w -qv @emacs_openfile_cmdfile 2>/dev/null || true)
  cmdfile=${cmdfile%$'\n'}

  if [[ $opt == "--cmdfile" ]]; then
    [[ -n $cmdfile ]] || return 1
    printf '%s\n' "$cmdfile"
    return 0
  fi

  local file=${1-}
  if [[ -z $file ]]; then
    printf '%s\n' "usage: ${cmd} [-k] FILE" >&2
    printf '%s\n' "       ${cmd} --cmdfile" >&2
    printf '%s\n' "       ${cmd} --list" >&2
    printf '%s\n' "options:" >&2
    printf '%s\n' "  -k, --keep-focus  do not move focus to the Emacs pane after opening" >&2
    return 2
  fi

  [[ -n $cmdfile ]] || {
    printf '%s\n' "${cmd}: error: no @emacs_openfile_cmdfile set for this tmux window" >&2
    printf '%s\n' "${cmd}: hint: load tmux-openfile.el and run M-x tmux-openfile-enable, then start Emacs in a tty inside this tmux window" >&2
    return 1
  }

  # Security guard: symlink and ownership checks
  #
  # -f $cmdfile — it exists and is a regular file
  # ! -L $cmdfile — it is not a symlink (redundant with -f, but explicit)
  # -O $cmdfile — it is owned by the current user
  #
  # If an attacker managed to replace the IPC file with a symlink
  # pointing elsewhere, et would refuse to write to it.
  # Without the check, writing $file to a symlink could redirect
  # a write to an arbitrary path owned by the user.
  [[ -f $cmdfile && ! -L $cmdfile && -O $cmdfile ]] || {
    printf '%s\n' "${cmd}: error: unsafe cmdfile: $cmdfile" >&2
    return 1
  }

  # In-place update (no temp+rename) so Emacs file-notify watches keep working.
  printf '%s\n' "$file" >| "$cmdfile"

  # Move focus to the Emacs pane (unless --keep-focus was given).
  if [[ $keep_focus -eq 0 ]]; then
    local paneid
    paneid=$(tmux show-options -w -qv @emacs_openfile_paneid 2>/dev/null || true)
    paneid=${paneid%$'\n'}
    [[ -n $paneid ]] && tmux select-pane -t "$paneid"
  fi
}

# Allow direct execution as a script (not sourced as a plugin).
[[ "${BASH_SOURCE[0]}" != "$0" ]] || __emacs-tmux-openfile.et "${0##*/}" "$@"
