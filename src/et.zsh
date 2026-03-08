#!/usr/bin/env zsh

# emacs-tmux-openfile — open a file in a running Emacs from within tmux.
#
# Defines __emacs-tmux-openfile.et, the real implementation of the et command.
# Sourced by emacs-tmux-openfile.plugin.zsh on first call; also executable
# directly as a script.

function __emacs-tmux-openfile._usage() {
  local cmd=$1 fd=$2
  print -u $fd -r -- "${cmd} — open a file in a running Emacs session from within the current tmux window"
  print -u $fd -r -- ""
  print -u $fd -r -- "usage: ${cmd} [-k] FILE"
  print -u $fd -r -- "       ${cmd} --cmdfile"
  print -u $fd -r -- "       ${cmd} --list"
  print -u $fd -r -- ""
  print -u $fd -r -- "options:"
  print -u $fd -r -- "  -k, --keep-focus  do not move focus to the Emacs pane after opening"
  print -u $fd -r -- "      --cmdfile     print the IPC file path for this tmux window and exit"
  print -u $fd -r -- "      --list        list all tmux panes with index, id, command, and tty"
  print -u $fd -r -- "  -h, --help        show this help message"
}

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

  if [[ $opt == "-h" || $opt == "--help" ]]; then
    __emacs-tmux-openfile._usage "$cmd" 1
    return 0
  fi

  if [[ $opt == "--list" ]]; then
    command tmux list-panes -F $'#{pane_index}\t#{pane_id}\t#{pane_current_command}\t#{pane_tty}'
    return 0
  fi

  local stack
  stack=$(command tmux show-options -w -qv @emacs_openfile_stack 2>/dev/null || true)
  local cmdfile=${stack%%$'\x1f'*}
  local paneid=${${${cmdfile:t}%.cmd}##*-}

  if [[ $opt == "--cmdfile" ]]; then
    [[ -n $cmdfile ]] || return 1
    print -r -- "$cmdfile"
    return 0
  fi

  local file=${1-}
  if [[ -z $file ]]; then
    __emacs-tmux-openfile._usage "$cmd" 2
    return 2
  fi

  [[ -n $cmdfile ]] || {
    print -u2 "${cmd}: error: no Emacs session registered in this tmux window"
    print -u2 "${cmd}: hint: load tmux-openfile.el and run M-x tmux-openfile-enable"
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

  local active_cmd
  active_cmd=$(command tmux display-message -t "$paneid" -p '#{pane_current_command}' 2>/dev/null || true)
  [[ $active_cmd == emacs* ]] || {
    print -u2 "${cmd}: error: pane $paneid is no longer running Emacs (found: ${active_cmd:-nothing})"
    print -u2 "${cmd}: hint: run '${cmd} --list' to see all panes in this tmux window"
    return 1
  }

  # In-place update (no temp+rename) so Emacs file-notify watches keep working.
  print -r -- "$file" >| "$cmdfile"

  # Move focus to the Emacs pane (unless --keep-focus was given).
  if [[ $keep_focus -eq 0 ]]; then
    [[ -n $paneid ]] && command tmux select-pane -t "$paneid"
  fi
}

# Allow direct execution as a script (not sourced as a plugin).
[[ "$ZSH_EVAL_CONTEXT" == *:file* ]] || __emacs-tmux-openfile.et "${0:t}" "$@"
