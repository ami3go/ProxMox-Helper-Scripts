#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
ENTRY="$ROOT_DIR/helpers/ai-dev-lxc/install.sh"
MANIFEST="$ROOT_DIR/helpers/ai-dev-lxc/manifest.env"
[[ -x $ENTRY ]]
[[ -f $MANIFEST ]]
bash -n "$ENTRY"
grep -Fq 'readonly SCRIPT_VERSION="2.2.1"' "$ENTRY"
printf 'AI Development LXC smoke test passed.\n'
