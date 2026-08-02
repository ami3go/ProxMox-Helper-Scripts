#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Interactive Proxmox VE LXC installer for a headless multi-agent AI development environment.
# Installs: Debian LXC, code-server, selectable AI coding agents, Python,
# Robot Framework, RobotCode, Git, GitHub CLI, SSH, and a starter workspace.
#
# Run this script as root on the Proxmox VE host.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.2.1"
readonly BACKTITLE="AI Development LXC • Proxmox VE"
readonly STATE_DIR="/etc/claude-dev-lxc"
readonly LOG_DIR="/var/log/claude-dev-lxc"
readonly DEFAULT_HOSTNAME="ai-dev"
readonly DEFAULT_USER="dev"
readonly DEFAULT_CORES="4"
readonly DEFAULT_MEMORY="8192"
readonly DEFAULT_SWAP="2048"
readonly DEFAULT_DISK="50"
readonly DEFAULT_PORT="8080"

LOG_FILE=""
LAST_ERROR=""
PROVISION_WARNING=""

# Runtime configuration
CTID=""
CT_HOSTNAME="$DEFAULT_HOSTNAME"
DEV_USER="$DEFAULT_USER"
CORES="$DEFAULT_CORES"
MEMORY="$DEFAULT_MEMORY"
SWAP="$DEFAULT_SWAP"
DISK_SIZE="$DEFAULT_DISK"
TEMPLATE_STORAGE=""
ROOTFS_STORAGE=""
BRIDGE=""
VLAN=""
IP_MODE="dhcp"
IP_CIDR=""
GATEWAY=""
NAMESERVER=""
ACCESS_MODE="tunnel"
CODE_SERVER_PORT="$DEFAULT_PORT"
CODE_SERVER_PASSWORD=""
DEV_PASSWORD=""
SSH_KEY_FILE=""
SSH_KEY_CONTENT=""
PASSWORD_AUTH="yes"
GIT_NAME=""
GIT_EMAIL=""
TEMPLATE_FILE=""
TEMPLATE_VOLID=""
CONFIGURE_SSH="1"
SELECTED_AGENTS="claude"

# ---------- Terminal UI ----------

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    printf 'ERROR: Run this script as root on the Proxmox VE host.\n' >&2
    exit 1
  fi
}

ensure_whiptail() {
  if command -v whiptail >/dev/null 2>&1; then
    return 0
  fi

  printf 'whiptail is required for the interactive interface.\n'
  read -r -p 'Install the Debian whiptail package now? [Y/n] ' answer
  answer=${answer:-Y}
  if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    printf 'Installation cancelled.\n'
    exit 1
  fi

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail
}

init_logging() {
  install -d -m 0700 "$STATE_DIR" "$LOG_DIR"
  LOG_FILE="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

show_error_details() {
  local message=${1:-"An unexpected error occurred."}
  local excerpt=""
  if [[ -s "$LOG_FILE" ]]; then
    excerpt=$(tail -n 18 "$LOG_FILE" | sed 's/[^[:print:]\t]//g')
  fi
  whiptail --backtitle "$BACKTITLE" --title "ERROR" --scrolltext --msgbox \
    "$message

${excerpt:+Recent log output:
$excerpt

}Full log:
$LOG_FILE" 24 90 || true
}

on_error() {
  local rc=$?
  local line=${BASH_LINENO[0]:-unknown}
  local command=${BASH_COMMAND:-unknown}
  LAST_ERROR="Failure at line $line (exit $rc): $command"
  log "$LAST_ERROR"
  show_error_details "$LAST_ERROR"
  exit "$rc"
}

trap on_error ERR
trap 'log "Interrupted by user"; exit 130' INT TERM

msg_info() {
  local message=$1
  whiptail --backtitle "$BACKTITLE" --title "PLEASE WAIT" --infobox "$message" 8 72
  sleep 0.15
  log "INFO: $message"
}

msg_ok() {
  local message=$1
  whiptail --backtitle "$BACKTITLE" --title "SUCCESS" --msgbox "$message" 10 76
  log "OK: $message"
}

msg_warn() {
  local message=$1
  whiptail --backtitle "$BACKTITLE" --title "WARNING" --msgbox "$message" 12 78
  log "WARNING: $message"
}

ask_yes_no() {
  local title=$1
  local message=$2
  local default=${3:-yes}
  local default_flag=()
  [[ "$default" == "no" ]] && default_flag=(--defaultno)
  whiptail --backtitle "$BACKTITLE" --title "$title" "${default_flag[@]}" \
    --yesno "$message" 13 78
}

input_box() {
  local title=$1
  local prompt=$2
  local default=${3:-}
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --inputbox "$prompt" 12 78 "$default" 3>&1 1>&2 2>&3
}

password_box() {
  local title=$1
  local prompt=$2
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --passwordbox "$prompt" 12 78 3>&1 1>&2 2>&3
}

menu_box() {
  local title=$1
  local prompt=$2
  shift 2
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --menu "$prompt" 20 82 11 "$@" 3>&1 1>&2 2>&3
}

checklist_box() {
  local title=$1
  local prompt=$2
  shift 2
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --separate-output --checklist "$prompt" 24 96 13 "$@" 3>&1 1>&2 2>&3
}

choose_from_list() {
  local title=$1
  local prompt=$2
  shift 2
  local entries=("$@")
  local menu_args=()
  local item

  if ((${#entries[@]} == 0)); then
    return 1
  fi
  for item in "${entries[@]}"; do
    menu_args+=("$item" "")
  done
  menu_box "$title" "$prompt" "${menu_args[@]}"
}

# ---------- AI agent selection ----------

agent_selected() {
  local agent=$1
  [[ ",$SELECTED_AGENTS," == *",$agent,"* ]]
}

agent_name() {
  case "$1" in
    claude) printf 'Claude Code' ;;
    codex) printf 'OpenAI Codex CLI' ;;
    gemini) printf 'Google Gemini CLI' ;;
    copilot) printf 'GitHub Copilot CLI' ;;
    aider) printf 'Aider' ;;
    opencode) printf 'OpenCode' ;;
    *) printf '%s' "$1" ;;
  esac
}

selected_agents_display() {
  local agent name result=""
  local ordered=(claude codex gemini copilot aider opencode)
  for agent in "${ordered[@]}"; do
    if agent_selected "$agent"; then
      name=$(agent_name "$agent")
      result+="${result:+, }$name"
    fi
  done
  printf '%s' "${result:-none}"
}

choose_ai_agents() {
  local output
  local args=()
  local agent state
  local ordered=(claude codex gemini copilot aider opencode)

  while true; do
    args=()
    for agent in "${ordered[@]}"; do
      state=OFF
      agent_selected "$agent" && state=ON
      case "$agent" in
        claude) args+=("claude" "Anthropic terminal coding agent; browser sign-in" "$state") ;;
        codex) args+=("codex" "OpenAI terminal coding agent; ChatGPT or API sign-in" "$state") ;;
        gemini) args+=("gemini" "Google terminal agent; OAuth or Gemini API key" "$state") ;;
        copilot) args+=("copilot" "GitHub terminal agent; Copilot plan and /login required" "$state") ;;
        aider) args+=("aider" "Open-source pair programmer; supports many model providers" "$state") ;;
        opencode) args+=("opencode" "Open-source terminal agent; supports multiple providers" "$state") ;;
      esac
    done

    output=$(checklist_box "AI CODING AGENTS" \
      "Select one or more agents to install or update.\n\nSpace toggles an item; Enter confirms. Deselecting an agent during repair does not uninstall an existing copy." \
      "${args[@]}") || return 1

    output=$(printf '%s\n' "$output" | sed -e '/^[[:space:]]*$/d' -e 's/^"//' -e 's/"$//')
    if [[ -z "$output" ]]; then
      msg_warn "Select at least one AI coding agent."
      continue
    fi

    SELECTED_AGENTS=$(printf '%s\n' "$output" | paste -sd, -)
    log "Selected AI agents: $SELECTED_AGENTS"
    return 0
  done
}

# ---------- Validation ----------

is_integer_range() {
  local value=$1 min=$2 max=$3
  [[ "$value" =~ ^[0-9]+$ ]] && ((value >= min && value <= max))
}

