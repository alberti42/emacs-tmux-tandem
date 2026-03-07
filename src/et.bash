#!/usr/bin/env bash

# emacs-tmux-openfile — open a file in a running Emacs from within tmux.
#
# Usable as a bash plugin function (sourced via emacs-tmux-openfile.plugin.bash)
# or executed directly as a script.
#
# Note: set -euo pipefail is intentionally omitted from the function body.
# In bash, unlike zsh, shell options set inside a function affect the whole
# session. Errors are handled explicitly instead.

et() {
  [[ -n ${TMUX-} ]] || { printf '%s\n' "${FUNCNAME[0]}: error: not inside tmux" >&2; return 1; }

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

  if [[ $opt == "--cmdfile" ]]; then
    [[ -n $cmdfile ]] || return 1
    printf '%s\n' "$cmdfile"
    return 0
  fi

  local file=${1-}
  if [[ -z $file ]]; then
    printf '%s\n' "usage: ${FUNCNAME[0]} [-k] FILE" >&2
    printf '%s\n' "       ${FUNCNAME[0]} --cmdfile" >&2
    printf '%s\n' "       ${FUNCNAME[0]} --list" >&2
    printf '%s\n' "options:" >&2
    printf '%s\n' "  -k, --keep-focus  do not move focus to the Emacs pane after opening" >&2
    return 2
  fi

  [[ -n $cmdfile ]] || {
    printf '%s\n' "${FUNCNAME[0]}: error: no @emacs_openfile_cmdfile set for this tmux window" >&2
    printf '%s\n' "${FUNCNAME[0]}: hint: load tmux-openfile.el and run M-x tmux-openfile-enable, then start Emacs in a tty inside this tmux window" >&2
    return 1
  }

  [[ -f $cmdfile && ! -L $cmdfile && -O $cmdfile ]] || {
    printf '%s\n' "${FUNCNAME[0]}: error: unsafe cmdfile: $cmdfile" >&2
    return 1
  }

  # In-place update (no temp+rename) so Emacs file-notify watches keep working.
  printf '%s\n' "$file" >| "$cmdfile"

  # Move focus to the Emacs pane (unless --keep-focus was given).
  if [[ $keep_focus -eq 0 ]]; then
    local paneid
    paneid=$(tmux show-options -w -qv @emacs_openfile_paneid 2>/dev/null || true)
    [[ -n $paneid ]] && tmux select-pane -t "$paneid"
  fi
}

# Allow direct execution as a script (not sourced as a plugin).
[[ "${BASH_SOURCE[0]}" != "$0" ]] || et "$@"
