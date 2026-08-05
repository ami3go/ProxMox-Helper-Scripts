#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=2.2.7
OUT_DIR=${OUT_DIR:-$(dirname "$ROOT")}
"$ROOT/scripts/build-standalone.sh"
"$ROOT/scripts/validate.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
helper_stage="$tmp/ai-dev-lxc-bundle-v$VERSION"
repo_stage="$tmp/proxmox-helper-scripts-v$VERSION"
mkdir -p "$helper_stage/helpers" "$repo_stage"
cp -a "$ROOT/helpers/ai-dev-lxc" "$helper_stage/helpers/"
cp -a "$ROOT/ai-dev-lxc.sh" "$ROOT/ai-dev-lxc-v$VERSION.sh" "$ROOT/proxmox-ai-dev-lxc.sh" "$helper_stage/"
cp -a "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/ARCHITECTURE.md" "$ROOT/HELPERS.md" "$ROOT/LICENSE" "$helper_stage/"
cp -a "$ROOT/docs" "$helper_stage/"

# Full repository stage; never include generated release archives, credentials, or VCS metadata.
tar -C "$ROOT" \
  --exclude='.git' --exclude='*.zip' --exclude='*.tar.gz' --exclude='*SHA256SUMS*' \
  --exclude='auth.json' --exclude='*.pem' --exclude='*.key' \
  -cf - . | tar -C "$repo_stage" -xf -

rm -f \
  "$OUT_DIR/ai-dev-lxc-bundle-v$VERSION.tar.gz" \
  "$OUT_DIR/ai-dev-lxc-bundle-v$VERSION.zip" \
  "$OUT_DIR/proxmox-helper-scripts-v$VERSION.tar.gz" \
  "$OUT_DIR/proxmox-helper-scripts-v$VERSION.zip" \
  "$OUT_DIR/proxmox-helper-scripts-v$VERSION-SHA256SUMS"

tar -C "$tmp" -czf "$OUT_DIR/ai-dev-lxc-bundle-v$VERSION.tar.gz" "$(basename "$helper_stage")"
tar -C "$tmp" -czf "$OUT_DIR/proxmox-helper-scripts-v$VERSION.tar.gz" "$(basename "$repo_stage")"

python3 - "$helper_stage" "$repo_stage" "$OUT_DIR" "$VERSION" <<'PY'
from pathlib import Path
import sys, zipfile
helper, repo, out, version = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4]
def make_zip(src: Path, dest: Path):
    with zipfile.ZipFile(dest,'w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as z:
        base=src.parent
        for p in sorted(src.rglob('*')):
            if p.is_file():
                z.write(p,p.relative_to(base))
make_zip(helper,out/f'ai-dev-lxc-bundle-v{version}.zip')
make_zip(repo,out/f'proxmox-helper-scripts-v{version}.zip')
PY

cp -a "$ROOT/ai-dev-lxc-v$VERSION.sh" "$ROOT/ai-dev-lxc.sh" "$ROOT/proxmox-ai-dev-lxc.sh" "$OUT_DIR/"
sha256sum \
  "$OUT_DIR/ai-dev-lxc-bundle-v$VERSION.tar.gz" \
  "$OUT_DIR/ai-dev-lxc-bundle-v$VERSION.zip" \
  "$OUT_DIR/proxmox-helper-scripts-v$VERSION.tar.gz" \
  "$OUT_DIR/proxmox-helper-scripts-v$VERSION.zip" \
  "$OUT_DIR/ai-dev-lxc-v$VERSION.sh" "$OUT_DIR/ai-dev-lxc.sh" "$OUT_DIR/proxmox-ai-dev-lxc.sh" \
  | sed "s|$OUT_DIR/||" > "$OUT_DIR/proxmox-helper-scripts-v$VERSION-SHA256SUMS"

"$ROOT/helpers/ai-dev-lxc/tests/release-packaging-test.sh" "$OUT_DIR"
echo "Release artifacts written to $OUT_DIR"
