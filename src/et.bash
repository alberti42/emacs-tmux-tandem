#!/usr/bin/env bash

# emacs-tmux-tandem — open a file in a running Emacs from within tmux.
#
# Defines __emacs-tmux-tandem.et, the real implementation of the et command.
# Sourced by emacs-tmux-tandem.plugin.bash on first call; also executable
# directly as a script.
#
# Note: set -euo pipefail is intentionally omitted from the function body.
# In bash, unlike zsh, shell options set inside a function affect the whole
# session. Errors are handled explicitly instead.

__emacs-tmux-tandem._usage() {
  local cmd=$1 fd=$2
  printf '%s\n' "${cmd} — open a file in a running Emacs session from within the current tmux window" >&$fd
  printf '%s\n' "" >&$fd
  printf '%s\n' "usage: ${cmd} [-k] FILE" >&$fd
  printf '%s\n' "       ${cmd}" >&$fd
  printf '%s\n' "       ${cmd} --cmdfile" >&$fd
  printf '%s\n' "       ${cmd} --list" >&$fd
  printf '%s\n' "" >&$fd
  printf '%s\n' "options:" >&$fd
  printf '%s\n' "  -k, --keep-focus  do not move focus to the Emacs pane after opening" >&$fd
  printf '%s\n' "      --cmdfile     print the IPC file path for this tmux window and exit" >&$fd
  printf '%s\n' "      --list        list all tmux panes with index, id, command, and tty" >&$fd
  printf '%s\n' "  -h, --help        show this help message" >&$fd
}

__emacs-tmux-tandem.et() {
  local cmd=$1; shift

  [[ -n ${TMUX-} ]] || { printf '%s\n' "${cmd}: error: not inside tmux" >&2; return 1; }

  local keep_focus=0
  local opt=${1-}

  if [[ $opt == "-k" || $opt == "--keep-focus" ]]; then
    keep_focus=1
    shift
  fi

  opt=${1-}

  if [[ $opt == "-h" || $opt == "--help" ]]; then
    __emacs-tmux-tandem._usage "$cmd" 1
    return 0
  fi

  if [[ $opt == "--list" ]]; then
    command tmux list-panes -F $'#{pane_index}\t#{pane_id}\t#{pane_current_command}\t#{pane_tty}'
    return 0
  fi

  local stack
  stack=$(command tmux show-options -w -qv @emacs_openfile_stack 2>/dev/null || true)
  local cmdfile="${stack%%$'\x1f'*}"
  local stem="${cmdfile##*/}"; stem="${stem%.cmd}"
  local paneid="${stem##*-}"

  if [[ $opt == "--cmdfile" ]]; then
    [[ -n $cmdfile ]] || return 1
    printf '%s\n' "$cmdfile"
    return 0
  fi

  local file=${1-}
  if [[ -z $file && $keep_focus -eq 1 ]]; then
    __emacs-tmux-tandem._usage "$cmd" 2
    return 2
  fi

  # Resolve the active session, auto-cleaning any stale entries.
  # A stale entry is one whose pane is no longer running Emacs (e.g. after a
  # crash). Each stale entry is removed from @emacs_openfile_stack and the next
  # leftmost entry is tried, so a surviving standby session is used immediately.
  local pane_cmd stale cur_raw new_stack remaining entry
  while [[ -n $cmdfile ]]; do
    pane_cmd=$(command tmux display-message -t "$paneid" -p '#{pane_current_command}' 2>/dev/null || true)
    [[ $pane_cmd == emacs* ]] && break
    # Stale entry: remove it from the stack and try the next one.
    stale=$cmdfile
    cur_raw=$(command tmux show-options -w -qv @emacs_openfile_stack 2>/dev/null || true)
    new_stack=''
    remaining="$cur_raw"
    while [[ -n $remaining ]]; do
      if [[ $remaining == *$'\x1f'* ]]; then
        entry="${remaining%%$'\x1f'*}"
        remaining="${remaining#*$'\x1f'}"
      else
        entry="$remaining"
        remaining=''
      fi
      [[ $entry == "$stale" ]] && continue
      if [[ -n $new_stack ]]; then
        new_stack+=$'\x1f'"$entry"
      else
        new_stack="$entry"
      fi
    done
    if [[ -n $new_stack ]]; then
      command tmux set-option -w @emacs_openfile_stack "$new_stack"
      cmdfile="${new_stack%%$'\x1f'*}"
      stem="${cmdfile##*/}"; stem="${stem%.cmd}"
      paneid="${stem##*-}"
    else
      command tmux set-option -w -u @emacs_openfile_stack
      cmdfile=''
      paneid=''
    fi
  done

  [[ -n $cmdfile ]] || {
    printf '%s\n' "${cmd}: error: no Emacs session registered in this tmux window" >&2
    printf '%s\n' "${cmd}: hint: load tmux-openfile.el and run M-x tmux-openfile-enable" >&2
    return 1
  }

  # Focus-only: jump to the Emacs pane without opening a file.
  if [[ -z $file ]]; then
    command tmux select-pane -t "$paneid"
    return 0
  fi

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
    [[ -n $paneid ]] && command tmux select-pane -t "$paneid"
  fi
}

# Allow direct execution as a script (not sourced as a plugin).
[[ "${BASH_SOURCE[0]}" != "$0" ]] || __emacs-tmux-tandem.et "${0##*/}" "$@"
