#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
SITE_DIR=${1:-"$ROOT_DIR/_site"}
cd "$ROOT_DIR"
./scripts/generate-catalog.py
rm -rf "$SITE_DIR"
mkdir -p "$SITE_DIR/downloads"
cp -a docs/. "$SITE_DIR/"
cp README.md LICENSE CHANGELOG.md HELPERS.md ARCHITECTURE.md "$SITE_DIR/"
cp -a helpers "$SITE_DIR/helpers"
./scripts/export-helpers.sh "$SITE_DIR/downloads"
(
  cd "$SITE_DIR/downloads"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\0' | sort -z | xargs -0 sha256sum > SHA256SUMS
)
printf 'Site built at %s\n' "$SITE_DIR"
