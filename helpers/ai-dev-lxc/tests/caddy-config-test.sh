#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/caddy.sh"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
render_case() {
  local name=$1
  shift
  (
    state_defaults
    ENABLE_HOMEPAGE=false CODE_SERVER_ENABLED=false FILE_MANAGER_ENABLED=false TERMIX_ENABLED=false
    for item in "$@"; do export "$item"; done
    normalize_state; validate_state
    caddy_render_config > "$tmp/$name.Caddyfile"
  )
}
render_case homepage-http GATEWAY_HTTPS_MODE=http ENABLE_HOMEPAGE=true
render_case all-http GATEWAY_HTTPS_MODE=http ENABLE_HOMEPAGE=true CODE_SERVER_ENABLED=true FILE_MANAGER_ENABLED=true TERMIX_ENABLED=true
render_case all-https GATEWAY_HTTPS_MODE=internal ENABLE_HOMEPAGE=true CODE_SERVER_ENABLED=true FILE_MANAGER_ENABLED=true TERMIX_ENABLED=true
render_case custom GATEWAY_HTTPS_MODE=http ENABLE_HOMEPAGE=true GATEWAY_DOMAIN=lab.home.arpa DASHBOARD_HOSTNAME=portal

grep -q 'auto_https off' "$tmp/homepage-http.Caddyfile"
grep -q 'http://ai-dev.home.arpa' "$tmp/homepage-http.Caddyfile"
! grep -q 'code.ai-dev.home.arpa' "$tmp/homepage-http.Caddyfile"
[[ $(grep -c 'reverse_proxy' "$tmp/all-http.Caddyfile") -eq 4 ]]
grep -q 'http://code.ai-dev.home.arpa' "$tmp/all-http.Caddyfile"
grep -q 'dl.cloudsmith.io/public/caddy/stable' "$ROOT/lib/caddy.sh"
grep -q 'tls internal' "$tmp/all-https.Caddyfile"
! grep -q 'auto_https off' "$tmp/all-https.Caddyfile"
grep -q 'http://portal.lab.home.arpa' "$tmp/custom.Caddyfile"
if command -v caddy >/dev/null 2>&1; then
  for file in "$tmp"/*.Caddyfile; do caddy validate --adapter caddyfile --config "$file" >/dev/null; done
else
  echo 'SKIP: caddy binary not installed; structural Caddyfile checks passed.'
fi
echo 'PASS: Caddy configuration generation'
