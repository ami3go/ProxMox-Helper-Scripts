#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Compatibility entrypoint retained for users of releases before v2.1.0.
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ENTRY="$ROOT_DIR/helpers/ai-dev-lxc/install.sh"
if [[ ! -f $ENTRY ]]; then
  printf 'ERROR: This compatibility launcher requires the complete repository.\n' >&2
  printf 'Use the standalone ai-dev-lxc.sh asset from a tagged release instead.\n' >&2
  exit 1
fi
exec "$ENTRY" "$@"