valid_hostname() {
  local value=$1
  [[ ${#value} -le 63 && "$value" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]
}

valid_username() {
  local value=$1
  [[ "$value" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

valid_cidr() {
  local value=$1
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
  local ip=${value%/*}
  local octet
  IFS=. read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
  done
}

valid_ipv4() {
  local value=$1
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local octet
  IFS=. read -r -a octets <<<"$value"
  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
  done
}

prompt_validated() {
  local variable_name=$1 title=$2 prompt=$3 default=$4 validator=$5 error_message=$6
  local value
  while true; do
    value=$(input_box "$title" "$prompt" "$default") || return 1
    if "$validator" "$value"; then
      printf -v "$variable_name" '%s' "$value"
      return 0
    fi
    msg_warn "$error_message"
  done
}

prompt_integer() {
  local variable_name=$1 title=$2 prompt=$3 default=$4 min=$5 max=$6
  local value
  while true; do
    value=$(input_box "$title" "$prompt"$'\n\n'"Allowed range: $min–$max" "$default") || return 1
    if is_integer_range "$value" "$min" "$max"; then
      printf -v "$variable_name" '%s' "$value"
      return 0
    fi
    msg_warn "Enter a whole number between $min and $max."
  done
}

# ---------- Proxmox discovery ----------

check_proxmox_host() {
  local required=(pveversion pct pvesm pveam pvesh ip awk sed grep base64 openssl)
  local missing=()
  local cmd
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    whiptail --backtitle "$BACKTITLE" --title "UNSUPPORTED HOST" --msgbox \
      "This script must run on a Proxmox VE host.

Missing commands: ${missing[*]}" 13 78
    exit 1
  fi

  log "Host version: $(pveversion 2>/dev/null || true)"
}

next_ctid() {
  pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9'
}

list_template_storages() {
  local result
  result=$(pvesm status --content vztmpl 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}') || true
  if [[ -z "$result" ]]; then
    result=$(pvesm status 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}') || true
  fi
  printf '%s\n' "$result" | awk 'NF && !seen[$0]++'
}

list_rootfs_storages() {
  local result
  result=$(pvesm status --content rootdir 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}') || true
  if [[ -z "$result" ]]; then
    result=$(pvesm status 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1}') || true
  fi
  printf '%s\n' "$result" | awk 'NF && !seen[$0]++'
}

list_bridges() {
  ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^vmbr[[:alnum:]_.-]*$/ {print $2}' | awk '!seen[$0]++'
}

select_default_storage() {
  local preferred=$1
  shift
  local entry
  for entry in "$@"; do
    [[ "$entry" == "$preferred" ]] && { printf '%s' "$entry"; return; }
  done
  printf '%s' "${1:-}"
}

find_debian_template() {
  local arch
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  msg_info "Refreshing the Proxmox appliance-template index…"
  pveam update >>"$LOG_FILE" 2>&1

  TEMPLATE_FILE=$(pveam available --section system 2>/dev/null \
    | awk -v arch="$arch" '$2 ~ /^debian-(13|12)-standard_/ && $2 ~ arch {print $2}' \
    | sort -V | tail -n 1)

  if [[ -z "$TEMPLATE_FILE" ]]; then
    TEMPLATE_FILE=$(pveam available --section system 2>/dev/null \
      | awk '$2 ~ /^debian-.*-standard_/ {print $2}' \
      | sort -V | tail -n 1)
  fi

  if [[ -z "$TEMPLATE_FILE" ]]; then
    show_error_details "No Debian standard LXC template was found in the Proxmox appliance index."
    return 1
  fi

  TEMPLATE_VOLID="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}"
  log "Selected template: $TEMPLATE_VOLID"
}

ensure_template_downloaded() {
  find_debian_template
  if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq "$TEMPLATE_VOLID"; then
    log "Template already present: $TEMPLATE_VOLID"
    return 0
  fi

  msg_info "Downloading $TEMPLATE_FILE to $TEMPLATE_STORAGE…"
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE" >>"$LOG_FILE" 2>&1
}

# ---------- Configuration wizard ----------

load_defaults() {
  CTID=$(next_ctid)
  CT_HOSTNAME="$DEFAULT_HOSTNAME"
  DEV_USER="$DEFAULT_USER"
  CORES="$DEFAULT_CORES"
  MEMORY="$DEFAULT_MEMORY"
  SWAP="$DEFAULT_SWAP"
  DISK_SIZE="$DEFAULT_DISK"
  VLAN=""
  IP_MODE="dhcp"
  IP_CIDR=""
  GATEWAY=""
  NAMESERVER=""
  ACCESS_MODE="tunnel"
  CODE_SERVER_PORT="$DEFAULT_PORT"
  CODE_SERVER_PASSWORD=""
  SSH_KEY_FILE=""
  SSH_KEY_CONTENT=""
  GIT_NAME=""
  GIT_EMAIL=""
  CONFIGURE_SSH="1"
  SELECTED_AGENTS="claude"

  mapfile -t template_storages < <(list_template_storages)
  mapfile -t rootfs_storages < <(list_rootfs_storages)
  mapfile -t bridges < <(list_bridges)

  TEMPLATE_STORAGE=$(select_default_storage local "${template_storages[@]}")
  ROOTFS_STORAGE=$(select_default_storage local-lvm "${rootfs_storages[@]}")
  BRIDGE=$(select_default_storage vmbr0 "${bridges[@]}")

  [[ -n "$TEMPLATE_STORAGE" ]] || TEMPLATE_STORAGE="local"
  [[ -n "$ROOTFS_STORAGE" ]] || ROOTFS_STORAGE="local-lvm"
  [[ -n "$BRIDGE" ]] || BRIDGE="vmbr0"
}

choose_ssh_access() {
  local choice
  choice=$(menu_box "SSH ACCESS" \
    "Choose how the development user will initially authenticate over SSH." \
    "1" "Generate a strong temporary password" \
    "2" "Import a public-key file from the Proxmox host" \
    "3" "Paste an SSH public key" \
    "4" "Password plus a public key") || return 1

  case "$choice" in
    1)
      DEV_PASSWORD=$(openssl rand -hex 12)
      PASSWORD_AUTH="yes"
      ;;
    2)
      while true; do
        SSH_KEY_FILE=$(input_box "SSH PUBLIC KEY" \
          "Enter the path to a public-key or authorized_keys file on the Proxmox host." \
          "/root/.ssh/authorized_keys") || return 1
        if [[ -f "$SSH_KEY_FILE" && -s "$SSH_KEY_FILE" ]]; then
          SSH_KEY_CONTENT=$(cat "$SSH_KEY_FILE")
          break
        fi
        msg_warn "The selected file does not exist or is empty."
      done
      DEV_PASSWORD=""
      PASSWORD_AUTH="no"
      ;;
    3)
      while true; do
        SSH_KEY_CONTENT=$(input_box "SSH PUBLIC KEY" \
          "Paste one OpenSSH public key on a single line." "") || return 1
        if [[ "$SSH_KEY_CONTENT" =~ ^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-) ]]; then
          break
        fi
        msg_warn "The value does not look like an OpenSSH public key."
      done
      DEV_PASSWORD=""
      PASSWORD_AUTH="no"
      ;;
    4)
      DEV_PASSWORD=$(openssl rand -hex 12)
      PASSWORD_AUTH="yes"
      while true; do
        SSH_KEY_FILE=$(input_box "SSH PUBLIC KEY" \
          "Enter a public-key or authorized_keys file on the Proxmox host, or leave blank to paste a key next." "") || return 1
        if [[ -z "$SSH_KEY_FILE" ]]; then
          SSH_KEY_CONTENT=$(input_box "SSH PUBLIC KEY" \
            "Paste one OpenSSH public key on a single line." "") || return 1
          [[ "$SSH_KEY_CONTENT" =~ ^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-) ]] && break
        elif [[ -f "$SSH_KEY_FILE" && -s "$SSH_KEY_FILE" ]]; then
          SSH_KEY_CONTENT=$(cat "$SSH_KEY_FILE")
          break
        fi
        msg_warn "A valid public key is required for this option."
      done
      ;;
  esac
}

configure_default_mode() {
  DEV_PASSWORD=$(openssl rand -hex 12)
  PASSWORD_AUTH="yes"

  if [[ -s /root/.ssh/authorized_keys ]]; then
    if ask_yes_no "SSH KEY" \
      "Reuse the public keys from /root/.ssh/authorized_keys for the container's '$DEV_USER' account?

Selecting Yes allows the same SSH client keys used for the Proxmox host to access the LXC." yes; then
      SSH_KEY_CONTENT=$(cat /root/.ssh/authorized_keys)
    fi
  fi

  choose_ai_agents || return 1
}

configure_advanced_mode() {
  local choice
  local value

  prompt_integer CTID "CONTAINER ID" "Choose a unique Proxmox container ID." "$CTID" 100 999999 || return 1
  if pct status "$CTID" >/dev/null 2>&1; then
    msg_warn "Container ID $CTID already exists. Choose another ID."
    return 1
  fi

  prompt_validated CT_HOSTNAME "HOSTNAME" "Container hostname:" "$CT_HOSTNAME" valid_hostname \
    "Use a valid DNS-style hostname without spaces." || return 1
  prompt_validated DEV_USER "DEVELOPMENT USER" "Linux development username:" "$DEV_USER" valid_username \
    "Use a lowercase Linux username beginning with a letter or underscore." || return 1

  prompt_integer CORES "CPU" "CPU cores assigned to the LXC:" "$CORES" 1 64 || return 1
  prompt_integer MEMORY "MEMORY" "RAM in MiB:" "$MEMORY" 1024 262144 || return 1
  prompt_integer SWAP "SWAP" "Swap in MiB:" "$SWAP" 0 65536 || return 1
  prompt_integer DISK_SIZE "ROOT DISK" "Root filesystem size in GiB:" "$DISK_SIZE" 16 2048 || return 1

  mapfile -t template_storages < <(list_template_storages)
  mapfile -t rootfs_storages < <(list_rootfs_storages)
  mapfile -t bridges < <(list_bridges)

  TEMPLATE_STORAGE=$(choose_from_list "TEMPLATE STORAGE" \
    "Select storage for the Debian template." "${template_storages[@]}") || return 1
  ROOTFS_STORAGE=$(choose_from_list "ROOTFS STORAGE" \
    "Select storage for the LXC root filesystem." "${rootfs_storages[@]}") || return 1
  BRIDGE=$(choose_from_list "NETWORK BRIDGE" \
    "Select the Proxmox Linux bridge." "${bridges[@]}") || return 1

  VLAN=$(input_box "VLAN" "Optional VLAN tag (1–4094). Leave blank for untagged traffic." "$VLAN") || return 1
  if [[ -n "$VLAN" ]] && ! is_integer_range "$VLAN" 1 4094; then
    msg_warn "Invalid VLAN tag. The value must be blank or between 1 and 4094."
    return 1
  fi

  choice=$(menu_box "IP CONFIGURATION" "Choose the container IPv4 configuration." \
    "dhcp" "Obtain an address from DHCP" \
    "static" "Configure a static IPv4 address") || return 1
  IP_MODE=$choice

  if [[ "$IP_MODE" == "static" ]]; then
    while true; do
      IP_CIDR=$(input_box "STATIC ADDRESS" "IPv4 address with prefix, for example 192.168.0.60/24:" "$IP_CIDR") || return 1
      valid_cidr "$IP_CIDR" && break
      msg_warn "Enter a valid IPv4 CIDR address."
    done
    while true; do
      GATEWAY=$(input_box "GATEWAY" "IPv4 default gateway, for example 192.168.0.1:" "$GATEWAY") || return 1
      valid_ipv4 "$GATEWAY" && break
      msg_warn "Enter a valid IPv4 gateway address."
    done
    while true; do
      NAMESERVER=$(input_box "DNS" "DNS server address, or leave blank to inherit the Proxmox host setting:" "$NAMESERVER") || return 1
      if [[ -z "$NAMESERVER" ]] || valid_ipv4 "$NAMESERVER"; then
        break
      fi
      msg_warn "Enter a valid IPv4 DNS address or leave the field blank."
    done
  fi

  choice=$(menu_box "WEB IDE ACCESS" \
    "Choose how code-server will be exposed." \
    "tunnel" "Loopback only; connect through an SSH tunnel (recommended)" \
    "lan" "Listen on the LXC network with password authentication") || return 1
  ACCESS_MODE=$choice
  prompt_integer CODE_SERVER_PORT "WEB IDE PORT" "code-server TCP port:" "$CODE_SERVER_PORT" 1024 65535 || return 1
  if [[ "$ACCESS_MODE" == "lan" ]]; then
    CODE_SERVER_PASSWORD=$(openssl rand -hex 16)
  fi

  choose_ssh_access || return 1

  if ask_yes_no "GIT IDENTITY" "Configure a global Git author name and email for '$DEV_USER'?" no; then
    GIT_NAME=$(input_box "GIT AUTHOR" "Git author name:" "") || return 1
    GIT_EMAIL=$(input_box "GIT EMAIL" "Git author email:" "") || return 1
  fi

  choose_ai_agents || return 1
}

configuration_summary() {
  local network_summary
  local access_summary
  local ssh_summary
  local agents_summary

  if [[ "$IP_MODE" == "dhcp" ]]; then
    network_summary="DHCP on $BRIDGE"
  else
    network_summary="$IP_CIDR via $GATEWAY on $BRIDGE"
  fi
  [[ -n "$VLAN" ]] && network_summary+=" (VLAN $VLAN)"

  if [[ "$ACCESS_MODE" == "tunnel" ]]; then
    access_summary="SSH tunnel → 127.0.0.1:$CODE_SERVER_PORT"
  else
    access_summary="LAN → 0.0.0.0:$CODE_SERVER_PORT with password"
  fi

  agents_summary=$(selected_agents_display)

  if [[ -n "$SSH_KEY_CONTENT" && -n "$DEV_PASSWORD" ]]; then
    ssh_summary="public key plus generated password"
  elif [[ -n "$SSH_KEY_CONTENT" ]]; then
    ssh_summary="public key only"
  else
    ssh_summary="generated password"
  fi

  whiptail --backtitle "$BACKTITLE" --title "CONFIRM DEPLOYMENT" --yesno \
    "Review the planned container:

Container ID:       $CTID
Hostname:           $CT_HOSTNAME
Debian user:        $DEV_USER
Container type:     unprivileged
CPU / RAM / swap:   $CORES cores / ${MEMORY} MiB / ${SWAP} MiB
Root disk:          ${DISK_SIZE} GiB on $ROOTFS_STORAGE
Template storage:   $TEMPLATE_STORAGE
Network:            $network_summary
SSH authentication: $ssh_summary
Web IDE:            $access_summary
Start at boot:      enabled
Protection:         enabled after successful setup

AI agents:           $agents_summary

Software:
code-server, Python, Robot Framework, RobotCode, Git, GitHub CLI,
SSH, build tools, selected AI agents, and a starter workspace.

Create this container now?" 30 88
}

# ---------- Container creation ----------

build_net0() {
  local net="name=eth0,bridge=$BRIDGE,type=veth,firewall=1"
  if [[ "$IP_MODE" == "dhcp" ]]; then
    net+=",ip=dhcp"
  else
    net+=",ip=$IP_CIDR,gw=$GATEWAY"
  fi
  [[ -n "$VLAN" ]] && net+=",tag=$VLAN"
  printf '%s' "$net"
}

create_container() {
  local net0
  local args=()
  net0=$(build_net0)

  if pct status "$CTID" >/dev/null 2>&1; then
    show_error_details "Container ID $CTID already exists."
    return 1
  fi

  ensure_template_downloaded

  args=(
    create "$CTID" "$TEMPLATE_VOLID"
    --hostname "$CT_HOSTNAME"
    --ostype debian
    --unprivileged 1
    --cores "$CORES"
    --memory "$MEMORY"
    --swap "$SWAP"
    --rootfs "${ROOTFS_STORAGE}:${DISK_SIZE}"
    --net0 "$net0"
    --onboot 1
    --startup "order=20,up=30"
    --protection 0
    --tags "development;ai-agents;robotframework"
  )
  [[ -n "$NAMESERVER" ]] && args+=(--nameserver "$NAMESERVER")

  msg_info "Creating unprivileged Debian LXC $CTID…"
  if ! pct "${args[@]}" >>"$LOG_FILE" 2>&1; then
    show_error_details "Proxmox could not create LXC $CTID."
    return 1
  fi

  msg_info "Starting LXC $CTID…"
  pct start "$CTID" >>"$LOG_FILE" 2>&1

  local attempts=0
  until pct exec "$CTID" -- true >/dev/null 2>&1; do
    sleep 2
    ((attempts += 1))
    if ((attempts >= 30)); then
      show_error_details "LXC $CTID did not become ready within 60 seconds."
      return 1
    fi
  done
}

b64() {
  printf '%s' "$1" | base64 -w 0
}

write_provision_files() {
  local tmp_dir
  local env_file
  local provision_file
  tmp_dir=$(mktemp -d)
  env_file="$tmp_dir/claude-dev.env"
  provision_file="$tmp_dir/provision.sh"
  chmod 0700 "$tmp_dir"

  cat >"$env_file" <<ENV
DEV_USER_B64='$(b64 "$DEV_USER")'
DEV_PASSWORD_B64='$(b64 "$DEV_PASSWORD")'
SSH_KEY_B64='$(b64 "$SSH_KEY_CONTENT")'
PASSWORD_AUTH_B64='$(b64 "$PASSWORD_AUTH")'
ACCESS_MODE_B64='$(b64 "$ACCESS_MODE")'
CODE_SERVER_PORT_B64='$(b64 "$CODE_SERVER_PORT")'
CODE_SERVER_PASSWORD_B64='$(b64 "$CODE_SERVER_PASSWORD")'
GIT_NAME_B64='$(b64 "$GIT_NAME")'
GIT_EMAIL_B64='$(b64 "$GIT_EMAIL")'
CONFIGURE_SSH_B64='$(b64 "$CONFIGURE_SSH")'
SELECTED_AGENTS_B64='$(b64 "$SELECTED_AGENTS")'
ENV
  chmod 0600 "$env_file"

  cat >"$provision_file" <<'PROVISION'
#!/usr/bin/env bash
set -Eeuo pipefail

LOG_FILE=/var/log/claude-dev-provision.log
exec >>"$LOG_FILE" 2>&1
printf '\n[%s] Provisioning started\n' "$(date '+%F %T')"

source /root/claude-dev.env

decode() { printf '%s' "$1" | base64 -d; }
DEV_USER=$(decode "$DEV_USER_B64")
DEV_PASSWORD=$(decode "$DEV_PASSWORD_B64")
SSH_KEY=$(decode "$SSH_KEY_B64")
PASSWORD_AUTH=$(decode "$PASSWORD_AUTH_B64")
ACCESS_MODE=$(decode "$ACCESS_MODE_B64")
CODE_SERVER_PORT=$(decode "$CODE_SERVER_PORT_B64")
CODE_SERVER_PASSWORD=$(decode "$CODE_SERVER_PASSWORD_B64")
GIT_NAME=$(decode "$GIT_NAME_B64")
GIT_EMAIL=$(decode "$GIT_EMAIL_B64")
CONFIGURE_SSH=$(decode "$CONFIGURE_SSH_B64")
SELECTED_AGENTS=$(decode "$SELECTED_AGENTS_B64")
DEV_HOME="/home/$DEV_USER"

if [[ ! "$DEV_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then
  echo "Invalid development username" >&2
  exit 1
fi
if [[ ! "$CODE_SERVER_PORT" =~ ^[0-9]+$ ]]; then
  echo "Invalid code-server port" >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get full-upgrade -y
apt-get install -y --no-install-recommends \
  sudo openssh-server ca-certificates curl wget git gh gnupg \
  build-essential python3 python3-dev python3-pip python3-venv pipx \
  jq ripgrep fd-find tmux unzip zip rsync shellcheck openssl \
  make cmake pkg-config less nano vim bash-completion locales xz-utils
apt-get autoremove -y

systemctl enable --now ssh

if ! id "$DEV_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEV_USER"
fi
usermod -aG sudo,dialout "$DEV_USER"

install -d -m 0750 -o "$DEV_USER" -g "$DEV_USER" /srv/workspace
install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "$DEV_HOME/.ssh"

if [[ -n "$DEV_PASSWORD" ]]; then
  printf '%s:%s\n' "$DEV_USER" "$DEV_PASSWORD" | chpasswd
fi

if [[ -n "$SSH_KEY" ]]; then
  printf '%s\n' "$SSH_KEY" >"$DEV_HOME/.ssh/authorized_keys"
  chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.ssh/authorized_keys"
  chmod 0600 "$DEV_HOME/.ssh/authorized_keys"
fi

if [[ "$CONFIGURE_SSH" == "1" ]]; then
  cat >/etc/ssh/sshd_config.d/99-claude-development-lxc.conf <<EOF
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication $PASSWORD_AUTH
KbdInteractiveAuthentication no
X11Forwarding no
AllowUsers $DEV_USER
EOF
  sshd -t
  systemctl restart ssh
fi

# code-server: official Debian installer.
curl -fsSL https://code-server.dev/install.sh -o /tmp/install-code-server.sh
sh /tmp/install-code-server.sh
rm -f /tmp/install-code-server.sh

install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "$DEV_HOME/.config/code-server"
if [[ "$ACCESS_MODE" == "lan" ]]; then
  cat >"$DEV_HOME/.config/code-server/config.yaml" <<EOF
bind-addr: 0.0.0.0:$CODE_SERVER_PORT
auth: password
password: $CODE_SERVER_PASSWORD
cert: false
disable-telemetry: true
EOF
else
  cat >"$DEV_HOME/.config/code-server/config.yaml" <<EOF
bind-addr: 127.0.0.1:$CODE_SERVER_PORT
auth: none
cert: false
disable-telemetry: true
EOF
fi
chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.config/code-server/config.yaml"
chmod 0600 "$DEV_HOME/.config/code-server/config.yaml"
systemctl enable --now "code-server@$DEV_USER.service"

# Selected AI coding agents.
has_agent() {
  local agent=$1
  [[ ",$SELECTED_AGENTS," == *",$agent,"* ]]
}

DEV_PATH="$DEV_HOME/.local/bin:$DEV_HOME/.local/npm/bin:$DEV_HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin"
run_as_dev() {
  runuser -u "$DEV_USER" -- env \
    HOME="$DEV_HOME" USER="$DEV_USER" LOGNAME="$DEV_USER" PATH="$DEV_PATH" "$@"
}
run_as_dev_shell() {
  local command=$1
  run_as_dev bash -c "$command"
}

install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" \
  "$DEV_HOME/.config/ai-agents" "$DEV_HOME/.local/bin" "$DEV_HOME/.local/npm"

if [[ ! -f "$DEV_HOME/.config/ai-agents/env" ]]; then
  cat >"$DEV_HOME/.config/ai-agents/env" <<'EOF'
# Optional API keys for agents that support direct provider authentication.
# Keep this file private. Uncomment only the variables you use.
# export ANTHROPIC_API_KEY=""
# export OPENAI_API_KEY=""
# export GEMINI_API_KEY=""
# export GOOGLE_API_KEY=""
# export GOOGLE_CLOUD_PROJECT=""
# export OPENROUTER_API_KEY=""
# export DEEPSEEK_API_KEY=""
# export MISTRAL_API_KEY=""
# export XAI_API_KEY=""
EOF
fi
chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.config/ai-agents/env"
chmod 0600 "$DEV_HOME/.config/ai-agents/env"

for profile in "$DEV_HOME/.profile" "$DEV_HOME/.bashrc"; do
  touch "$profile"
  if ! grep -Fq '.local/npm/bin' "$profile"; then
    printf '%s\n' 'export PATH="$HOME/.local/bin:$HOME/.local/npm/bin:$HOME/.opencode/bin:$PATH"' >>"$profile"
  fi
  if ! grep -Fq '.config/ai-agents/env' "$profile"; then
    printf '%s\n' '[ -f "$HOME/.config/ai-agents/env" ] && . "$HOME/.config/ai-agents/env"' >>"$profile"
  fi
done
chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.profile" "$DEV_HOME/.bashrc"

install_node22() {
  local deb_arch node_arch base node_file tmp_dir
  deb_arch=$(dpkg --print-architecture)
  case "$deb_arch" in
    amd64) node_arch=x64 ;;
    arm64) node_arch=arm64 ;;
    *) echo "Node.js 22 automatic installation is unsupported on architecture: $deb_arch" >&2; return 1 ;;
  esac

  base=https://nodejs.org/dist/latest-v22.x
  tmp_dir=$(mktemp -d)
  curl -fsSL "$base/SHASUMS256.txt" -o "$tmp_dir/SHASUMS256.txt"
  node_file=$(awk -v arch="$node_arch" \
    '$2 ~ ("^node-v22\\.[0-9]+\\.[0-9]+-linux-" arch "\\.tar\\.xz$") {print $2}' \
    "$tmp_dir/SHASUMS256.txt" | sort -V | tail -n 1)
  [[ -n "$node_file" ]] || { echo 'Unable to determine the current Node.js 22 build.' >&2; rm -rf "$tmp_dir"; return 1; }

  curl -fsSL "$base/$node_file" -o "$tmp_dir/$node_file"
  (cd "$tmp_dir" && grep "  $node_file\$" SHASUMS256.txt | sha256sum -c -)

  rm -rf /opt/node-v22
  install -d -m 0755 /opt/node-v22
  tar -xJf "$tmp_dir/$node_file" -C /opt/node-v22 --strip-components=1
  rm -rf "$tmp_dir"

  for command in node npm npx corepack; do
    [[ -x "/opt/node-v22/bin/$command" ]] && ln -sfn "/opt/node-v22/bin/$command" "/usr/local/bin/$command"
  done
  node --version
  npm --version
}

install_claude_code() {
  local deb_arch fingerprint
  local expected_fingerprint="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"
  local key_file="/etc/apt/keyrings/claude-code.asc"
  local source_file="/etc/apt/sources.list.d/claude-code.list"

  deb_arch=$(dpkg --print-architecture)
  case "$deb_arch" in
    amd64)
      if ! grep -qw avx /proc/cpuinfo; then
        echo "ERROR: Claude Code requires AVX on x86-64, but AVX is not exposed by this Proxmox node CPU." >&2
        echo "CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | xargs || true)" >&2
        echo "There is currently no native-binary workaround for a missing AVX instruction set." >&2
        return 1
      fi
      ;;
    arm64) ;;
    *)
      echo "ERROR: Claude Code is unsupported by this helper on Debian architecture: $deb_arch" >&2
      return 1
      ;;
  esac

  echo 'Checking access to the Claude Code download service...'
  curl -fsSL --retry 3 --retry-delay 2 \
    https://downloads.claude.ai/claude-code-releases/latest \
    -o /tmp/claude-code-latest-version
  printf 'Available Claude Code release: %s\n' "$(tr -d '[:space:]' </tmp/claude-code-latest-version)"
  rm -f /tmp/claude-code-latest-version

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 --retry-delay 2 \
    https://downloads.claude.ai/keys/claude-code.asc \
    -o "$key_file"

  fingerprint=$(gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null \
    | awk -F: '$1 == "fpr" {print toupper($10); exit}')
  if [[ "$fingerprint" != "$expected_fingerprint" ]]; then
    echo "ERROR: Anthropic signing-key fingerprint verification failed." >&2
    echo "Expected: $expected_fingerprint" >&2
    echo "Received: ${fingerprint:-none}" >&2
    rm -f "$key_file"
    return 1
  fi

  printf '%s\n' \
    'deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main' \
    >"$source_file"

  apt-get update
  apt-get install -y --no-install-recommends claude-code
  run_as_dev claude --version
}

FAILED_AGENTS=()
install_agent() {
  local agent_id=$1
  local agent_name=$2
  shift 2
  local agent_log="/var/log/ai-agent-${agent_id}-install.log"
  local rc=0

  : >"$agent_log"
  echo "Installing/updating $agent_name..."
  set +e
  ( set -Eeuo pipefail; "$@" ) > >(tee -a "$agent_log") 2>&1
  rc=$?
  set -e
  if ((rc == 0)); then
    echo "$agent_name installation completed."
  else
    FAILED_AGENTS+=("$agent_id")
    echo "ERROR: $agent_name installation failed with exit code $rc." | tee -a "$agent_log" >&2
    echo "Detailed log: $agent_log" >&2
    tail -n 60 "$agent_log" >&2 || true
  fi
  return 0
}

if has_agent gemini || has_agent copilot; then
  install_node22
  run_as_dev npm config set prefix "$DEV_HOME/.local/npm"
fi

if has_agent claude; then
  install_agent claude 'Claude Code' install_claude_code
fi

if has_agent codex; then
  install_agent codex 'OpenAI Codex CLI' \
    run_as_dev_shell 'set -o pipefail; curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh'
fi

if has_agent gemini; then
  install_agent gemini 'Google Gemini CLI' \
    run_as_dev npm install -g @google/gemini-cli@latest
fi

if has_agent copilot; then
  install_agent copilot 'GitHub Copilot CLI' \
    run_as_dev env npm_config_ignore_scripts=false npm install -g @github/copilot@latest
fi

if has_agent aider; then
  install_agent aider 'Aider' \
    run_as_dev_shell 'set -o pipefail; curl -LsSf https://aider.chat/install.sh | sh'
fi

if has_agent opencode; then
  install_agent opencode 'OpenCode' \
    run_as_dev_shell 'set -o pipefail; curl -fsSL https://opencode.ai/install | bash'
fi

link_user_command() {
  local command=$1 path
  path=$(run_as_dev bash -c "command -v $command" 2>/dev/null || true)
  if [[ -n "$path" && -x "$path" && "$path" != "/usr/local/bin/$command" ]]; then
    ln -sfn "$path" "/usr/local/bin/$command"
  fi
}

for command in claude codex gemini copilot aider opencode; do
  link_user_command "$command"
done

printf 'SELECTED_AGENTS=%q\n' "$SELECTED_AGENTS" >/etc/ai-agent-selection
printf '%s\n' "$DEV_USER" >/etc/ai-development-user
chmod 0644 /etc/ai-agent-selection /etc/ai-development-user

# Stable system-level Robot Framework tool environment.
python3 -m venv /opt/robotframework
/opt/robotframework/bin/python -m pip install --upgrade pip setuptools wheel
/opt/robotframework/bin/python -m pip install --upgrade robotframework 'robotcode[all]'
for app in robot rebot libdoc robotcode; do
  if [[ -x "/opt/robotframework/bin/$app" ]]; then
    ln -sfn "/opt/robotframework/bin/$app" "/usr/local/bin/$app"
  fi
done

# Ready-to-run project-specific virtual environment and example.
PROJECT=/srv/workspace/robot-demo
install -d -m 0755 -o "$DEV_USER" -g "$DEV_USER" "$PROJECT/tests" "$PROJECT/.vscode"
cat >"$PROJECT/requirements.txt" <<'EOF'
robotframework
robotcode[all]
EOF
cat >"$PROJECT/tests/smoke.robot" <<'EOF'
*** Settings ***
Documentation    Basic verification for the headless development LXC.

*** Test Cases ***
Development Environment Is Working
    Log    Multi-agent AI development LXC is ready.
    Should Be Equal As Integers    ${{1 + 1}}    2
EOF
cat >"$PROJECT/.vscode/settings.json" <<'EOF'
{
    "python.defaultInterpreterPath": "${workspaceFolder}/.venv/bin/python",
    "python.terminal.activateEnvironment": true,
    "robotcode.robot.pythonPath": ["${workspaceFolder}"],
    "files.exclude": {
        "**/__pycache__": true,
        "**/.pytest_cache": true
    }
}
EOF
cat >"$PROJECT/.gitignore" <<'EOF'
.venv/
__pycache__/
*.py[cod]
.pytest_cache/
.mypy_cache/
.ruff_cache/
results/
output.xml
log.html
report.html
.env
EOF
cat >"$PROJECT/AGENTS.md" <<'EOF'
# AI agent development guidance

- Inspect the repository and explain the intended change before editing.
- Keep changes focused and preserve existing public behavior unless explicitly requested.
- Never print, commit, or copy credentials, tokens, private keys, or `.env` contents.
- Do not use `sudo`, change host networking, or install system packages without approval.
- Use the project `.venv` for Python dependencies.
- Run the relevant Robot Framework tests after changes.
- Review `git diff` before committing and keep generated reports out of Git.
EOF
cat >"$PROJECT/CLAUDE.md" <<'EOF'
Follow the repository instructions in AGENTS.md.
EOF
cat >"$PROJECT/GEMINI.md" <<'EOF'
Follow the repository instructions in AGENTS.md.
EOF
cat >"$PROJECT/AI_AGENTS.md" <<'EOF'
# Installed AI coding agents

Selected during provisioning: __SELECTED_AGENTS__

Useful commands:

- `ai-agent-menu` — launch agents, authenticate, edit API-key environment, or update agents
- `ai-agent-status` — show selected agents and installed versions
- `ai-agent-help` — show first-run authentication instructions
- `dev-environment-status` — show the complete development environment
- `nano ~/.config/ai-agents/env` — configure optional provider API keys

Authentication notes:

- Claude Code: launch `claude` and complete browser sign-in.
- Codex CLI: launch `codex` and choose ChatGPT sign-in or another offered method.
- Gemini CLI: launch `gemini` and complete Google OAuth or configure an API key.
- Copilot CLI: launch `copilot`, then enter `/login`.
- Aider: configure the chosen provider API key before launching `aider`.
- OpenCode: launch `opencode`, then enter `/connect`.

Run an agent from the root of the repository it should inspect. Review its proposed commands and diffs before accepting changes.
EOF
sed -i "s/__SELECTED_AGENTS__/$SELECTED_AGENTS/" "$PROJECT/AI_AGENTS.md"

if [[ ! -x "$PROJECT/.venv/bin/python" ]]; then
  python3 -m venv "$PROJECT/.venv"
fi
"$PROJECT/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
"$PROJECT/.venv/bin/python" -m pip install --upgrade -r "$PROJECT/requirements.txt"
chown -R "$DEV_USER:$DEV_USER" "$PROJECT"

if [[ -n "$GIT_NAME" ]]; then
  runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" git config --global user.name "$GIT_NAME"
fi
if [[ -n "$GIT_EMAIL" ]]; then
  runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" git config --global user.email "$GIT_EMAIL"
fi
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" git config --global init.defaultBranch main
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" git config --global pull.rebase false

# OpenVSX extension installation is best-effort because extension availability can vary.
install_extension() {
  local extension=$1
  if ! runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" USER="$DEV_USER" \
      code-server --install-extension "$extension"; then
    echo "WARNING: code-server extension not installed: $extension"
  fi
}
install_extension ms-python.python
install_extension d-biehl.robotcode
if has_agent claude; then
  install_extension anthropic.claude-code
fi
if has_agent codex; then
  install_extension openai.chatgpt
fi
if has_agent gemini; then
  install_extension Google.gemini-cli-vscode-ide-companion
fi
install_extension github.vscode-pull-request-github

cat >/usr/local/bin/ai-agent-status <<'STATUS'
#!/usr/bin/env bash
set -u
SELECTED_AGENTS=""
[[ -r /etc/ai-agent-selection ]] && source /etc/ai-agent-selection
selected() { [[ ",$SELECTED_AGENTS," == *",$1,"* ]]; }
show_agent() {
  local id=$1 name=$2 command=$3
  local mark=' '
  selected "$id" && mark='*'
  if command -v "$command" >/dev/null 2>&1; then
    local version
    version=$(timeout 12 "$command" --version 2>&1 | head -n 1 || true)
    printf '[%s] %-22s installed  %s\n' "$mark" "$name" "${version:-version unavailable}"
  else
    printf '[%s] %-22s not installed\n' "$mark" "$name"
  fi
}
printf '%s\n' 'Selected agents are marked with *.'
show_agent claude   'Claude Code'        claude
show_agent codex    'OpenAI Codex CLI'   codex
show_agent gemini   'Google Gemini CLI'  gemini
show_agent copilot  'GitHub Copilot CLI' copilot
show_agent aider    'Aider'              aider
show_agent opencode 'OpenCode'           opencode
STATUS
chmod 0755 /usr/local/bin/ai-agent-status

cat >/usr/local/bin/dev-environment-status <<'STATUS'
#!/usr/bin/env bash
set -u
printf 'Host:            %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'Addresses:       %s\n' "$(hostname -I 2>/dev/null || true)"
printf 'Python:          %s\n' "$(python3 --version 2>&1)"
printf 'Robot Framework: %s\n' "$(robot --version 2>&1 | head -n 1)"
printf 'RobotCode:       %s\n' "$(robotcode --version 2>&1 | head -n 1)"
printf 'Git:             %s\n' "$(git --version 2>&1)"
printf 'GitHub CLI:      %s\n' "$(gh --version 2>&1 | head -n 1)"
if command -v node >/dev/null 2>&1; then
  printf 'Node.js:         %s\n' "$(node --version 2>&1)"
fi
printf 'code-server:     %s\n' "$(code-server --version 2>&1 | head -n 1)"
printf 'SSH service:     %s\n' "$(systemctl is-active ssh 2>/dev/null || true)"
service_user=$(cat /etc/ai-development-user 2>/dev/null || whoami)
printf 'Web IDE service: %s\n' "$(systemctl is-active "code-server@$service_user" 2>/dev/null || true)"
printf '\nAI coding agents:\n'
ai-agent-status
STATUS
chmod 0755 /usr/local/bin/dev-environment-status

cat >/usr/local/bin/ai-agent-update <<'UPDATE'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  echo 'Run ai-agent-update as the normal development user, not root.' >&2
  exit 1
fi
SELECTED_AGENTS=""
[[ -r /etc/ai-agent-selection ]] && source /etc/ai-agent-selection
has_agent() { [[ ",$SELECTED_AGENTS," == *",$1,"* ]]; }
export PATH="$HOME/.local/bin:$HOME/.local/npm/bin:$HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin"

if has_agent claude; then
  echo 'Updating Claude Code from the Anthropic APT repository...'
  if dpkg-query -W -f='${Status}' claude-code 2>/dev/null | grep -q 'ok installed'; then
    sudo apt-get update
    sudo apt-get install -y --only-upgrade claude-code
  else
    echo 'Claude Code is not managed by APT. Run the Proxmox helper Update/repair action.' >&2
  fi
fi
if has_agent codex; then
  echo 'Updating OpenAI Codex CLI...'
  curl -fsSL https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh
fi
if has_agent gemini; then
  echo 'Updating Google Gemini CLI...'
  npm config set prefix "$HOME/.local/npm"
  npm install -g @google/gemini-cli@latest
fi
if has_agent copilot; then
  echo 'Updating GitHub Copilot CLI...'
  npm config set prefix "$HOME/.local/npm"
  npm_config_ignore_scripts=false npm install -g @github/copilot@latest
fi
if has_agent aider; then
  echo 'Updating Aider...'
  curl -LsSf https://aider.chat/install.sh | sh
fi
if has_agent opencode; then
  echo 'Updating OpenCode...'
  curl -fsSL https://opencode.ai/install | bash
fi
hash -r
echo
ai-agent-status
UPDATE
chmod 0755 /usr/local/bin/ai-agent-update

cat >/usr/local/bin/ai-agent-help <<'HELP'
#!/usr/bin/env bash
cat <<'EOF'
AI agent first-run authentication
---------------------------------
Claude Code:        Run `claude` and complete the browser sign-in flow.
OpenAI Codex CLI:   Run `codex` and select ChatGPT sign-in or another offered method.
Google Gemini CLI:  Run `gemini` and complete Google OAuth, or configure a supported API key.
GitHub Copilot CLI: Run `copilot`, enter `/login`, and use an account with Copilot access.
Aider:              Add the selected model provider key to ~/.config/ai-agents/env, then run `aider`.
OpenCode:           Run `opencode`, enter `/connect`, and select a model provider.
GitHub Git access:  Run `gh auth login --web`, then `gh auth setup-git`.

Provider environment file:
  ~/.config/ai-agents/env

Launch agents from the repository directory they should inspect. Keep credentials out of Git.
EOF
HELP
chmod 0755 /usr/local/bin/ai-agent-help

cat >/usr/local/bin/ai-agent-menu <<'MENU'
#!/usr/bin/env bash
set -u
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  echo 'Run ai-agent-menu as the normal development user, not root.' >&2
  exit 1
fi
export PATH="$HOME/.local/bin:$HOME/.local/npm/bin:$HOME/.opencode/bin:/usr/local/bin:/usr/bin:/bin"
SELECTED_AGENTS=""
[[ -r /etc/ai-agent-selection ]] && source /etc/ai-agent-selection
load_provider_env() {
  if [[ -r "$HOME/.config/ai-agents/env" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.config/ai-agents/env"
  fi
}
run_agent() {
  local command=$1
  load_provider_env
  if command -v "$command" >/dev/null 2>&1; then
    "$command"
  else
    echo "$command is not installed. Change the selection from the Proxmox helper and run Update/repair."
  fi
}
while true; do
  printf '\nSelected agents: %s\n' "${SELECTED_AGENTS:-not recorded}"
  cat <<'EOF'

AI Agent Menu
-------------
1) GitHub CLI login
2) Claude Code
3) OpenAI Codex CLI
4) Google Gemini CLI
5) GitHub Copilot CLI
6) Aider
7) OpenCode
8) Edit provider API-key environment
9) Show agent status
h) Show first-run authentication help
u) Update selected agents
q) Quit
EOF
  read -r -p 'Select: ' choice
  case "$choice" in
    1) gh auth login --hostname github.com --git-protocol https --web && gh auth setup-git ;;
    2) run_agent claude ;;
    3) run_agent codex ;;
    4) run_agent gemini ;;
    5) run_agent copilot ;;
    6) run_agent aider ;;
    7) run_agent opencode ;;
    8) "${EDITOR:-nano}" "$HOME/.config/ai-agents/env"; load_provider_env ;;
    9) ai-agent-status ;;
    h|H) ai-agent-help ;;
    u|U) ai-agent-update ;;
    q|Q) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
