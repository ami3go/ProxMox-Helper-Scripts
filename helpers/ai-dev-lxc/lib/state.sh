#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

state_defaults() {
  : "${ENABLE_CADDY:=true}"
  : "${ENABLE_HOMEPAGE:=true}"
  : "${GATEWAY_DOMAIN:=home.arpa}"
  : "${DASHBOARD_HOSTNAME:=ai-dev}"
  : "${CODE_HOSTNAME:=code}"
  : "${FILES_HOSTNAME:=files}"
  : "${TERMIX_HOSTNAME:=termix}"
  : "${GATEWAY_HTTPS_MODE:=http}"
  : "${RESTRICT_BACKEND_PORTS:=true}"
  : "${HOMEPAGE_PORT:=3000}"
  : "${HOMEPAGE_IMAGE:=ghcr.io/gethomepage/homepage:v1.13.2}"
  : "${HOMEPAGE_DOCKER_DISCOVERY:=false}"
  : "${HOMEPAGE_SYSTEM_WIDGETS:=true}"
  : "${PROXMOX_WEB_URL:=}"
  : "${ENABLE_CODEX_CLI:=true}"
  : "${CODEX_LINUX_USER:=${DEV_USER:-dev}}"
  : "${CODEX_AUTH_MODE:=chatgpt}"
  : "${CODEX_CREDENTIAL_STORE:=auto}"
  : "${CODEX_HOME:=/home/${CODEX_LINUX_USER}/.codex}"
  : "${CODEX_INSTALL_METHOD:=official-standalone}"
  : "${CODEX_INSTALLED_VERSION:=}"
  : "${CODEX_INSTALLED_PATH:=}"
  : "${CODEX_INSTALL_TIMESTAMP:=}"
  : "${CODEX_WORKSPACE_ROOT:=/srv/workspace}"
  : "${DEV_USER:=${CODEX_LINUX_USER:-dev}}"
  : "${CODE_SERVER_ENABLED:=true}"
  : "${CODE_SERVER_PORT:=8080}"
  : "${FILE_MANAGER_ENABLED:=true}"
  : "${FILE_MANAGER_PORT:=8081}"
  : "${TERMIX_ENABLED:=true}"
  : "${TERMIX_PORT:=8082}"
  : "${GATEWAY_MANAGED_VERSION:=2.2.7}"
}

state_migration_defaults() {
  # Older managed containers predate these optional components. Preserve their
  # current exposure until the user explicitly enables the gateway features.
  ENABLE_CADDY=false
  ENABLE_HOMEPAGE=false
  RESTRICT_BACKEND_PORTS=false
  HOMEPAGE_DOCKER_DISCOVERY=false
  ENABLE_CODEX_CLI=false
  state_defaults
}

load_state() {
  if [[ -r "$AI_DEV_STATE_FILE" ]]; then
    state_migration_defaults
    safe_source_env "$AI_DEV_STATE_FILE"
  else
    state_defaults
  fi
  state_defaults
  normalize_state
}

normalize_state() {
  ENABLE_CADDY=$(bool_value "$ENABLE_CADDY")
  ENABLE_HOMEPAGE=$(bool_value "$ENABLE_HOMEPAGE")
  RESTRICT_BACKEND_PORTS=$(bool_value "$RESTRICT_BACKEND_PORTS")
  HOMEPAGE_DOCKER_DISCOVERY=$(bool_value "$HOMEPAGE_DOCKER_DISCOVERY")
  HOMEPAGE_SYSTEM_WIDGETS=$(bool_value "$HOMEPAGE_SYSTEM_WIDGETS")
  ENABLE_CODEX_CLI=$(bool_value "$ENABLE_CODEX_CLI")
  CODE_SERVER_ENABLED=$(bool_value "$CODE_SERVER_ENABLED")
  FILE_MANAGER_ENABLED=$(bool_value "$FILE_MANAGER_ENABLED")
  TERMIX_ENABLED=$(bool_value "$TERMIX_ENABLED")
}

