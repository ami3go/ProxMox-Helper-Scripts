#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIB_DIR="$SCRIPT_DIR/lib"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/state.sh"
source "$LIB_DIR/codex.sh"
source "$LIB_DIR/homepage.sh"
source "$LIB_DIR/caddy.sh"
source "$LIB_DIR/bindings.sh"

NON_INTERACTIVE=false
GUEST_MODE=false
CTID=''
STATE_INPUT=''

usage() {
  cat <<'USAGE'
AI Development LXC Gateway/Codex installer v2.2.7

Usage:
  install.sh                         Interactive; auto-detect Proxmox host or LXC
  install.sh --ctid 123              Configure an existing LXC from Proxmox host
  install.sh --guest                 Provision from inside the LXC
  install.sh --guest --state FILE    Provision from a supplied state file
  install.sh --non-interactive       Use state/environment defaults without prompts
  install.sh --validate-only         Validate the loaded state and exit
  install.sh --version               Print the helper version and exit

This release extends an existing AI Development LXC. It preserves projects and
existing code-server, FileBrowser Quantum, and Termix credentials and data.
USAGE
}

VALIDATE_ONLY=false
while (($#)); do
  case "$1" in
    --ctid) CTID=${2:?missing CTID}; shift 2 ;;
    --guest|--inside-lxc) GUEST_MODE=true; shift ;;
    --state) STATE_INPUT=${2:?missing state file}; shift 2 ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --validate-only) VALIDATE_ONLY=true; shift ;;
    --version) printf '%s\n' "$AI_DEV_VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1" ;;
  esac
done

ensure_whiptail() {
  command_exists whiptail && return 0
  if command_exists apt-get; then apt-get update && apt-get install -y whiptail; fi
  command_exists whiptail || die "whiptail is required for interactive mode"
}

ask_yes_no() {
  local title=$1 text=$2 default=${3:-yes}
  if is_true "$NON_INTERACTIVE"; then [[ "$default" == yes ]]; return; fi
  local option=--yesno
  [[ "$default" == no ]] && option=--defaultno
  whiptail --backtitle "AI Development LXC v$AI_DEV_VERSION" --title "$title" "$option" "$text" 18 82
}

input_box() {
  local title=$1 text=$2 default=${3:-}
  if is_true "$NON_INTERACTIVE"; then printf '%s' "$default"; return; fi
  whiptail --backtitle "AI Development LXC v$AI_DEV_VERSION" --title "$title" --inputbox "$text" 12 82 "$default" 3>&1 1>&2 2>&3
}

menu_box() {
  local title=$1 text=$2
  shift 2
  if is_true "$NON_INTERACTIVE"; then printf '%s' "$1"; return; fi
  whiptail --backtitle "AI Development LXC v$AI_DEV_VERSION" --title "$title" --menu "$text" 18 86 8 "$@" 3>&1 1>&2 2>&3
}

