#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$ROOT/helpers/ai-dev-lxc"
OMNIROUTE_TUI="$ROOT/helpers/ai-dev-omniroute-tui"
TELEMETRY="$ROOT/helpers/internet-telemetry"

"$HELPER/tests/smoke.sh"

# Discover every shell script in the repository instead of maintaining a
# fragile hand-written list. This includes extensionless entrypoints such as
# bin/proxmox-helper-scripts and helpers/ai-dev-omniroute-tui/ai-dev-tui.
shell_files=()
while IFS= read -r -d '' file; do
  if [[ "$file" == *.sh ]] || head -n 1 "$file" 2>/dev/null | grep -Eq '^#!.*(bash|sh)([[:space:]]|$)'; then
    shell_files+=("$file")
  fi
done < <(find "$ROOT" -type f \
  -not -path "$ROOT/.git/*" \
  -not -path "$ROOT/dist/*" \
  -print0)

((${#shell_files[@]} > 0)) || { echo 'No shell scripts discovered.' >&2; exit 1; }

for file in "${shell_files[@]}"; do
  bash -n "$file"
done

# Run warning-level static analysis, excluding categories that are known to be
# noisy for this repository's cross-file state model or test fixtures. Keep
# scope/order, quoting, condition, redirection, and control-flow warnings fatal.
shellcheck --severity=warning -x \
  --exclude=SC2034,SC2120,SC2155,SC2163 \
  "${shell_files[@]}"

# RETURN traps persist beyond the function that creates them. Referencing a
# local variable from one is unsafe under `set -u` and caused the Node.js TUI
# crash fixed in v0.1.3. Disallow this construct repository-wide.
if grep -nHE '^[[:space:]]*trap .* RETURN([[:space:]]|$)' "${shell_files[@]}"; then
  echo 'Persistent RETURN trap found in shell script.' >&2
  exit 1
fi

grep -q 'HELPER_VERSION="2.2.7"' "$HELPER/manifest.env"
grep -q 'AI_DEV_VERSION="${AI_DEV_VERSION:-2.2.7}"' "$HELPER/lib/common.sh"
grep -q '^## v2.2.7' "$ROOT/CHANGELOG.md"
grep -q 'ghcr.io/gethomepage/homepage:v1.13.2' "$HELPER/lib/state.sh"
grep -q '127.0.0.1:${HOMEPAGE_PORT}:3000' "$HELPER/lib/homepage.sh"
grep -q 'forced_login_method' "$HELPER/lib/codex.sh"
grep -q 'caddy validate --config /etc/caddy/Caddyfile' "$HELPER/lib/caddy.sh"
grep -q 'bindings_restore' "$HELPER/lib/bindings.sh"
grep -q 'APP_VERSION="0.1.3"' "$OMNIROUTE_TUI/ai-dev-tui"
grep -q -- '--strict-allow-scripts' "$OMNIROUTE_TUI/ai-dev-tui"
grep -q -- '--allow-scripts=' "$OMNIROUTE_TUI/ai-dev-tui"
grep -q 'allow_scripts=.*fsevents' "$OMNIROUTE_TUI/ai-dev-tui"

python3 "$ROOT/scripts/validate-manifests.py"

# Syntax-check every Python source without leaving __pycache__ artifacts in the
# checkout. This covers repository tooling and the Internet Telemetry helper.
python3 - "$ROOT" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
for path in sorted(root.rglob('*.py')):
    if '.git' in path.parts or 'dist' in path.parts:
        continue
    compile(path.read_text(encoding='utf-8'), str(path), 'exec')
    print(f'PY  {path.relative_to(root)}')
PY

# Run the telemetry helper's standard-library-only logic regression suite.
python3 "$TELEMETRY/test_logic.py"

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
