#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

./scripts/generate-catalog.py
./scripts/validate.sh

VERSION=$(tr -d '[:space:]' < VERSION)
NAME="proxmox-helper-scripts-v${VERSION}"
DIST="$ROOT_DIR/dist"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

rm -rf "$DIST"
mkdir -p "$DIST" "$STAGE/$NAME"

tar \
  --exclude='./.git' \
  --exclude='./dist' \
  --exclude='./_site' \
  --exclude='./__pycache__' \
  --exclude='*.pyc' \
  -cf - . | tar -C "$STAGE/$NAME" -xf -

(
  cd "$STAGE"
  tar -czf "$DIST/$NAME.tar.gz" "$NAME"
  zip -qr "$DIST/$NAME.zip" "$NAME"
)

./scripts/export-helpers.sh "$DIST"
cp docs/data/helpers.json "$DIST/helper-catalog.json"
(
  cd "$DIST"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\0' | sort -z | xargs -0 sha256sum > SHA256SUMS
)

printf 'Release files created in %s\n' "$DIST"
find "$DIST" -maxdepth 1 -type f -printf '%f\n' | sort