detect_guest_services() {
  local home config bind
  if ! id "${DEV_USER:-dev}" >/dev/null 2>&1; then
    config=$(find /home -path '*/.config/code-server/config.yaml' -type f -print -quit 2>/dev/null || true)
    [[ -n "$config" ]] && DEV_USER=$(cut -d/ -f3 <<<"$config")
  fi
  : "${DEV_USER:=dev}"
  home=$(getent passwd "$DEV_USER" 2>/dev/null | cut -d: -f6)
  config="$home/.config/code-server/config.yaml"
  if [[ -f "$config" ]]; then
    CODE_SERVER_ENABLED=true
    bind=$(sed -n 's/^bind-addr:[[:space:]]*//p' "$config" | head -n1)
    [[ "$bind" == *:* ]] && CODE_SERVER_PORT=${bind##*:}
  elif service_exists code-server@"$DEV_USER".service || service_exists code-server.service; then
    CODE_SERVER_ENABLED=true
  else
    CODE_SERVER_ENABLED=false
  fi
  if [[ -r /etc/ai-development-file-manager.env ]]; then
    safe_source_env /etc/ai-development-file-manager.env
    FILE_MANAGER_ENABLED=$(bool_value "${FILE_MANAGER_ENABLED:-false}")
    : "${FILE_MANAGER_PORT:=8081}"
  else
    service_exists filebrowser-quantum.service && FILE_MANAGER_ENABLED=true || FILE_MANAGER_ENABLED=false
  fi
  if [[ -r /etc/ai-development-termix.env ]]; then
    safe_source_env /etc/ai-development-termix.env
    TERMIX_ENABLED=$(bool_value "${TERMIX_ENABLED:-false}")
    : "${TERMIX_PORT:=8082}"
  else
    docker inspect termix >/dev/null 2>&1 && TERMIX_ENABLED=true || TERMIX_ENABLED=false
  fi
  CODEX_LINUX_USER=${CODEX_LINUX_USER:-$DEV_USER}
  CODEX_HOME=${CODEX_HOME:-/home/$CODEX_LINUX_USER/.codex}
}

prompt_settings() {
  local current_default choice
  current_default=no; is_true "$ENABLE_HOMEPAGE" && current_default=yes
  ask_yes_no "WEB SERVICES GATEWAY" "Install or enable Homepage dashboard?\n\nExisting configuration and data are preserved when disabled." "$current_default" && ENABLE_HOMEPAGE=true || ENABLE_HOMEPAGE=false

  current_default=no; is_true "$ENABLE_CADDY" && current_default=yes
  is_true "$ENABLE_HOMEPAGE" && current_default=yes
  ask_yes_no "WEB SERVICES GATEWAY" "Install or enable Caddy reverse proxy?\n\nCaddy provides friendly hostnames and is required before backend ports can be restricted." "$current_default" && ENABLE_CADDY=true || ENABLE_CADDY=false

  GATEWAY_DOMAIN=$(input_box "LOCAL DOMAIN" "Local domain suffix:" "$GATEWAY_DOMAIN")
  DASHBOARD_HOSTNAME=$(input_box "DASHBOARD HOSTNAME" "Dashboard hostname prefix:" "$DASHBOARD_HOSTNAME")
  CODE_HOSTNAME=$(input_box "CODE HOSTNAME" "code-server hostname prefix:" "$CODE_HOSTNAME")
  FILES_HOSTNAME=$(input_box "FILES HOSTNAME" "FileBrowser hostname prefix:" "$FILES_HOSTNAME")
  TERMIX_HOSTNAME=$(input_box "TERMIX HOSTNAME" "Termix hostname prefix:" "$TERMIX_HOSTNAME")

  choice=$(menu_box "HTTPS MODE" "Choose the Caddy gateway mode." \
    http "HTTP only (trusted LAN)" internal "HTTPS using Caddy's internal CA") || return 1
  GATEWAY_HTTPS_MODE=$choice
  [[ "$choice" != internal ]] || whiptail --title "INTERNAL CA" --msgbox "Client devices must trust Caddy's local root certificate before internal HTTPS will be trusted." 10 76

  current_default=no; is_true "$RESTRICT_BACKEND_PORTS" && current_default=yes
  if is_true "$ENABLE_CADDY" && ask_yes_no "BACKEND EXPOSURE" "Restrict code-server, FileBrowser, and Termix to localhost after every proxy route passes?\n\nDirect access to ports 8080, 8081, and 8082 will stop." "$current_default"; then
    RESTRICT_BACKEND_PORTS=true
  else
    RESTRICT_BACKEND_PORTS=false
  fi

  current_default=no; is_true "$HOMEPAGE_SYSTEM_WIDGETS" && current_default=yes
  ask_yes_no "HOMEPAGE WIDGETS" "Enable Homepage CPU, memory, uptime, and disk widgets?" "$current_default" && HOMEPAGE_SYSTEM_WIDGETS=true || HOMEPAGE_SYSTEM_WIDGETS=false

  current_default=no; is_true "$HOMEPAGE_DOCKER_DISCOVERY" && current_default=yes
  if ask_yes_no "DOCKER DISCOVERY" "Allow Homepage to discover Docker containers automatically?\n\nWARNING: This mounts the Docker socket read-only into Homepage. The socket still grants powerful control over Docker." "$current_default"; then
    HOMEPAGE_DOCKER_DISCOVERY=true
  else
    HOMEPAGE_DOCKER_DISCOVERY=false
  fi
  PROXMOX_WEB_URL=$(input_box "PROXMOX URL" "Optional Proxmox management URL; leave blank to omit the tile:" "$PROXMOX_WEB_URL")

  current_default=no; is_true "$ENABLE_CODEX_CLI" && current_default=yes
  ask_yes_no "CODEX CLI" "Install or repair OpenAI Codex CLI for a non-root development user?" "$current_default" && ENABLE_CODEX_CLI=true || ENABLE_CODEX_CLI=false
  if is_true "$ENABLE_CODEX_CLI"; then
    CODEX_LINUX_USER=$(input_box "CODEX USER" "Linux user that will run Codex CLI:" "${CODEX_LINUX_USER:-$DEV_USER}")
    choice=$(menu_box "CODEX AUTHENTICATION" "ChatGPT sign-in uses included plan allowance. API-key usage is billed separately." \
      chatgpt "Sign in with ChatGPT (default; no API key)" api "API key (advanced; separately billed)") || return 1
    CODEX_AUTH_MODE=$choice
    choice=$(menu_box "CODEX CREDENTIAL STORE" "Choose where Codex caches credentials." \
      auto "Use keyring when available, otherwise protected file" keyring "Require OS keyring" file "Protected ~/.codex/auth.json") || return 1
    CODEX_CREDENTIAL_STORE=$choice
  fi
  normalize_state
  validate_state
}

show_guest_summary() {
  local scheme ip
  scheme=$(gateway_scheme)
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  cat <<SUMMARY

AI Development Web Gateway v${AI_DEV_VERSION}

Dashboard:
  ${scheme}://$(fqdn_dashboard)

Services:
$(is_true "$CODE_SERVER_ENABLED" && printf '  VS Code Web:  %s://%s\n' "$scheme" "$(fqdn_code)")
$(is_true "$FILE_MANAGER_ENABLED" && printf '  File Manager: %s://%s\n' "$scheme" "$(fqdn_files)")
$(is_true "$TERMIX_ENABLED" && printf '  Termix:       %s://%s\n' "$scheme" "$(fqdn_termix)")

Required DNS:
  *.${DASHBOARD_HOSTNAME}.${GATEWAY_DOMAIN} -> ${ip:-LXC_IP}

Commands:
  gateway-status --check
  gateway-dns-records
  homepage-status
  homepage-backup
  homepage-update
  codex-status --check
  codex-login
  sudo codex-update

Security:
  Homepage has no built-in authentication. Keep this gateway on a trusted LAN,
  or add authenticated edge access / VPN before remote use.
SUMMARY
}

guest_install() {
  require_root
  ensure_runtime_dirs
  if [[ -n "$STATE_INPUT" ]]; then
    cp -a "$STATE_INPUT" "$AI_DEV_STATE_FILE"
    chmod 0644 "$AI_DEV_STATE_FILE"
  fi
  load_state
  detect_guest_services
  if ! is_true "$NON_INTERACTIVE"; then ensure_whiptail; prompt_settings; fi
  validate_state
  persist_state
  is_true "$VALIDATE_ONLY" && { echo "State valid"; exit 0; }

  install_codex
  persist_state
  install_homepage
  persist_state
  install_caddy
  persist_state
  restrict_backend_bindings
  persist_state

  is_true "$ENABLE_CODEX_CLI" && codex-status --check
  is_true "$ENABLE_HOMEPAGE" && homepage-status
  is_true "$ENABLE_CADDY" && gateway-status --check
  show_guest_summary
  info "AI Development LXC v$AI_DEV_VERSION provisioning completed"
}

host_managed_ctids() {
  local file
  shopt -s nullglob
  for file in /etc/claude-dev-lxc/*.conf /etc/ai-dev-lxc/*.conf; do basename "$file" .conf; done | sort -u
  shopt -u nullglob
}

host_select_ctid() {
  [[ -n "$CTID" ]] && return 0
  if is_true "$NON_INTERACTIVE"; then die "--ctid is required in non-interactive host mode"; fi
  local entries=() id name
  while read -r id; do
    [[ -n "$id" ]] || continue
    pct status "$id" >/dev/null 2>&1 || continue
    name=$(pct config "$id" | awk -F': ' '$1=="hostname" {print $2; exit}')
    entries+=("$id" "${name:-managed LXC}")
  done < <(host_managed_ctids)
  if ((${#entries[@]})); then
    CTID=$(whiptail --title "SELECT LXC" --menu "Select the AI Development LXC to update." 18 76 9 "${entries[@]}" 3>&1 1>&2 2>&3) || exit 0
  else
    CTID=$(input_box "LXC ID" "Enter the numeric ID of the existing AI Development LXC:" '')
  fi
  [[ "$CTID" =~ ^[1-9][0-9]{1,8}$ ]] || die "Invalid CTID: $CTID"
}

host_wait_guest() {
  local i
  for i in $(seq 1 40); do pct exec "$CTID" -- true >/dev/null 2>&1 && return 0; sleep 2; done
  return 1
}

host_load_guest_state() {
  local tmp
  tmp=$(mktemp)
  if pct exec "$CTID" -- test -r "$AI_DEV_STATE_FILE"; then
    state_migration_defaults
    pct exec "$CTID" -- cat "$AI_DEV_STATE_FILE" > "$tmp"
    safe_source_env "$tmp"
  else
    # Migration defaults preserve the currently installed state on older v2.2.x containers.
    ENABLE_CADDY=$(pct exec "$CTID" -- bash -lc 'command -v caddy >/dev/null && echo true || echo false')
    ENABLE_HOMEPAGE=$(pct exec "$CTID" -- bash -lc 'docker inspect homepage >/dev/null 2>&1 && echo true || echo false')
    ENABLE_CODEX_CLI=$(pct exec "$CTID" -- bash -lc 'find /home -path "*/.local/bin/codex" -o -path "*/.codex/bin/codex" 2>/dev/null | grep -q . && echo true || echo false')
    RESTRICT_BACKEND_PORTS=false
  fi
  rm -f "$tmp"
  state_defaults
  normalize_state
  DEV_USER=$(pct exec "$CTID" -- bash -lc 'p=$(find /home -path "*/.config/code-server/config.yaml" -type f -print -quit 2>/dev/null); if [[ -n "$p" ]]; then cut -d/ -f3 <<<"$p"; elif id dev >/dev/null 2>&1; then echo dev; else getent passwd 1000 | cut -d: -f1; fi' 2>/dev/null || echo dev)
  CODEX_LINUX_USER=${CODEX_LINUX_USER:-$DEV_USER}
  CODEX_HOME=/home/$CODEX_LINUX_USER/.codex
  CODE_SERVER_ENABLED=$(pct exec "$CTID" -- bash -lc 'systemctl list-unit-files "code-server*" 2>/dev/null | grep -q code-server && echo true || echo false')
  CODE_SERVER_PORT=$(pct exec "$CTID" -- bash -lc 'p=$(find /home -path "*/.config/code-server/config.yaml" -type f -print -quit); sed -n "s/^bind-addr:.*://p" "$p" | head -n1' 2>/dev/null || echo 8080)
  [[ "$CODE_SERVER_PORT" =~ ^[0-9]+$ ]] || CODE_SERVER_PORT=8080
  FILE_MANAGER_ENABLED=$(pct exec "$CTID" -- bash -lc 'systemctl is-enabled filebrowser-quantum.service >/dev/null 2>&1 && echo true || echo false')
  FILE_MANAGER_PORT=$(pct exec "$CTID" -- bash -lc 'source /etc/ai-development-file-manager.env 2>/dev/null; echo "${FILE_MANAGER_PORT:-8081}"' 2>/dev/null || echo 8081)
  TERMIX_ENABLED=$(pct exec "$CTID" -- bash -lc 'docker inspect termix >/dev/null 2>&1 && echo true || echo false')
  TERMIX_PORT=$(pct exec "$CTID" -- bash -lc 'source /etc/ai-development-termix.env 2>/dev/null; echo "${TERMIX_PORT:-8082}"' 2>/dev/null || echo 8082)
  normalize_state
}

host_write_state_file() {
  local target=$1
  write_env_file "$target" 0644 \
    GATEWAY_MANAGED_VERSION ENABLE_CADDY ENABLE_HOMEPAGE GATEWAY_DOMAIN DASHBOARD_HOSTNAME \
    CODE_HOSTNAME FILES_HOSTNAME TERMIX_HOSTNAME GATEWAY_HTTPS_MODE RESTRICT_BACKEND_PORTS \
    HOMEPAGE_PORT HOMEPAGE_IMAGE HOMEPAGE_DOCKER_DISCOVERY HOMEPAGE_SYSTEM_WIDGETS PROXMOX_WEB_URL \
    ENABLE_CODEX_CLI CODEX_LINUX_USER CODEX_AUTH_MODE CODEX_CREDENTIAL_STORE CODEX_HOME \
    CODEX_INSTALL_METHOD CODEX_INSTALLED_VERSION CODEX_INSTALLED_PATH CODEX_INSTALL_TIMESTAMP \
    CODEX_WORKSPACE_ROOT DEV_USER CODE_SERVER_ENABLED CODE_SERVER_PORT FILE_MANAGER_ENABLED \
    FILE_MANAGER_PORT TERMIX_ENABLED TERMIX_PORT
}

host_update_legacy_state() {
  local legacy file key value tmp
  for legacy in "/etc/claude-dev-lxc/$CTID.conf" "/etc/ai-dev-lxc/$CTID.conf"; do
    [[ -f "$legacy" ]] || continue
    cp -a "$legacy" "${legacy}.before-v2.2.7-$(timestamp)"
    tmp=$(mktemp)
    cp -a "$legacy" "$tmp"
    for key in ENABLE_CADDY ENABLE_HOMEPAGE GATEWAY_DOMAIN DASHBOARD_HOSTNAME CODE_HOSTNAME FILES_HOSTNAME TERMIX_HOSTNAME GATEWAY_HTTPS_MODE RESTRICT_BACKEND_PORTS HOMEPAGE_PORT HOMEPAGE_IMAGE HOMEPAGE_DOCKER_DISCOVERY PROXMOX_WEB_URL ENABLE_CODEX_CLI CODEX_LINUX_USER CODEX_AUTH_MODE CODEX_CREDENTIAL_STORE CODEX_HOME CODEX_INSTALL_METHOD CODEX_INSTALLED_VERSION CODEX_WORKSPACE_ROOT; do
      value=${!key-}
      sed -i "/^${key}=/d" "$tmp"
      printf '%s=%q\n' "$key" "$value" >> "$tmp"
    done
    install -m 0600 "$tmp" "$legacy"
    rm -f "$tmp"
  done
}

host_push_and_run() {
  local archive state_tmp remote_archive=/root/ai-dev-lxc-v2.2.7.tar.gz
  archive=$(mktemp --suffix=.tar.gz)
  state_tmp=$(mktemp)
  tar -czf "$archive" -C "$SCRIPT_DIR/.." ai-dev-lxc
  host_write_state_file "$state_tmp"
  pct push "$CTID" "$archive" "$remote_archive" --perms 0600
  pct exec "$CTID" -- bash -lc 'rm -rf /opt/ai-dev-lxc-helper && mkdir -p /opt/ai-dev-lxc-helper && tar -xzf /root/ai-dev-lxc-v2.2.7.tar.gz -C /opt/ai-dev-lxc-helper --strip-components=1 && rm -f /root/ai-dev-lxc-v2.2.7.tar.gz'
  pct push "$CTID" "$state_tmp" "$AI_DEV_STATE_FILE" --perms 0644
  rm -f "$archive" "$state_tmp"
  pct exec "$CTID" -- /opt/ai-dev-lxc-helper/install.sh --guest --non-interactive
}

host_verify_routes() {
  is_true "$ENABLE_CADDY" || return 0
  local ip scheme flags=() host code failed=0
  local hosts=()
  ip=$(pct exec "$CTID" -- bash -lc "hostname -I | awk '{print \$1}'")
  scheme=$(gateway_scheme)
  [[ "$scheme" == https ]] && flags=(-k)
  is_true "$ENABLE_HOMEPAGE" && hosts+=("$(fqdn_dashboard)")
  is_true "$CODE_SERVER_ENABLED" && hosts+=("$(fqdn_code)")
  is_true "$FILE_MANAGER_ENABLED" && hosts+=("$(fqdn_files)")
  is_true "$TERMIX_ENABLED" && hosts+=("$(fqdn_termix)")
  for host in "${hosts[@]}"; do
    code=$(curl "${flags[@]}" -sS -o /dev/null -w '%{http_code}' -H "Host: $host" --connect-timeout 5 --max-time 12 "${scheme}://${ip}/" 2>/dev/null || true)
    if http_status_ok "$code"; then info "Proxmox-host route check passed: $host ($code)"
    else warn "Proxmox-host route check failed: $host ($code)"; failed=1; fi
  done
  ((failed == 0)) || die "One or more routes failed from the Proxmox host; inspect LXC and Proxmox firewall rules"
}

host_install() {
  require_root
  command_exists pct || die "pct was not found; run host mode on a Proxmox VE node"
  ensure_whiptail
  host_select_ctid
  pct status "$CTID" >/dev/null 2>&1 || die "LXC $CTID does not exist"
  if [[ $(pct status "$CTID" | awk '{print $2}') != running ]]; then pct start "$CTID"; host_wait_guest || die "LXC did not become ready"; fi
  host_load_guest_state
  prompt_settings
  validate_state
  if ! ask_yes_no "APPLY v2.2.7" "Install/repair Codex CLI, Homepage, Caddy, DNS helpers, management commands, and safe backend bindings in LXC $CTID?\n\nExisting projects, credentials, databases, and Termix volumes are preserved." yes; then exit 0; fi
  host_push_and_run
  host_load_guest_state
  host_update_legacy_state
  host_verify_routes
  whiptail --title "COMPLETED" --msgbox "AI Development LXC $CTID was updated to v2.2.7.\n\nRun inside the LXC:\n  gateway-status --check\n  gateway-dns-records\n  codex-login" 14 78
}

main() {
  if is_true "$GUEST_MODE"; then guest_install; return; fi
  if command_exists pct && [[ -d /etc/pve ]]; then host_install; else guest_install; fi
}

main
