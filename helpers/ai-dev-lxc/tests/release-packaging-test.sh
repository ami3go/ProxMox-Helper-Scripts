#!/usr/bin/env bash
set -Eeuo pipefail
OUT_DIR=${1:?output directory required}
VERSION=2.2.7
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
required=(
  helpers/ai-dev-lxc/install.sh
  helpers/ai-dev-lxc/lib/caddy.sh
  helpers/ai-dev-lxc/lib/homepage.sh
  helpers/ai-dev-lxc/lib/codex.sh
  helpers/ai-dev-lxc/lib/bindings.sh
  helpers/ai-dev-lxc/templates/Caddyfile.tpl
  helpers/ai-dev-lxc/templates/homepage-compose.yaml.tpl
  helpers/ai-dev-lxc/templates/codex-config.toml.tpl
  helpers/ai-dev-lxc/tests/smoke.sh
)
for archive in \
  "$OUT_DIR/ai-dev-lxc-bundle-v$VERSION.tar.gz" \
  "$OUT_DIR/proxmox-helper-scripts-v$VERSION.tar.gz"; do
  dir="$tmp/$(basename "$archive" .tar.gz)"
  mkdir -p "$dir"
  tar -xzf "$archive" -C "$dir"
  root=$(find "$dir" -mindepth 1 -maxdepth 1 -type d | head -n1)
  for path in "${required[@]}"; do [[ -e "$root/$path" ]] || { echo "Missing $path in $archive" >&2; exit 1; }; done
  ! find "$root" -type f \( -name auth.json -o -name '*.pem' -o -name '*.key' \) | grep -q .
done
python3 - "$OUT_DIR/ai-dev-lxc-bundle-v$VERSION.zip" "$OUT_DIR/proxmox-helper-scripts-v$VERSION.zip" <<'PY'
import sys, zipfile
required=['helpers/ai-dev-lxc/lib/caddy.sh','helpers/ai-dev-lxc/lib/homepage.sh','helpers/ai-dev-lxc/lib/codex.sh']
for filename in sys.argv[1:]:
    with zipfile.ZipFile(filename) as z:
        names=z.namelist()
        for suffix in required:
            assert any(n.endswith(suffix) for n in names), (filename,suffix)
        assert not any(n.endswith('/auth.json') or n.endswith('.pem') or n.endswith('.key') for n in names)
PY
for standalone in "$OUT_DIR/ai-dev-lxc-v$VERSION.sh" "$OUT_DIR/ai-dev-lxc.sh" "$OUT_DIR/proxmox-ai-dev-lxc.sh"; do
  [[ -x "$standalone" ]] || { echo "Missing executable standalone: $standalone" >&2; exit 1; }
  [[ $(stat -c '%s' "$standalone") -gt 50000 ]] || { echo "Standalone is unexpectedly small: $standalone" >&2; exit 1; }
  [[ $("$standalone" --version) == "$VERSION" ]] || { echo "Standalone version check failed: $standalone" >&2; exit 1; }
done

(cd "$OUT_DIR" && sha256sum -c "proxmox-helper-scripts-v$VERSION-SHA256SUMS" >/dev/null)
echo 'PASS: release packaging and extracted archive validation'
