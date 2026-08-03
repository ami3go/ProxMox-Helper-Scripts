#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Repository-level compatibility launcher for the AI Development LXC post-install utility.
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENTRY="$ROOT_DIR/helpers/ai-dev-lxc/post-install.sh"
if [[ ! -f $ENTRY ]]; then
  printf 'ERROR: This launcher requires the complete repository.\n' >&2
  printf 'Use the standalone ai-dev-lxc-post-install.sh asset from a tagged release instead.\n' >&2
  exit 1
fi
exec "$ENTRY" "$@"