validate_state() {
  validate_domain "$GATEWAY_DOMAIN" || die "Invalid local domain suffix: $GATEWAY_DOMAIN"
  local label
  for label in "$DASHBOARD_HOSTNAME" "$CODE_HOSTNAME" "$FILES_HOSTNAME" "$TERMIX_HOSTNAME"; do
    validate_hostname_label "$label" || die "Invalid hostname label: $label"
  done
  case "$GATEWAY_HTTPS_MODE" in http|internal) ;; *) die "GATEWAY_HTTPS_MODE must be http or internal" ;; esac
  for label in "$HOMEPAGE_PORT" "$CODE_SERVER_PORT" "$FILE_MANAGER_PORT" "$TERMIX_PORT"; do
    validate_port "$label" || die "Invalid TCP port: $label"
  done
  [[ "$HOMEPAGE_PORT" != "$CODE_SERVER_PORT" && "$HOMEPAGE_PORT" != "$FILE_MANAGER_PORT" && "$HOMEPAGE_PORT" != "$TERMIX_PORT" ]] || die "Homepage port conflicts with an existing backend"
  if is_true "$CODE_SERVER_ENABLED" && is_true "$FILE_MANAGER_ENABLED"; then
    [[ "$CODE_SERVER_PORT" != "$FILE_MANAGER_PORT" ]] || die "code-server and FileBrowser cannot share a port"
  fi
  if is_true "$CODE_SERVER_ENABLED" && is_true "$TERMIX_ENABLED"; then
    [[ "$CODE_SERVER_PORT" != "$TERMIX_PORT" ]] || die "code-server and Termix cannot share a port"
  fi
  if is_true "$FILE_MANAGER_ENABLED" && is_true "$TERMIX_ENABLED"; then
    [[ "$FILE_MANAGER_PORT" != "$TERMIX_PORT" ]] || die "FileBrowser and Termix cannot share a port"
  fi
  if is_true "$RESTRICT_BACKEND_PORTS" && ! is_true "$ENABLE_CADDY"; then
    die "Backend restriction requires Caddy"
  fi
  if is_true "$ENABLE_CADDY" && ! is_true "$ENABLE_HOMEPAGE" && ! is_true "$CODE_SERVER_ENABLED" && ! is_true "$FILE_MANAGER_ENABLED" && ! is_true "$TERMIX_ENABLED"; then
    die "Caddy is enabled but no gateway route is enabled"
  fi
  case "$CODEX_AUTH_MODE" in chatgpt|api) ;; *) die "CODEX_AUTH_MODE must be chatgpt or api" ;; esac
  case "$CODEX_CREDENTIAL_STORE" in auto|keyring|file) ;; *) die "CODEX_CREDENTIAL_STORE must be auto, keyring, or file" ;; esac
  [[ "$CODEX_LINUX_USER" != root ]] || die "Codex must not be configured for routine use as root"
  [[ "$HOMEPAGE_IMAGE" =~ ^ghcr\.io/gethomepage/homepage:v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Homepage must use a pinned ghcr.io image tag"
  if [[ -n "$PROXMOX_WEB_URL" ]]; then
    [[ "$PROXMOX_WEB_URL" =~ ^https?:// ]] || die "Proxmox URL must start with http:// or https://"
    [[ ! "$PROXMOX_WEB_URL" =~ ^https?://[^/]*@ ]] || die "Do not embed credentials in the Proxmox URL"
  fi
}

persist_state() {
  normalize_state
  write_env_file "$AI_DEV_STATE_FILE" 0644 \
    GATEWAY_MANAGED_VERSION ENABLE_CADDY ENABLE_HOMEPAGE GATEWAY_DOMAIN \
    DASHBOARD_HOSTNAME CODE_HOSTNAME FILES_HOSTNAME TERMIX_HOSTNAME \
    GATEWAY_HTTPS_MODE RESTRICT_BACKEND_PORTS HOMEPAGE_PORT HOMEPAGE_IMAGE \
    HOMEPAGE_DOCKER_DISCOVERY HOMEPAGE_SYSTEM_WIDGETS PROXMOX_WEB_URL \
    ENABLE_CODEX_CLI CODEX_LINUX_USER CODEX_AUTH_MODE CODEX_CREDENTIAL_STORE \
    CODEX_HOME CODEX_INSTALL_METHOD CODEX_INSTALLED_VERSION CODEX_INSTALLED_PATH \
    CODEX_INSTALL_TIMESTAMP CODEX_WORKSPACE_ROOT DEV_USER CODE_SERVER_ENABLED \
    CODE_SERVER_PORT FILE_MANAGER_ENABLED FILE_MANAGER_PORT TERMIX_ENABLED TERMIX_PORT
}

fqdn_dashboard() { printf '%s.%s' "$DASHBOARD_HOSTNAME" "$GATEWAY_DOMAIN"; }
fqdn_code() { printf '%s.%s.%s' "$CODE_HOSTNAME" "$DASHBOARD_HOSTNAME" "$GATEWAY_DOMAIN"; }
fqdn_files() { printf '%s.%s.%s' "$FILES_HOSTNAME" "$DASHBOARD_HOSTNAME" "$GATEWAY_DOMAIN"; }
fqdn_termix() { printf '%s.%s.%s' "$TERMIX_HOSTNAME" "$DASHBOARD_HOSTNAME" "$GATEWAY_DOMAIN"; }
gateway_scheme() { [[ "$GATEWAY_HTTPS_MODE" == internal ]] && printf https || printf http; }