done
MENU
chmod 0755 /usr/local/bin/ai-agent-menu

cat >/usr/local/bin/dev-auth <<'AUTH'
#!/usr/bin/env bash
exec ai-agent-menu "$@"
AUTH
chmod 0755 /usr/local/bin/dev-auth

cat >/usr/local/sbin/disable-dev-ssh-password <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
KEY_FILE="$DEV_HOME/.ssh/authorized_keys"
if [[ ! -s "\$KEY_FILE" ]]; then
  echo "Refusing to disable password login: \$KEY_FILE is missing or empty." >&2
  exit 1
fi
sed -i 's/^PasswordAuthentication .*/PasswordAuthentication no/' \
  /etc/ssh/sshd_config.d/99-claude-development-lxc.conf
sshd -t
systemctl restart ssh
echo 'SSH password authentication is now disabled.'
EOF
chmod 0750 /usr/local/sbin/disable-dev-ssh-password

cat >/etc/motd <<EOF

Multi-Agent AI Development LXC
------------------------------
Workspace:          /srv/workspace
Example project:    /srv/workspace/robot-demo
Selected agents:    $SELECTED_AGENTS
Agent menu:         ai-agent-menu
Agent status:       ai-agent-status
Agent help:         ai-agent-help
Environment status: dev-environment-status
Provider key file:  ~/.config/ai-agents/env
Web IDE service:    systemctl status code-server@$DEV_USER

