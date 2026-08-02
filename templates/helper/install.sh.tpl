#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# __HELPER_NAME__
set -Eeuo pipefail

readonly SCRIPT_VERSION="0.1.0"
HELPER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$HELPER_DIR/../.." && pwd)
# shellcheck source=../../lib/common.sh
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=../../lib/tui.sh
source "$ROOT_DIR/lib/tui.sh"

main() {
  ph_require_root
  ph_tui_message "__HELPER_NAME__" \
    "This is a generated helper skeleton. Implement provisioning in helpers/__HELPER_ID__/install.sh."
}

main "$@"
