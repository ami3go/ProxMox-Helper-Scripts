#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/helpers/ai-dev-lxc"

"$HELPER/tests/smoke.sh"

for file in "$ROOT"/*.sh "$ROOT"/scripts/*.sh "$HELPER"/install.sh "$HELPER"/extend-existing-lxc.sh "$HELPER"/lib/*.sh "$HELPER"/tests/*.sh; do
  bash -n "$file"
done

grep -q 'HELPER_VERSION="2.2.7"' "$HELPER/manifest.env"
grep -q 'AI_DEV_VERSION="${AI_DEV_VERSION:-2.2.7}"' "$HELPER/lib/common.sh"
grep -q '^## v2.2.7' "$ROOT/CHANGELOG.md"
grep -q 'ghcr.io/gethomepage/homepage:v1.13.2' "$HELPER/lib/state.sh"
grep -q '127.0.0.1:${HOMEPAGE_PORT}:3000' "$HELPER/lib/homepage.sh"
grep -q 'forced_login_method' "$HELPER/lib/codex.sh"
grep -q 'caddy validate --config /etc/caddy/Caddyfile' "$HELPER/lib/caddy.sh"
grep -q 'bindings_restore' "$HELPER/lib/bindings.sh"

python3 - "$ROOT/helper-catalog.json" <<'PY'
import json,sys
x=json.load(open(sys.argv[1]))
assert x['release']=='2.2.7'
assert x['helpers'][0]['version']=='2.2.7'
PY

if find "$ROOT" -type f \( -name auth.json -o -name '*.pem' -o -name '*.key' \) | grep -q .; then
  echo 'Forbidden secret-bearing file found in repository.' >&2
  exit 1
fi
if grep -R --exclude-dir=.git --exclude='*.md' --exclude='codex-cli-test.sh' --exclude='validate.sh' -E 'sk-[A-Za-z0-9_-]{16,}|OPENAI_API_KEY=[^$"[:space:]]' "$ROOT"; then
  echo 'Possible embedded API credential found.' >&2
  exit 1
fi

python3 - "$HELPER/assets/homepage-preview.png" <<'PY'
from PIL import Image
import sys
with Image.open(sys.argv[1]) as im:
    assert im.size == (1200,675)
    im.verify()
PY

echo 'PASS: repository validation'
