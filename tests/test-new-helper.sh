#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

HELPER_OUTPUT_ROOT="$TMP/helpers" "$ROOT_DIR/scripts/new-helper.sh" \
  --id sample-helper \
  --name 'Sample Helper' \
  --category testing \
  --description 'Generated helper used by the repository test suite.'

DEST="$TMP/helpers/sample-helper"
[[ -f $DEST/manifest.env ]]
[[ -x $DEST/install.sh ]]
[[ -x $DEST/tests/smoke.sh ]]
for directory in assets files lib templates tests; do
  [[ -d $DEST/$directory ]]
  [[ -f $DEST/$directory/README.md || $directory == tests ]]
done
grep -Fq 'HELPER_ID="sample-helper"' "$DEST/manifest.env"
grep -Fq 'HELPER_CATEGORY="testing"' "$DEST/manifest.env"
grep -Fq 'HELPER_STANDALONE="false"' "$DEST/manifest.env"
grep -Fq 'Sample Helper' "$DEST/README.md"
bash -n "$DEST/install.sh"
printf 'Helper package scaffold test passed.\n'
