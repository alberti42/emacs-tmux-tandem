#!/hint/bash

# Private bootstrap stub — sources the real implementation on first call,
# which redefines __emacs-tmux-tandem.et, then forwards the call.
__emacs-tmux-tandem.et() {
  local plugin_dir
  plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "${plugin_dir}/src/et.bash"
  __emacs-tmux-tandem.et "$@"
}

# Public wrapper under the user-configured name (default: et).
# ET_TANDEM_CMD_NAME is read at source time and baked into the wrapper body,
# so the name is resolved once and never read again at call time.
_eto_cmd="${ET_TANDEM_CMD_NAME:-et}"
eval "
${_eto_cmd}() {
  __emacs-tmux-tandem.et \"${_eto_cmd}\" \"\$@\"
  local rc=\$?
  return \$rc
}
"
unset _eto_cmd