EOF

# Smoke test the installed Robot Framework environment.
cd "$PROJECT"
"$PROJECT/.venv/bin/python" -m robot --outputdir results tests
chown -R "$DEV_USER:$DEV_USER" "$PROJECT/results"

rm -f /root/claude-dev.env
if ((${#FAILED_AGENTS[@]} > 0)); then
  printf '%s\n' "${FAILED_AGENTS[@]}" >/var/log/ai-agent-install-failures
  chmod 0644 /var/log/ai-agent-install-failures
  printf '[%s] Provisioning completed with AI-agent failures: %s\n' \
    "$(date '+%F %T')" "${FAILED_AGENTS[*]}"
  exit 20
fi
rm -f /var/log/ai-agent-install-failures
printf '[%s] Provisioning completed\n' "$(date '+%F %T')"
PROVISION
  chmod 0700 "$provision_file"

  pct push "$CTID" "$env_file" /root/claude-dev.env --perms 0600 >>"$LOG_FILE" 2>&1
  pct push "$CTID" "$provision_file" /root/claude-dev-provision.sh --perms 0700 >>"$LOG_FILE" 2>&1
  rm -rf "$tmp_dir"
}

provision_container() {
  local rc=0
  PROVISION_WARNING=""
  write_provision_files
  msg_info "Installing the headless development toolchain inside LXC $CTID…

This includes package upgrades, code-server, selected AI coding agents, Python, Robot Framework, GitHub CLI, helper commands, and a smoke test."

  set +e
  pct exec "$CTID" -- /root/claude-dev-provision.sh >>"$LOG_FILE" 2>&1
  rc=$?
  set -e

  if ((rc == 20)); then
    PROVISION_WARNING=$(pct exec "$CTID" -- bash -lc       'printf "The environment is operational, but these selected AI agents failed to install: "; paste -sd", " /var/log/ai-agent-install-failures 2>/dev/null || true'       2>/dev/null || true)
    pct exec "$CTID" -- bash -lc 'tail -n 120 /var/log/claude-dev-provision.log' >>"$LOG_FILE" 2>&1 || true
  elif ((rc != 0)); then
    pct exec "$CTID" -- bash -lc 'tail -n 120 /var/log/claude-dev-provision.log' >>"$LOG_FILE" 2>&1 || true
    show_error_details "Provisioning failed inside LXC $CTID. The container was left intact for diagnosis."
    return 1
  fi

  pct exec "$CTID" -- rm -f /root/claude-dev-provision.sh /root/claude-dev.env >/dev/null 2>&1 || true
  pct set "$CTID" --protection 1 >>"$LOG_FILE" 2>&1
}

get_ct_ipv4() {
  local output
  output=$(pct exec "$CTID" -- bash -lc "hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$'" 2>/dev/null || true)
  printf '%s' "$output"
}

wait_for_ct_ipv4() {
  local ip=""
  local count=0
  while ((count < 30)); do
    ip=$(get_ct_ipv4)
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
    sleep 2
    ((count += 1))
  done
  return 1
}

write_state_file() {
  local state_file="$STATE_DIR/$CTID.conf"
  {
    printf 'CTID=%q\n' "$CTID"
    printf 'CT_HOSTNAME=%q\n' "$CT_HOSTNAME"
    printf 'DEV_USER=%q\n' "$DEV_USER"
    printf 'ACCESS_MODE=%q\n' "$ACCESS_MODE"
    printf 'CODE_SERVER_PORT=%q\n' "$CODE_SERVER_PORT"
    printf 'CODE_SERVER_PASSWORD=%q\n' "$CODE_SERVER_PASSWORD"
    printf 'PASSWORD_AUTH=%q\n' "$PASSWORD_AUTH"
    printf 'ROOTFS_STORAGE=%q\n' "$ROOTFS_STORAGE"
    printf 'TEMPLATE_STORAGE=%q\n' "$TEMPLATE_STORAGE"
    printf 'BRIDGE=%q\n' "$BRIDGE"
    printf 'SELECTED_AGENTS=%q\n' "$SELECTED_AGENTS"
    printf 'CREATED_AT=%q\n' "$(date --iso-8601=seconds)"
  } >"$state_file"
  chmod 0600 "$state_file"
}

write_credentials_file() {
  local ip=$1
  local credentials_file="/root/ai-dev-lxc-${CTID}-access.txt"
  {
    echo "Multi-Agent AI Development LXC"
    echo "======================"
    echo "Container ID: $CTID"
    echo "Hostname:     $CT_HOSTNAME"
    echo "Address:      ${ip:-not detected}"
    echo "User:         $DEV_USER"
    echo "AI agents:    $(selected_agents_display)"
    [[ -n "$DEV_PASSWORD" ]] && echo "Initial SSH password: $DEV_PASSWORD"
    echo
    if [[ "$ACCESS_MODE" == "tunnel" ]]; then
      echo "SSH tunnel:"
      echo "  ssh -N -L ${CODE_SERVER_PORT}:127.0.0.1:${CODE_SERVER_PORT} ${DEV_USER}@${ip:-CONTAINER_IP}"
      echo "Web IDE: http://127.0.0.1:${CODE_SERVER_PORT}"
    else
      echo "Web IDE: http://${ip:-CONTAINER_IP}:${CODE_SERVER_PORT}"
      echo "Web IDE password: $CODE_SERVER_PASSWORD"
    fi
    echo
    echo "First-login setup:"
    echo "  ssh ${DEV_USER}@${ip:-CONTAINER_IP}"
    echo "  ai-agent-menu"
    echo "  ai-agent-help"
    echo
    echo "After adding and testing an SSH public key:"
    echo "  sudo disable-dev-ssh-password"
    echo
    echo "Delete this credentials file after saving the required secrets securely."
  } >"$credentials_file"
  chmod 0600 "$credentials_file"
  printf '%s' "$credentials_file"
}

show_completion() {
  local ip=$1
  local credentials_file=$2
  local access_text

  if [[ "$ACCESS_MODE" == "tunnel" ]]; then
    access_text="On your PC, run:

ssh -N -L ${CODE_SERVER_PORT}:127.0.0.1:${CODE_SERVER_PORT} ${DEV_USER}@${ip:-CONTAINER_IP}

Then open:
http://127.0.0.1:${CODE_SERVER_PORT}"
  else
    access_text="Open from your LAN:

http://${ip:-CONTAINER_IP}:${CODE_SERVER_PORT}

code-server password:
$CODE_SERVER_PASSWORD"
  fi

  whiptail --backtitle "$BACKTITLE" --title "DEPLOYMENT COMPLETE" --scrolltext --msgbox \
    "LXC $CTID ($CT_HOSTNAME) is ready.

Detected address: ${ip:-not detected}
Development user: $DEV_USER
Selected AI agents: $(selected_agents_display)
${DEV_PASSWORD:+Initial SSH password: $DEV_PASSWORD
}
$access_text

After SSH login, run:
  ai-agent-menu

Use the menu to authenticate GitHub, launch each selected agent, configure optional provider API keys, and update agents. Run ai-agent-help for agent-specific first-login instructions.

Robot Framework example:
  cd /srv/workspace/robot-demo
  source .venv/bin/activate
  robot --outputdir results tests

Access details were saved on the Proxmox host:
$credentials_file

${PROVISION_WARNING:+WARNING:
$PROVISION_WARNING
Review /var/log/ai-agent-<name>-install.log inside the LXC, then use Update/repair.

}Installation log:
$LOG_FILE" 35 90
}

new_installation() {
  local mode
  local ip=""
  local credentials_file

  load_defaults
  mode=$(menu_box "INSTALLATION MODE" \
    "Choose a configuration mode." \
    "default" "Recommended infrastructure defaults plus AI-agent selection" \
    "advanced" "Configure infrastructure, access, Git identity, and AI agents" \
    "cancel" "Return to the main menu") || return 0

  case "$mode" in
    default) configure_default_mode || return 0 ;;
    advanced) configure_advanced_mode || return 0 ;;
    *) return 0 ;;
  esac

  if pct status "$CTID" >/dev/null 2>&1; then
    msg_warn "Container ID $CTID already exists."
    return 0
  fi

  configuration_summary || return 0

  if ! create_container; then
    if pct status "$CTID" >/dev/null 2>&1; then
      if ask_yes_no "CLEANUP" "The deployment did not complete. Destroy incomplete LXC $CTID?" no; then
        pct set "$CTID" --protection 0 >/dev/null 2>&1 || true
        pct stop "$CTID" --skiplock 1 >/dev/null 2>&1 || true
        pct destroy "$CTID" --purge 1 >>"$LOG_FILE" 2>&1 || true
      fi
    fi
    return 0
  fi

  # Register the container before provisioning so a partial deployment remains repairable.
  write_state_file

  if ! provision_container; then
    msg_warn "LXC $CTID exists but provisioning is incomplete. It remains registered and can be repaired from the main menu after reviewing the log."
    return 0
  fi

  write_state_file
  ip=$(wait_for_ct_ipv4 || true)
  credentials_file=$(write_credentials_file "$ip")
  show_completion "$ip" "$credentials_file"
}

