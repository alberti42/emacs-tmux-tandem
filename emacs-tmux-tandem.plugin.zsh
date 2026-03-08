#!/hint/zsh

# Private bootstrap stub — sources the real implementation on first call,
# which redefines __emacs-tmux-tandem.et, then forwards the call.
function __emacs-tmux-tandem.et() {
  emulate -LR zsh
  local plugin_dir="${${(%):-%x}:a:h}"
  source "${plugin_dir}/src/et.zsh"
  __emacs-tmux-tandem.et "$@"
}

# Public wrapper under the user-configured name (default: et).
# ET_TANDEM_CMD_NAME is read at source time and baked into the wrapper body,
# so the name is resolved once and never read again at call time.
(){
  local _cmd="${ET_TANDEM_CMD_NAME:-et}"
  functions[$_cmd]="__emacs-tmux-tandem.et ${_cmd} \"\$@\""
}
