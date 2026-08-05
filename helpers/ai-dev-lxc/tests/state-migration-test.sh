#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
for version in 2.2.3 2.2.4 2.2.5 2.2.6; do
  cat > "$tmp/$version.env" <<STATE
SCRIPT_VERSION=$version
DEV_USER=dev
CODE_SERVER_PORT=8080
FILE_MANAGER_PORT=8081
TERMIX_PORT=8082
STATE
  AI_DEV_STATE_FILE="$tmp/$version.env"
  unset ENABLE_CADDY ENABLE_HOMEPAGE GATEWAY_DOMAIN DASHBOARD_HOSTNAME CODE_HOSTNAME FILES_HOSTNAME TERMIX_HOSTNAME GATEWAY_HTTPS_MODE RESTRICT_BACKEND_PORTS HOMEPAGE_PORT HOMEPAGE_IMAGE HOMEPAGE_DOCKER_DISCOVERY HOMEPAGE_SYSTEM_WIDGETS PROXMOX_WEB_URL ENABLE_CODEX_CLI CODEX_LINUX_USER CODEX_AUTH_MODE CODEX_CREDENTIAL_STORE CODEX_HOME CODEX_INSTALL_METHOD CODEX_INSTALLED_VERSION CODEX_INSTALLED_PATH CODEX_INSTALL_TIMESTAMP CODEX_WORKSPACE_ROOT CODE_SERVER_ENABLED FILE_MANAGER_ENABLED TERMIX_ENABLED GATEWAY_MANAGED_VERSION
  load_state
  [[ "$GATEWAY_DOMAIN" == home.arpa ]]
  [[ "$HOMEPAGE_IMAGE" == ghcr.io/gethomepage/homepage:v1.13.2 ]]
  [[ "$CODEX_AUTH_MODE" == chatgpt ]]
  [[ "$ENABLE_CADDY" == false ]]
  [[ "$ENABLE_HOMEPAGE" == false ]]
  [[ "$ENABLE_CODEX_CLI" == false ]]
  [[ "$RESTRICT_BACKEND_PORTS" == false ]]
  validate_state
done
AI_DEV_STATE_FILE="$tmp/roundtrip.env"
CODEX_INSTALLED_VERSION='codex-cli 1.2.3'
PROXMOX_WEB_URL='https://proxmox.local:8006/'
persist_state
unset CODEX_INSTALLED_VERSION PROXMOX_WEB_URL
load_state
[[ "$CODEX_INSTALLED_VERSION" == 'codex-cli 1.2.3' ]]
[[ "$PROXMOX_WEB_URL" == 'https://proxmox.local:8006/' ]]
[[ "$(fqdn_code)" == 'code.ai-dev.home.arpa' ]]
echo 'PASS: state migration v2.2.3-v2.2.6 and state round-trip' 
