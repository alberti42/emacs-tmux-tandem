#!/hint/bash

# Bootstrap loader for the 'et' function.
# On first call, sources the real implementation from src/et.bash,
# which overwrites this stub, then forwards the call.

et() {
  local plugin_dir
  plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "${plugin_dir}/src/et.bash"
  et "$@"
}
