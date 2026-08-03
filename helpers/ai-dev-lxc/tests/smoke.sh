#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
ENTRY="$ROOT_DIR/helpers/ai-dev-lxc/install.sh"
POST_INSTALL="$ROOT_DIR/helpers/ai-dev-lxc/post-install.sh"
MANIFEST="$ROOT_DIR/helpers/ai-dev-lxc/manifest.env"
[[ -x $ENTRY ]]
[[ -f $MANIFEST ]]
[[ -x $POST_INSTALL ]]
bash -n "$ENTRY"
bash -n "$POST_INSTALL"
grep -Fq 'readonly SCRIPT_VERSION="2.3.0"' "$ENTRY"
grep -Fq 'readonly SCRIPT_VERSION="2.3.0"' "$POST_INSTALL"
grep -Fq 'pct set "$CTID" --cmode shell' "$POST_INSTALL"
grep -Fq 'bind-addr: 0.0.0.0:$CODE_SERVER_PORT' "$POST_INSTALL"
printf 'AI Development LXC smoke test passed.\n'
