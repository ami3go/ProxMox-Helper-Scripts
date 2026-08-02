#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
HELPER_DIR="$ROOT_DIR/helpers/__HELPER_ID__"
ENTRY="$HELPER_DIR/install.sh"
MANIFEST="$HELPER_DIR/manifest.env"
[[ -x $ENTRY ]]
[[ -f $MANIFEST ]]
for directory in assets files lib templates tests; do
  [[ -d $HELPER_DIR/$directory ]]
done
bash -n "$ENTRY"
printf '__HELPER_ID__ smoke test passed.\n'
