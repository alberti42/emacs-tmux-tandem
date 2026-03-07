#!/usr/bin/env zsh

# emacs-tmux-openfile — open a file in a running Emacs from within tmux.
#
# Defines __emacs-tmux-openfile.et, the real implementation of the et command.
# Sourced by emacs-tmux-openfile.plugin.zsh on first call; also executable
# directly as a script.

function __emacs-tmux-openfile.et() {
  builtin emulate -LR zsh -o warn_create_global -o pipe_fail -o no_unset
  # Note: errexit (ERR_EXIT) is intentionally omitted. In zsh, ERR_EXIT exits
  # the shell process itself — not just the function — when a command fails,
  # even with LOCAL_OPTIONS set. Errors are handled explicitly instead.

  local cmd=$1; shift

  [[ -n ${TMUX-} ]] || { print -u2 "${cmd}: error: not inside tmux"; return 1; }

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
    print -r -- "$cmdfile"
    return 0
  fi

  local file=${1-}
  if [[ -z $file ]]; then
    print -u2 "usage: ${cmd} [-k] FILE"
    print -u2 "       ${cmd} --cmdfile"
    print -u2 "       ${cmd} --list"
    print -u2 "options:"
    print -u2 "  -k, --keep-focus  do not move focus to the Emacs pane after opening"
    return 2
  fi

  [[ -n $cmdfile ]] || {
    print -u2 "${cmd}: error: no @emacs_openfile_cmdfile set for this tmux window"
    print -u2 "${cmd}: hint: load tmux-openfile.el and run M-x tmux-openfile-enable, then start Emacs in a tty inside this tmux window"
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
    print -u2 "${cmd}: error: unsafe cmdfile: $cmdfile"
    return 1
  }

  # In-place update (no temp+rename) so Emacs file-notify watches keep working.
  print -r -- "$file" >| "$cmdfile"

  # Move focus to the Emacs pane (unless --keep-focus was given).
  if [[ $keep_focus -eq 0 ]]; then
    local paneid
    paneid=$(tmux show-options -w -qv @emacs_openfile_paneid 2>/dev/null || true)
    paneid=${paneid%$'\n'}
    [[ -n $paneid ]] && tmux select-pane -t "$paneid"
  fi
}

# Allow direct execution as a script (not sourced as a plugin).
[[ "$ZSH_EVAL_CONTEXT" == *:file* ]] || __emacs-tmux-openfile.et "${0:t}" "$@"