# ---------- Managed-container actions ----------

list_managed_ctids() {
  local file
  shopt -s nullglob
  for file in "$STATE_DIR"/*.conf; do
    basename "$file" .conf
  done
  shopt -u nullglob
}

select_managed_ctid() {
  local prompt=$1
  local entries=()
  local id
  mapfile -t ids < <(list_managed_ctids)
  for id in "${ids[@]}"; do
    if pct status "$id" >/dev/null 2>&1; then
      entries+=("$id" "$(pct config "$id" 2>/dev/null | awk -F': ' '$1 == "hostname" {print $2}')")
    fi
  done

  if ((${#entries[@]} == 0)); then
    msg_warn "No containers managed by this script were found in $STATE_DIR."
    return 1
  fi

  whiptail --backtitle "$BACKTITLE" --title "SELECT CONTAINER" \
    --menu "$prompt" 18 76 9 "${entries[@]}" 3>&1 1>&2 2>&3
}

load_state() {
  local id=$1
  local state_file="$STATE_DIR/$id.conf"
  [[ -f "$state_file" ]] || return 1
  # State files are root-owned, mode 0600, and generated by this script.
  SELECTED_AGENTS="claude"
  # shellcheck disable=SC1090
  source "$state_file"
  CONFIGURE_SSH="0"
  DEV_PASSWORD=""
  SSH_KEY_CONTENT=""
  GIT_NAME=""
  GIT_EMAIL=""
}

update_managed_container() {
  local id
  id=$(select_managed_ctid "Select a container to update or repair.") || return 0
  load_state "$id"
  CTID=$id

  if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
    msg_info "Starting LXC $CTID…"
    pct start "$CTID" >>"$LOG_FILE" 2>&1
    sleep 3
  fi

  if ask_yes_no "AI AGENT SELECTION" \
    "Current selection:
$(selected_agents_display)

Change which AI coding agents are installed or updated? Existing agents are not automatically removed when deselected." no; then
    choose_ai_agents || return 0
  fi

  if ! ask_yes_no "UPDATE / REPAIR" \
    "Re-run the idempotent provisioning process in LXC $CTID?

This updates Debian packages, code-server, Python tooling, Robot Framework,
RobotCode, selected AI agents, helper commands, extensions, and the starter workspace.
Existing projects under /srv/workspace are preserved.

Selected agents: $(selected_agents_display)" yes; then
    return 0
  fi

  if ! provision_container; then
    msg_warn "LXC $CTID is still incomplete. Review the provisioning log and retry Update/repair.

Log: $LOG_FILE"
    return 0
  fi
  write_state_file
  if [[ -n "$PROVISION_WARNING" ]]; then
    msg_warn "LXC $CTID was updated, but one or more selected AI agents failed.

$PROVISION_WARNING

Detailed logs are under /var/log/ai-agent-*-install.log inside the LXC."
  else
    msg_ok "LXC $CTID was updated successfully.

Log: $LOG_FILE"
  fi
}

adopt_existing_container() {
  local detected_config=""
  local bind_addr=""
  local detected_agents=""
  local ip=""
  local credentials_file=""

  CTID=$(input_box "ADOPT EXISTING LXC" \
    "Enter the numeric ID of an existing AI Development LXC.

This is intended for containers left intact after an earlier provisioning failure." \
    "${CTID:-}") || return 0
  [[ "$CTID" =~ ^[1-9][0-9]{1,8}$ ]] || { msg_warn "Invalid container ID: $CTID"; return 0; }
  pct status "$CTID" >/dev/null 2>&1 || { msg_warn "LXC $CTID does not exist on this Proxmox node."; return 0; }

  if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
    msg_info "Starting LXC $CTID…"
    pct start "$CTID" >>"$LOG_FILE" 2>&1
    sleep 3
  fi

  CT_HOSTNAME=$(pct config "$CTID" 2>/dev/null | awk -F': ' '$1 == "hostname" {print $2; exit}')
  CT_HOSTNAME=${CT_HOSTNAME:-ai-dev}
  ROOTFS_STORAGE=$(pct config "$CTID" 2>/dev/null | awk -F': ' '$1 == "rootfs" {split($2,a,":"); print a[1]; exit}')
  BRIDGE=$(pct config "$CTID" 2>/dev/null | sed -n 's/^net0:.*bridge=\([^,]*\).*/\1/p' | head -n1)

  detected_config=$(pct exec "$CTID" -- bash -lc \
    "find /home -path '*/.config/code-server/config.yaml' -type f -print -quit" 2>/dev/null || true)
  if [[ -n "$detected_config" ]]; then
    DEV_USER=$(cut -d/ -f3 <<<"$detected_config")
    bind_addr=$(pct exec "$CTID" -- awk -F': ' '$1 == "bind-addr" {print $2; exit}' "$detected_config" 2>/dev/null || true)
    CODE_SERVER_PORT=${bind_addr##*:}
    [[ "$CODE_SERVER_PORT" =~ ^[0-9]+$ ]] || CODE_SERVER_PORT="$DEFAULT_PORT"
    if [[ "$bind_addr" == 127.0.0.1:* || "$bind_addr" == localhost:* ]]; then
      ACCESS_MODE="tunnel"
      CODE_SERVER_PASSWORD=""
    else
      ACCESS_MODE="lan"
      CODE_SERVER_PASSWORD=$(pct exec "$CTID" -- sed -n 's/^password:[[:space:]]*//p' "$detected_config" 2>/dev/null | head -n1 || true)
    fi
  else
    DEV_USER=$(input_box "DEVELOPMENT USER" \
      "code-server configuration was not detected. Enter the development username." "$DEFAULT_USER") || return 0
    ACCESS_MODE="tunnel"
    CODE_SERVER_PORT="$DEFAULT_PORT"
    CODE_SERVER_PASSWORD=""
  fi

  detected_agents=$(pct exec "$CTID" -- bash -lc \
    'if [[ -r /etc/ai-agent-selection ]]; then source /etc/ai-agent-selection; printf "%s" "${SELECTED_AGENTS:-}"; fi' \
    2>/dev/null || true)
  SELECTED_AGENTS=${detected_agents:-claude}

  if ask_yes_no "AI AGENT SELECTION" \
    "Detected selection: $(selected_agents_display)

Change the agents to install or repair?" no; then
    choose_ai_agents || return 0
  fi

  CONFIGURE_SSH="0"
  DEV_PASSWORD=""
  SSH_KEY_CONTENT=""
  GIT_NAME=""
  GIT_EMAIL=""
  PASSWORD_AUTH="yes"

  if ! ask_yes_no "ADOPT AND REPAIR" \
    "Adopt LXC $CTID as a managed AI Development LXC and run idempotent repair?

Hostname: $CT_HOSTNAME
User: $DEV_USER
Web IDE: $ACCESS_MODE on port $CODE_SERVER_PORT
Agents: $(selected_agents_display)

Existing projects under /srv/workspace are preserved." yes; then
    return 0
  fi

  write_state_file
  if ! provision_container; then
    msg_warn "LXC $CTID was registered, but repair is still incomplete. Review the log and retry Update/repair.

Log: $LOG_FILE"
    return 0
  fi
  write_state_file
  ip=$(wait_for_ct_ipv4 || true)
  credentials_file=$(write_credentials_file "$ip")
  if [[ -n "$PROVISION_WARNING" ]]; then
    msg_warn "LXC $CTID was adopted and the base development environment is operational.

$PROVISION_WARNING

Use Update/repair after resolving the indicated agent issue."
  else
    show_completion "$ip" "$credentials_file"
  fi
}

show_managed_info() {
  local id
  local ip
  local status
  local access
  id=$(select_managed_ctid "Select a container to inspect.") || return 0
  load_state "$id"
  CTID=$id
  status=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
  ip=$(get_ct_ipv4)

  if [[ "$ACCESS_MODE" == "tunnel" ]]; then
    access="ssh -N -L ${CODE_SERVER_PORT}:127.0.0.1:${CODE_SERVER_PORT} ${DEV_USER}@${ip:-CONTAINER_IP}
Then open http://127.0.0.1:${CODE_SERVER_PORT}"
  else
    access="http://${ip:-CONTAINER_IP}:${CODE_SERVER_PORT}
Password: $CODE_SERVER_PASSWORD"
  fi

  whiptail --backtitle "$BACKTITLE" --title "CONTAINER INFORMATION" --scrolltext --msgbox \
    "Container ID: $CTID
Hostname:     $CT_HOSTNAME
Status:       $status
Address:      ${ip:-not detected}
User:         $DEV_USER
AI agents:    $(selected_agents_display)

Web IDE access:
$access

Useful host commands:
pct enter $CTID
pct exec $CTID -- systemctl status code-server@$DEV_USER
pct exec $CTID -- tail -n 100 /var/log/claude-dev-provision.log

State file:
$STATE_DIR/$CTID.conf" 25 88
}

open_container_shell() {
  local id
  id=$(select_managed_ctid "Select a container to open in the Proxmox console.") || return 0
  if [[ "$(pct status "$id" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
    pct start "$id" >>"$LOG_FILE" 2>&1
    sleep 2
  fi
  clear 2>/dev/null || true
  printf 'Entering LXC %s as root. Use "su - %s" for the development account.\n\n' "$id" \
    "$(awk -F= '$1 == "DEV_USER" {gsub(/\047/, "", $2); print $2}' "$STATE_DIR/$id.conf" 2>/dev/null || echo dev)"
  pct enter "$id"
}

main_menu() {
  local choice
  while true; do
    choice=$(menu_box "AI DEVELOPMENT LXC v$SCRIPT_VERSION" \
      "Run this helper on the Proxmox VE host. Choose an action." \
      "1" "Create a new headless development LXC" \
      "2" "Update or repair a managed development LXC" \
      "3" "Adopt and repair an incomplete existing LXC" \
      "4" "Show access and status information" \
      "5" "Open a managed container console" \
      "6" "Show this run's log file" \
      "7" "Exit") || break

    case "$choice" in
      1) new_installation ;;
      2) update_managed_container ;;
      3) adopt_existing_container ;;
      4) show_managed_info ;;
      5) open_container_shell ;;
      6)
        whiptail --backtitle "$BACKTITLE" --title "RUN LOG" --scrolltext --textbox "$LOG_FILE" 30 100
        ;;
      7) break ;;
    esac
  done
}

main() {
  require_root
  ensure_whiptail
  init_logging
  check_proxmox_host
  log "$SCRIPT_NAME v$SCRIPT_VERSION started"

  whiptail --backtitle "$BACKTITLE" --title "WELCOME" --msgbox \
    "This standalone helper creates an unprivileged, headless Debian LXC for software development with:

• Selectable AI coding agents: Claude, Codex, Gemini, Copilot, Aider, OpenCode
• Browser-based code-server IDE
• Python and virtual environments
• Robot Framework and RobotCode
• Git and GitHub CLI
• SSH access, agent-management helpers, and build tools

The script runs on the Proxmox host and provisions the LXC automatically." 22 82

  main_menu
  clear 2>/dev/null || true
  printf '%s finished. Log: %s\n' "$SCRIPT_NAME" "$LOG_FILE"
}

main "$@"
