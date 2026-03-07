#!/usr/bin/env zsh
set -euo pipefail

usage() {
  print -u2 "usage: ${0:t} FILE"
  print -u2 "       ${0:t} --cmdfile"
  print -u2 "       ${0:t} --list"
}

[[ -n ${TMUX-} ]] || { print -u2 "error: not inside tmux"; exit 1; }

opt=${1-}

if [[ $opt == "--list" ]]; then
  tmux list-panes -F $'#{pane_index}\t#{pane_id}\t#{pane_current_command}\t#{pane_tty}'
  exit 0
fi

cmdfile=$(tmux show-options -w -qv @emacs_openfile_cmdfile || true)

if [[ $opt == "--cmdfile" ]]; then
  [[ -n $cmdfile ]] || exit 1
  print -r -- "$cmdfile"
  exit 0
fi

file=${1-}
[[ -n $file ]] || { usage; exit 2; }

[[ -n $cmdfile ]] || {
  print -u2 "error: no @emacs_openfile_cmdfile set for this tmux window"
  print -u2 "hint: load tmux.el and run M-x tmux-openfile-enable, then create a tty emacsclient frame"
  exit 1
}

[[ -f $cmdfile && ! -L $cmdfile && -O $cmdfile ]] || {
  print -u2 "error: unsafe cmdfile: $cmdfile"
  exit 1
}

# In-place update (no temp+rename) so Emacs file-notify watches keep working.
print -r -- "$file" >| "$cmdfile"
