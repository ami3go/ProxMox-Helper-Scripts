#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/homepage.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
state_defaults
ENABLE_HOMEPAGE=true ENABLE_CADDY=true CODE_SERVER_ENABLED=true FILE_MANAGER_ENABLED=true TERMIX_ENABLED=true
HOMEPAGE_DOCKER_DISCOVERY=false
homepage_render_services > "$tmp/services.yaml"
homepage_render_widgets > "$tmp/widgets.yaml"
homepage_render_compose > "$tmp/compose.yaml"
printf '{}\n' > "$tmp/docker.yaml"
printf 'title: AI Development Environment\n' > "$tmp/settings.yaml"
printf '[]\n' > "$tmp/bookmarks.yaml"
python3 - "$tmp" <<'PY'
from pathlib import Path
import sys, yaml
root=Path(sys.argv[1])
for name in ['services.yaml','settings.yaml','widgets.yaml','docker.yaml','compose.yaml','bookmarks.yaml']:
    yaml.safe_load((root/name).read_text())
services=yaml.safe_load((root/'services.yaml').read_text())
names=[]
for group in services:
    for _, items in group.items():
        for item in items:
            names.extend(item.keys())
assert len(names)==len(set(names)), f'duplicate service names: {names}'
compose=yaml.safe_load((root/'compose.yaml').read_text())
ports=compose['services']['homepage']['ports']
assert ports == ['127.0.0.1:3000:3000']
assert '/var/run/docker.sock:/var/run/docker.sock:ro' not in compose['services']['homepage']['volumes']
assert compose['services']['homepage']['image'].endswith(':v1.13.2')
assert 'code.ai-dev.home.arpa' in (root/'services.yaml').read_text()
PY
HOMEPAGE_DOCKER_DISCOVERY=true homepage_render_compose > "$tmp/compose-discovery.yaml"
grep -q '/var/run/docker.sock:/var/run/docker.sock:ro' "$tmp/compose-discovery.yaml"
python3 - "$tmp/compose-discovery.yaml" <<'PYDISCOVERY'
import sys,yaml
x=yaml.safe_load(open(sys.argv[1]))
assert '/var/run/docker.sock:/var/run/docker.sock:ro' in x['services']['homepage']['volumes']
PYDISCOVERY
FILE_MANAGER_ENABLED=false TERMIX_ENABLED=false homepage_render_services > "$tmp/services-reduced.yaml"
! grep -q 'FileBrowser Quantum' "$tmp/services-reduced.yaml"
! grep -q 'Termix:' "$tmp/services-reduced.yaml"
echo 'PASS: Homepage YAML generation'
