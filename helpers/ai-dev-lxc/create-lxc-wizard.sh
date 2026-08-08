#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Interactive Proxmox VE LXC installer for a headless multi-agent AI development environment.
# Installs: Debian LXC, code-server, selectable AI coding agents, Python,
# Robot Framework, RobotCode, Git, GitHub CLI, SSH, and a starter workspace.
#
# Run this script as root on the Proxmox VE host.
#
# Standalone from-scratch LXC creation wizard; self-contained and does not
# source lib/*.sh. This is a separate tool from install.sh, which extends an
# LXC that already exists. Not wired into manifest.env, the smoke tests, or
# the standalone launchers (ai-dev-lxc.sh etc.) — run it directly.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.2.14"
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
readonly DEFAULT_FILE_MANAGER_PORT="8081"
readonly DEFAULT_TERMIX_PORT="8082"

LOG_FILE=""
LAST_ERROR=""
PROVISION_WARNING=""
PROVISION_RUN_ID=""

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
ACCESS_MODE="lan"
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
FILE_MANAGER_ENABLED="1"
FILE_MANAGER_PORT="$DEFAULT_FILE_MANAGER_PORT"
FILE_MANAGER_PASSWORD=""
TERMIX_ENABLED="1"
TERMIX_PORT="$DEFAULT_TERMIX_PORT"
TERMIX_IMAGE="ghcr.io/lukegus/termix:latest"

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

format_elapsed() {
  local total=${1:-0}
  local hours minutes seconds
  ((total < 0)) && total=0
  hours=$((total / 3600))
  minutes=$(((total % 3600) / 60))
  seconds=$((total % 60))
  printf '%02d:%02d:%02d' "$hours" "$minutes" "$seconds"
}

read_provision_status() {
  pct exec "$CTID" -- bash -lc \
    'cat /run/ai-dev-provision.status 2>/dev/null || true' \
    2>/dev/null | tail -n 1
}

provision_remote_log_path() {
  printf '/var/log/ai-dev-provision/run-%s.log' "$PROVISION_RUN_ID"
}

read_provision_log_mtime() {
  local remote_log output
  remote_log=$(provision_remote_log_path)
  output=$(pct exec "$CTID" -- stat -Lc %Y -- "$remote_log" 2>/dev/null || true)
  if [[ "$output" =~ ^[0-9]+$ ]]; then
    printf '%s' "$output"
  else
    printf '0'
  fi
}

read_provision_last_line() {
  local remote_log
  remote_log=$(provision_remote_log_path)
  pct exec "$CTID" -- tail -n 1 -- "$remote_log" 2>/dev/null || true
}

prepare_remote_provision_log() {
  local remote_log
  remote_log=$(provision_remote_log_path)

  # Create the exact run log before the progress reader starts. This prevents a
  # race where tail/stat are invoked before the embedded provisioner has made
  # the log and also avoids shell-string quoting of the path entirely.
  pct exec "$CTID" -- install -d -m 0750 /var/log/ai-dev-provision >/dev/null 2>&1 || return 1
  pct exec "$CTID" -- touch -- "$remote_log" >/dev/null 2>&1 || return 1
  pct exec "$CTID" -- chmod 0640 -- "$remote_log" >/dev/null 2>&1 || return 1
  pct exec "$CTID" -- ln -sfn -- "$remote_log" /var/log/claude-dev-provision.log >/dev/null 2>&1 || return 1
  pct exec "$CTID" -- bash -c 'printf "%s\n" "$1" > /run/ai-dev-provision.log-path' _ "$remote_log" >/dev/null 2>&1 || return 1
}

run_provision_with_progress() {
  local provision_pid rc gauge_rc=0
  local started now elapsed status progress stage_epoch description
  local log_mtime idle_seconds last_line idle_note

  pct exec "$CTID" -- rm -f /run/ai-dev-provision.status >/dev/null 2>&1 || true
  if ! prepare_remote_provision_log; then
    log "Unable to create the current provisioning log inside LXC $CTID."
    return 1
  fi

  # Run provisioning asynchronously so the TUI can remain responsive and show
  # the current stage instead of leaving a static or blank screen.
  timeout --foreground --signal=TERM --kill-after=30s 90m \
    pct exec "$CTID" -- /root/claude-dev-provision.sh >>"$LOG_FILE" 2>&1 &
  provision_pid=$!
  started=$(date +%s)

  set +e
  {
    while kill -0 "$provision_pid" 2>/dev/null; do
      now=$(date +%s)
      elapsed=$((now - started))
      status=$(read_provision_status || true)
      progress=1
      stage_epoch=0
      description="Waiting for the LXC provisioner to publish its first stage…"

      if [[ "$status" == *"|"* ]]; then
        IFS='|' read -r progress stage_epoch description <<<"$status"
      fi
      [[ "$progress" =~ ^[0-9]+$ ]] || progress=1
      ((progress < 1)) && progress=1
      ((progress > 99)) && progress=99
      [[ "$stage_epoch" =~ ^[0-9]+$ ]] || stage_epoch=0

      log_mtime=$(read_provision_log_mtime || true)
      [[ "$log_mtime" =~ ^[0-9]+$ ]] || log_mtime=0
      idle_seconds=0
      if ((log_mtime > 0 && now >= log_mtime)); then
        idle_seconds=$((now - log_mtime))
      fi

      idle_note=""
      if ((idle_seconds >= 180)); then
        idle_note="WARNING: no new log output for $(format_elapsed "$idle_seconds"). The current network or package command may be stalled."
      fi

      last_line=$(read_provision_last_line 2>/dev/null || true)
      last_line=$(printf '%s' "$last_line" | tr '\r\n' '  ' | sed 's/[^[:print:]\t]//g' | cut -c1-110)
      [[ -n "$last_line" ]] || last_line="The run log exists; waiting for the first provisioning message."

      printf 'XXX\n%s\n' "$progress"
      printf '%s\n\nElapsed: %s\n%s\nLast activity: %s\n\nDetailed host log: %s\nInside LXC current run: %s\n' \
        "$description" "$(format_elapsed "$elapsed")" "$idle_note" "$last_line" "$LOG_FILE" "$(provision_remote_log_path)"
      printf 'XXX\n'
      sleep 2
    done

    printf 'XXX\n100\nProvisioning process finished. Collecting results and running host-side HTTP checks…\nXXX\n'
  } | whiptail --backtitle "$BACKTITLE" --title "PROVISIONING LXC $CTID" \
      --gauge "Starting…" 16 96 1
  gauge_rc=$?

  wait "$provision_pid"
  rc=$?
  set -e

  if ((gauge_rc != 0)); then
    log "Provisioning progress display exited with status $gauge_rc; provisioning result was $rc."
  fi
  if ((rc == 124)); then
    log "Provisioning exceeded the 90-minute watchdog limit."
    return 124
  fi
  return "$rc"
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
  local candidate

  candidate=$(pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9')
  if [[ ! "$candidate" =~ ^[0-9]+$ ]] || (( candidate < 100 )); then
    candidate=100
  fi

  # Protect the create path from stale cluster-nextid results and races with
  # another administrator creating a guest while this wizard is open.
  while pct status "$candidate" >/dev/null 2>&1; do
    ((candidate += 1))
  done

  printf '%s\n' "$candidate"
}

refresh_new_ctid() {
  local previous=${CTID:-}
  local selected

  selected=$(next_ctid)
  if [[ ! "$selected" =~ ^[0-9]+$ ]] || (( selected < 100 )); then
    show_error_details "Proxmox did not return a valid unused container ID."
    return 1
  fi

  CTID=$selected
  if [[ -n "$previous" && "$previous" != "$CTID" ]]; then
    log "Container ID $previous became unavailable; automatically selected free CTID $CTID."
  else
    log "Automatically selected free CTID $CTID."
  fi
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
  timeout --foreground 10m pveam update >>"$LOG_FILE" 2>&1

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
  timeout --foreground 30m pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE" >>"$LOG_FILE" 2>&1
}

# ---------- Configuration wizard ----------

load_defaults() {
  refresh_new_ctid || return 1
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
  ACCESS_MODE="lan"
  CODE_SERVER_PORT="$DEFAULT_PORT"
  CODE_SERVER_PASSWORD=""
  SSH_KEY_FILE=""
  SSH_KEY_CONTENT=""
  GIT_NAME=""
  GIT_EMAIL=""
  CONFIGURE_SSH="1"
  SELECTED_AGENTS="claude"
  FILE_MANAGER_ENABLED="1"
  FILE_MANAGER_PORT="$DEFAULT_FILE_MANAGER_PORT"
  FILE_MANAGER_PASSWORD=""
  TERMIX_ENABLED="1"
  TERMIX_PORT="$DEFAULT_TERMIX_PORT"
  TERMIX_IMAGE="ghcr.io/lukegus/termix:latest"

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
  ACCESS_MODE="lan"
  CODE_SERVER_PASSWORD=$(openssl rand -hex 16)
  FILE_MANAGER_ENABLED="1"
  FILE_MANAGER_PORT="$DEFAULT_FILE_MANAGER_PORT"
  FILE_MANAGER_PASSWORD=$(openssl rand -hex 16)
  TERMIX_ENABLED="1"
  TERMIX_PORT="$DEFAULT_TERMIX_PORT"

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

  # The create workflow always allocates a new CTID automatically. Advanced
  # mode configures resources and networking, but never asks for an existing ID.
  refresh_new_ctid || return 1

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
    "Choose how code-server will be exposed. Direct LAN access is the default for private networks." \
    "lan" "Direct LXC IP access with password authentication" \
    "tunnel" "Loopback only; connect through an SSH tunnel") || return 1
  ACCESS_MODE=$choice
  prompt_integer CODE_SERVER_PORT "WEB IDE PORT" "code-server TCP port:" "$CODE_SERVER_PORT" 1024 65535 || return 1
  if [[ "$ACCESS_MODE" == "lan" ]]; then
    CODE_SERVER_PASSWORD=$(openssl rand -hex 16)
  fi

  if ask_yes_no "WEB FILE MANAGER"     "Install FileBrowser Quantum for browser-based access to /srv/workspace?

It runs as '$DEV_USER', requires a password, and is intended for a trusted private LAN." yes; then
    FILE_MANAGER_ENABLED="1"
    prompt_integer FILE_MANAGER_PORT "FILE MANAGER PORT"       "FileBrowser Quantum TCP port:" "$FILE_MANAGER_PORT" 1024 65535 || return 1
    if [[ "$FILE_MANAGER_PORT" == "$CODE_SERVER_PORT" ]]; then
      msg_warn "The web file manager and code-server cannot use the same TCP port."
      return 1
    fi
    FILE_MANAGER_PASSWORD=$(openssl rand -hex 16)
  else
    FILE_MANAGER_ENABLED="0"
    FILE_MANAGER_PASSWORD=""
  fi

  if ask_yes_no "TERMIX WEB TERMINAL"     "Install Termix for browser-based SSH terminals, tabs, tunnels, host management, and remote files?

Termix runs in Docker inside this unprivileged LXC, requires nesting/keyctl features, and is intended for a trusted private LAN." yes; then
    TERMIX_ENABLED="1"
    prompt_integer TERMIX_PORT "TERMIX PORT" "Termix TCP port:" "$TERMIX_PORT" 1024 65535 || return 1
    if [[ "$TERMIX_PORT" == "$CODE_SERVER_PORT" || ( "$FILE_MANAGER_ENABLED" == "1" && "$TERMIX_PORT" == "$FILE_MANAGER_PORT" ) ]]; then
      msg_warn "Termix must use a different TCP port from code-server and FileBrowser Quantum."
      return 1
    fi
  else
    TERMIX_ENABLED="0"
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
  local file_manager_summary
  local termix_summary

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
  if [[ "$FILE_MANAGER_ENABLED" == "1" ]]; then
    file_manager_summary="LAN → 0.0.0.0:$FILE_MANAGER_PORT with admin password; root /srv/workspace"
  else
    file_manager_summary="disabled"
  fi
  if [[ "$TERMIX_ENABLED" == "1" ]]; then
    termix_summary="LAN → 0.0.0.0:$TERMIX_PORT; first-run admin setup; Docker-backed"
  else
    termix_summary="disabled"
  fi

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
Web file manager:   $file_manager_summary
Termix web terminal: $termix_summary
Start at boot:      enabled
Protection:         enabled after successful setup

AI agents:           $agents_summary

Software:
code-server, FileBrowser Quantum, Termix, Python, Robot Framework, RobotCode, Git, GitHub CLI,
SSH, build tools, selected AI agents, and a starter workspace.

Create new LXC $CTID now?" 30 88
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
    local previous_ctid=$CTID
    refresh_new_ctid || return 1
    msg_info "CTID $previous_ctid was allocated while the wizard was open. Using the next free CTID: $CTID."
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
  [[ "$TERMIX_ENABLED" == "1" ]] && args+=(--features "nesting=1,keyctl=1")

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
FILE_MANAGER_ENABLED_B64='$(b64 "$FILE_MANAGER_ENABLED")'
FILE_MANAGER_PORT_B64='$(b64 "$FILE_MANAGER_PORT")'
FILE_MANAGER_PASSWORD_B64='$(b64 "$FILE_MANAGER_PASSWORD")'
TERMIX_ENABLED_B64='$(b64 "$TERMIX_ENABLED")'
TERMIX_PORT_B64='$(b64 "$TERMIX_PORT")'
TERMIX_IMAGE_B64='$(b64 "$TERMIX_IMAGE")'
PROVISION_RUN_ID_B64='$(b64 "$PROVISION_RUN_ID")'
ENV
  chmod 0600 "$env_file"

  cat >"$provision_file" <<'PROVISION'
#!/usr/bin/env bash
set -Eeuo pipefail

source /root/claude-dev.env

decode() { printf '%s' "$1" | base64 -d; }
PROVISION_RUN_ID=$(decode "$PROVISION_RUN_ID_B64")
if [[ ! "$PROVISION_RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  printf 'Invalid provisioning run identifier\n' >&2
  exit 1
fi

PROVISION_LOG_DIR=/var/log/ai-dev-provision
LOG_FILE="$PROVISION_LOG_DIR/run-$PROVISION_RUN_ID.log"
CURRENT_LOG=/var/log/claude-dev-provision.log
STATUS_FILE=/run/ai-dev-provision.status
LOG_PATH_FILE=/run/ai-dev-provision.log-path
PROVISION_STARTED_AT=$(date --iso-8601=seconds)

install -d -m 0750 "$PROVISION_LOG_DIR"
: >"$LOG_FILE"
chmod 0640 "$LOG_FILE"
ln -sfn "$LOG_FILE" "$CURRENT_LOG"
printf '%s\n' "$LOG_FILE" >"$LOG_PATH_FILE"
# Retain recent run logs while preventing unbounded growth on repeated repairs.
find "$PROVISION_LOG_DIR" -maxdepth 1 -type f -name 'run-*.log' -printf '%T@ %p\n' 2>/dev/null \
  | sort -nr | awk 'NR > 12 {sub(/^[^ ]+ /, ""); print}' \
  | xargs -r rm -f --

exec >>"$LOG_FILE" 2>&1

stage() {
  local percent=$1
  shift
  local description=$*
  printf '%s|%s|%s\n' "$percent" "$(date +%s)" "$description" >"$STATUS_FILE"
  printf '[%s] STAGE %s%%: %s\n' "$(date '+%F %T')" "$percent" "$description"
}

printf '[%s] Provisioning run %s started\n' "$(date '+%F %T')" "$PROVISION_RUN_ID"
stage 1 "Starting provisioner and reading configuration"

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
FILE_MANAGER_ENABLED=$(decode "$FILE_MANAGER_ENABLED_B64")
FILE_MANAGER_PORT=$(decode "$FILE_MANAGER_PORT_B64")
FILE_MANAGER_PASSWORD=$(decode "$FILE_MANAGER_PASSWORD_B64")
TERMIX_ENABLED=$(decode "$TERMIX_ENABLED_B64")
TERMIX_PORT=$(decode "$TERMIX_PORT_B64")
TERMIX_IMAGE=$(decode "$TERMIX_IMAGE_B64")
DEV_HOME="/home/$DEV_USER"

if [[ ! "$DEV_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; then
  echo "Invalid development username" >&2
  exit 1
fi
if [[ ! "$CODE_SERVER_PORT" =~ ^[0-9]+$ ]]; then
  echo "Invalid code-server port" >&2
  exit 1
fi
if [[ "$FILE_MANAGER_ENABLED" == "1" ]]; then
  if [[ ! "$FILE_MANAGER_PORT" =~ ^[0-9]+$ ]]; then
    echo "Invalid FileBrowser Quantum port" >&2
    exit 1
  fi
  if [[ "$FILE_MANAGER_PORT" == "$CODE_SERVER_PORT" ]]; then
    echo "FileBrowser Quantum and code-server ports must differ" >&2
    exit 1
  fi
  if [[ -z "$FILE_MANAGER_PASSWORD" ]]; then
    echo "FileBrowser Quantum requires an admin password" >&2
    exit 1
  fi
fi
if [[ "$TERMIX_ENABLED" == "1" ]]; then
  if [[ ! "$TERMIX_PORT" =~ ^[0-9]+$ ]]; then
    echo "Invalid Termix port" >&2
    exit 1
  fi
  if [[ "$TERMIX_PORT" == "$CODE_SERVER_PORT" || ( "$FILE_MANAGER_ENABLED" == "1" && "$TERMIX_PORT" == "$FILE_MANAGER_PORT" ) ]]; then
    echo "Termix port conflicts with another web service" >&2
    exit 1
  fi
  if [[ ! "$TERMIX_IMAGE" =~ ^[a-zA-Z0-9._/:@-]+$ ]]; then
    echo "Invalid Termix image reference" >&2
    exit 1
  fi
fi

export DEBIAN_FRONTEND=noninteractive
cat >/etc/apt/apt.conf.d/99-ai-dev-timeouts <<'EOF'
Acquire::Retries "3";
Acquire::http::Timeout "60";
Acquire::https::Timeout "60";
DPkg::Lock::Timeout "300";
Dpkg::Use-Pty "0";
EOF

stage 5 "Refreshing Debian package indexes"
timeout --foreground 15m apt-get update

stage 10 "Upgrading Debian packages"
timeout --foreground 60m apt-get full-upgrade -y

stage 18 "Installing base development, keyring, and terminal packages"
timeout --foreground 45m apt-get install -y --no-install-recommends \
  sudo openssh-server ca-certificates curl wget git gh gnupg \
  build-essential python3 python3-dev python3-pip python3-venv pipx \
  jq ripgrep fd-find tmux mc unzip zip rsync shellcheck openssl \
  make cmake pkg-config less nano vim bash-completion locales xz-utils \
  iproute2 procps dbus dbus-user-session gnome-keyring libsecret-tools \
  libsecret-1-0 libpam-gnome-keyring python3-keyring pinentry-curses pass keyutils
timeout --foreground 15m apt-get autoremove -y

if ! command -v mc >/dev/null 2>&1; then
  echo "Midnight Commander installation verification failed." >&2
  exit 1
fi

stage 25 "Configuring the development account and SSH access"
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
stage 30 "Installing and configuring code-server"
curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 \
  https://code-server.dev/install.sh -o /tmp/install-code-server.sh
timeout --foreground 15m sh /tmp/install-code-server.sh
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

verify_code_server_local() {
  local service="code-server@$DEV_USER.service"
  local health_url="http://127.0.0.1:$CODE_SERVER_PORT/healthz"
  local health_file="/var/log/code-server-health.json"
  local listener_file="/var/log/code-server-listener.txt"
  local attempt

  : >"$health_file"
  : >"$listener_file"

  for attempt in $(seq 1 30); do
    if systemctl is-active --quiet "$service" && \
       curl -fsS --max-time 4 "$health_url" -o "$health_file" && \
       grep -Eq '"status"[[:space:]]*:' "$health_file"; then
      break
    fi
    sleep 1
  done

  ss -H -lntp | awk -v port=":$CODE_SERVER_PORT" '$4 ~ port "$" {print}' >"$listener_file" || true

  if ! systemctl is-active --quiet "$service"; then
    echo "ERROR: code-server service is not active after installation." >&2
    systemctl status "$service" --no-pager >&2 || true
    journalctl -u "$service" --since "$PROVISION_STARTED_AT" --no-pager >&2 || true
    return 1
  fi

  if [[ ! -s "$health_file" ]] || ! grep -Eq '"status"[[:space:]]*:' "$health_file"; then
    echo "ERROR: code-server /healthz did not return a valid response at $health_url." >&2
    curl -v --max-time 5 "$health_url" >&2 || true
    systemctl status "$service" --no-pager >&2 || true
    journalctl -u "$service" --since "$PROVISION_STARTED_AT" --no-pager >&2 || true
    return 1
  fi

  if [[ ! -s "$listener_file" ]]; then
    echo "ERROR: code-server is active but no TCP listener was found on port $CODE_SERVER_PORT." >&2
    ss -lntp >&2 || true
    return 1
  fi

  if [[ "$ACCESS_MODE" == "lan" ]]; then
    if ! grep -Eq "(^|[[:space:]])(0\\.0\\.0\\.0|\\*|\\[::\\]):$CODE_SERVER_PORT([[:space:]]|$)" "$listener_file"; then
      echo "ERROR: LAN mode requires code-server to listen on all interfaces, but the listener is:" >&2
      cat "$listener_file" >&2
      return 1
    fi
  else
    if ! grep -Eq "(^|[[:space:]])127\\.0\\.0\\.1:$CODE_SERVER_PORT([[:space:]]|$)" "$listener_file"; then
      echo "ERROR: Tunnel mode requires a loopback listener, but the listener is:" >&2
      cat "$listener_file" >&2
      return 1
    fi
  fi

  printf 'Local code-server health check passed: %s\n' "$(cat "$health_file")"
  printf 'Verified listener:\n'
  cat "$listener_file"
}

verify_code_server_local

cat >/etc/ai-development-web.env <<EOF
ACCESS_MODE=$ACCESS_MODE
CODE_SERVER_PORT=$CODE_SERVER_PORT
DEV_USER=$DEV_USER
EOF
chmod 0644 /etc/ai-development-web.env

# FileBrowser Quantum: authenticated browser file manager for /srv/workspace.
stage 40 "Installing and verifying FileBrowser Quantum"
validate_filebrowser_config() {
  local config_file=$1
  local validation_log=/tmp/filebrowser-config-validation.log
  local rc=0

  rm -f "$validation_log"
  # There is no dedicated config-validation subcommand. A valid configuration
  # starts the long-running server, so timeout(1) returning 124 is expected.
  # Invalid YAML/schema exits earlier and records a fatal parser error.
  set +e
  timeout --foreground --signal=TERM --kill-after=5s 12s \
    runuser -u "$DEV_USER" -- env \
      HOME="$DEV_HOME" USER="$DEV_USER" \
      FILEBROWSER_CONFIG="$config_file" \
      FILEBROWSER_ADMIN_PASSWORD="$FILE_MANAGER_PASSWORD" \
      /usr/local/bin/filebrowser -c "$config_file" \
      >"$validation_log" 2>&1
  rc=$?
  set -e
  pkill -TERM -u "$DEV_USER" -x filebrowser >/dev/null 2>&1 || true

  if grep -Eqi 'fatal|error unmarshaling|unknown field|unable to load config' "$validation_log"; then
    echo "ERROR: FileBrowser Quantum rejected the generated configuration." >&2
    cat "$validation_log" >&2
    return 1
  fi

  if [[ $rc -ne 124 && $rc -ne 137 && $rc -ne 143 ]]; then
    echo "ERROR: FileBrowser Quantum configuration preflight exited unexpectedly with status $rc." >&2
    cat "$validation_log" >&2
    return 1
  fi

  echo "FileBrowser Quantum configuration preflight passed."
}

install_filebrowser_quantum() {
  local arch asset_name asset_url api_url release_json tag_name tmp_binary
  local current_major new_major version_text config_file config_backup

  # A repair run may encounter an existing active or restart-looping service.
  # Stop it before replacing the binary or touching the database/configuration.
  systemctl stop filebrowser-quantum.service >/dev/null 2>&1 || true

  case "$(dpkg --print-architecture)" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    armhf)
      case "$(uname -m)" in
        armv6*) arch="armv6" ;;
        *) arch="armv7" ;;
      esac
      ;;
    *)
      echo "ERROR: FileBrowser Quantum does not provide a supported binary for $(dpkg --print-architecture)." >&2
      return 1
      ;;
  esac

  asset_name="linux-${arch}-filebrowser"
  api_url="https://api.github.com/repos/gtsteffaniak/filebrowser/releases/latest"
  release_json=$(mktemp)
  tmp_binary=$(mktemp)

  # Resolve the latest stable release through the GitHub API. This gives us a
  # reliable release tag for selecting the matching v1/v2 configuration schema.
  if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 90 \
      -H 'Accept: application/vnd.github+json' \
      "$api_url" -o "$release_json"; then
    tag_name=$(jq -r '.tag_name // empty' "$release_json")
    asset_url=$(jq -r --arg name "$asset_name" \
      '.assets[]? | select(.name == $name) | .browser_download_url' \
      "$release_json" | head -n1)
  else
    tag_name=""
    asset_url=""
  fi
  rm -f "$release_json"

  # Fallback keeps installation working when the API is unavailable or rate-limited.
  if [[ -z "$asset_url" || "$asset_url" == "null" ]]; then
    asset_url="https://github.com/gtsteffaniak/filebrowser/releases/latest/download/${asset_name}"
  fi

  curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 600 \
    "$asset_url" -o "$tmp_binary"
  chmod 0755 "$tmp_binary"

  version_text=$($tmp_binary version 2>&1 || $tmp_binary --version 2>&1 || true)
  new_major=$(sed -nE 's/.*[^0-9]([0-9]+)\.[0-9]+\.[0-9]+.*/\1/p' <<<"${tag_name:-$version_text}" | head -n1)
  if [[ -z "$new_major" ]]; then
    new_major=$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' <<<"$version_text" | head -n1 | cut -d. -f1 || true)
  fi
  [[ "$new_major" =~ ^[0-9]+$ ]] || new_major=1

  if [[ -x /usr/local/bin/filebrowser ]]; then
    version_text=$(/usr/local/bin/filebrowser version 2>&1 || /usr/local/bin/filebrowser --version 2>&1 || true)
    current_major=$(grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' <<<"$version_text" | head -n1 | cut -d. -f1 || true)
    if [[ -n "$current_major" && "$current_major" != "$new_major" ]] && \
       { [[ -e "$DEV_HOME/.local/share/filebrowser/database.db" ]] || \
         [[ -e "$DEV_HOME/.local/share/filebrowser/filebrowser.sqlite" ]]; }; then
      echo "WARNING: FileBrowser Quantum major upgrade $current_major -> $new_major requires an explicit database/config migration. Retaining the installed binary." >&2
      rm -f "$tmp_binary"
      new_major="$current_major"
    else
      install -m 0755 "$tmp_binary" /usr/local/bin/filebrowser
      rm -f "$tmp_binary"
    fi
  else
    install -m 0755 "$tmp_binary" /usr/local/bin/filebrowser
    rm -f "$tmp_binary"
  fi

  install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" \
    "$DEV_HOME/.config/filebrowser" \
    "$DEV_HOME/.local/share/filebrowser" \
    "$DEV_HOME/.cache/filebrowser"

  config_file="$DEV_HOME/.config/filebrowser/config.yaml"
  config_backup=""
  if [[ -f "$config_file" ]]; then
    config_backup="${config_file}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$config_file" "$config_backup"
  fi

  if [[ "$new_major" -ge 2 ]]; then
    cat >"$config_file" <<EOF
http:
  port: $FILE_MANAGER_PORT
  listen: "0.0.0.0"
  baseURL: "/"
  disableRateLimit: false
server:
  database:
    path: "$DEV_HOME/.local/share/filebrowser/filebrowser.sqlite"
  cacheDir: "$DEV_HOME/.cache/filebrowser"
  cacheDirCleanup: true
  sources:
    - path: "/srv/workspace"
      name: "Workspace"
      config:
        defaultEnabled: true
  filesystem:
    createFilePermission: "644"
    createDirectoryPermission: "755"
auth:
  adminUsername: admin
  methods:
    password:
      enabled: true
      minLength: 12
      signup: false
EOF
  else
    cat >"$config_file" <<EOF
server:
  port: $FILE_MANAGER_PORT
  database: "$DEV_HOME/.local/share/filebrowser/database.db"
  cacheDir: "$DEV_HOME/.cache/filebrowser"
  cacheDirCleanup: true
  sources:
    - path: "/srv/workspace"
      name: "Workspace"
      config:
        defaultEnabled: true
auth:
  adminUsername: admin
  methods:
    password:
      enabled: true
      minLength: 12
      signup: false
EOF
  fi
  chown "$DEV_USER:$DEV_USER" "$config_file"
  chmod 0600 "$config_file"

  if ! validate_filebrowser_config "$config_file"; then
    if [[ -n "$config_backup" && -f "$config_backup" ]]; then
      cp -a "$config_backup" "$config_file"
      chown "$DEV_USER:$DEV_USER" "$config_file"
      chmod 0600 "$config_file"
      echo "Previous FileBrowser configuration restored after failed preflight." >&2
    fi
    return 1
  fi

  cat >/etc/filebrowser-quantum.env <<EOF
FILEBROWSER_ADMIN_PASSWORD=$FILE_MANAGER_PASSWORD
FILEBROWSER_CONFIG=$config_file
HOME=$DEV_HOME
EOF
  chmod 0600 /etc/filebrowser-quantum.env

  cat >/etc/systemd/system/filebrowser-quantum.service <<EOF
[Unit]
Description=FileBrowser Quantum workspace manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$DEV_USER
Group=$DEV_USER
WorkingDirectory=$DEV_HOME/.local/share/filebrowser
EnvironmentFile=/etc/filebrowser-quantum.env
ExecStart=/usr/local/bin/filebrowser -c $config_file
Restart=on-failure
RestartSec=3
TimeoutStartSec=180
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=false
ReadWritePaths=/srv/workspace $DEV_HOME/.local/share/filebrowser $DEV_HOME/.cache/filebrowser

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/ai-development-file-manager.env <<EOF
FILE_MANAGER_ENABLED=1
FILE_MANAGER_PORT=$FILE_MANAGER_PORT
FILE_MANAGER_USER=$DEV_USER
FILE_MANAGER_ROOT=/srv/workspace
FILE_MANAGER_MAJOR=$new_major
EOF
  chmod 0644 /etc/ai-development-file-manager.env

  systemctl daemon-reload
  systemctl reset-failed filebrowser-quantum.service >/dev/null 2>&1 || true
  systemctl enable filebrowser-quantum.service >/dev/null
  systemctl restart filebrowser-quantum.service
}

filebrowser_diagnostics() {
  echo "=== FileBrowser Quantum diagnostics ===" >&2
  /usr/local/bin/filebrowser version >&2 2>&1 || /usr/local/bin/filebrowser --version >&2 2>&1 || true
  echo "--- generated config ---" >&2
  sed -E 's/(adminPassword:).*/\1 REDACTED/' "$DEV_HOME/.config/filebrowser/config.yaml" >&2 2>/dev/null || true
  echo "--- service definition ---" >&2
  systemctl cat filebrowser-quantum.service >&2 2>/dev/null || true
  echo "--- listeners ---" >&2
  ss -H -lntp >&2 2>/dev/null || true
  echo "--- service status ---" >&2
  systemctl status filebrowser-quantum.service --no-pager >&2 2>/dev/null || true
  echo "--- journal ---" >&2
  journalctl -u filebrowser-quantum.service --since "$PROVISION_STARTED_AT" --no-pager >&2 2>/dev/null || true
}

verify_filebrowser_local() {
  local service="filebrowser-quantum.service"
  local health_url="http://127.0.0.1:$FILE_MANAGER_PORT/health"
  local root_url="http://127.0.0.1:$FILE_MANAGER_PORT/"
  local listener="" health="" root_code="000" attempt

  # Initial indexing and first-database creation may take longer on slower hosts.
  for attempt in $(seq 1 120); do
    listener=$(ss -H -lntp 2>/dev/null | awk -v port=":$FILE_MANAGER_PORT" '$4 ~ port "$" {print}')
    health=$(curl -fsS --max-time 4 "$health_url" 2>/dev/null || true)
    root_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 4 "$root_url" 2>/dev/null || printf '000')
    if systemctl is-active --quiet "$service" && [[ -n "$listener" ]] && \
       { [[ -n "$health" ]] || [[ "$root_code" =~ ^(200|301|302|303|307|308|401|403)$ ]]; }; then
      break
    fi
    sleep 1
  done

  if ! systemctl is-active --quiet "$service"; then
    echo "ERROR: FileBrowser Quantum service is not active." >&2
    filebrowser_diagnostics
    return 1
  fi

  if [[ -z "$listener" ]]; then
    echo "ERROR: FileBrowser Quantum is active but is not listening on configured port $FILE_MANAGER_PORT." >&2
    filebrowser_diagnostics
    return 1
  fi

  if ! grep -Eq "(^|[[:space:]])(0\\.0\\.0\\.0|\\*|\\[::\\]):$FILE_MANAGER_PORT([[:space:]]|$)" <<<"$listener"; then
    echo "ERROR: FileBrowser Quantum is not listening on all interfaces at port $FILE_MANAGER_PORT." >&2
    printf '%s\n' "$listener" >&2
    filebrowser_diagnostics
    return 1
  fi

  if [[ -z "$health" && ! "$root_code" =~ ^(200|301|302|303|307|308|401|403)$ ]]; then
    echo "ERROR: FileBrowser Quantum did not respond on either $health_url or $root_url." >&2
    filebrowser_diagnostics
    return 1
  fi

  if [[ -n "$health" ]]; then
    printf 'FileBrowser Quantum health check passed: %s\n' "$health"
  else
    printf 'FileBrowser Quantum HTTP check passed at %s with status %s; /health was unavailable.\n' "$root_url" "$root_code"
  fi
  printf 'Verified listener: %s\n' "$listener"
}

if [[ "$FILE_MANAGER_ENABLED" == "1" ]]; then
  install_filebrowser_quantum
  verify_filebrowser_local
else
  systemctl disable --now filebrowser-quantum.service >/dev/null 2>&1 || true
  cat >/etc/ai-development-file-manager.env <<EOF
FILE_MANAGER_ENABLED=0
FILE_MANAGER_PORT=$FILE_MANAGER_PORT
FILE_MANAGER_USER=$DEV_USER
FILE_MANAGER_ROOT=/srv/workspace
EOF
  chmod 0644 /etc/ai-development-file-manager.env
fi

stage 50 "Configuring headless GNOME Keyring and credential helpers"
# Headless credential-store support. GNOME Keyring provides the Secret Service
# implementation; libsecret and Python keyring clients can use it through D-Bus.
loginctl enable-linger "$DEV_USER" >/dev/null 2>&1 || true
for profile in "$DEV_HOME/.profile" "$DEV_HOME/.bashrc"; do
  touch "$profile"
  if ! grep -Fq 'GPG_TTY' "$profile"; then
    cat >>"$profile" <<'EOF'
if tty -s; then
  export GPG_TTY="$(tty)"
fi
EOF
  fi
done
chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.profile" "$DEV_HOME/.bashrc"

cat >/usr/local/bin/keyring-session <<'KEYRING'
#!/usr/bin/env bash
set -Eeuo pipefail

if ! command -v dbus-run-session >/dev/null 2>&1 || ! command -v gnome-keyring-daemon >/dev/null 2>&1; then
  echo 'GNOME Keyring or D-Bus support is not installed.' >&2
  exit 1
fi

if (($# == 0)); then
  exec dbus-run-session -- bash -lc '
    eval "$(gnome-keyring-daemon --start --components=secrets,ssh,pkcs11)"
    export GNOME_KEYRING_CONTROL SSH_AUTH_SOCK
    exec "${SHELL:-/bin/bash}" -l
  '
fi

printf -v command_line '%q ' "$@"
exec dbus-run-session -- bash -lc "
  eval \"\$(gnome-keyring-daemon --start --components=secrets,ssh,pkcs11)\"
  export GNOME_KEYRING_CONTROL SSH_AUTH_SOCK
  exec $command_line
"
KEYRING
chmod 0755 /usr/local/bin/keyring-session

cat >/usr/local/bin/keyring-status <<'KEYSTATUS'
#!/usr/bin/env bash
set -u

failed=0
for package in gnome-keyring libsecret-tools dbus-user-session python3-keyring pinentry-curses pass; do
  if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'ok installed'; then
    printf '[OK]   %-24s installed\n' "$package"
  else
    printf '[FAIL] %-24s not installed\n' "$package"
    failed=1
  fi
done

if [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]]; then
  printf '[OK]   D-Bus session address: %s\n' "$DBUS_SESSION_BUS_ADDRESS"
else
  printf '[INFO] No D-Bus user session in this shell. Start one with: keyring-session\n'
fi

if pgrep -u "$(id -u)" -x gnome-keyring-daemon >/dev/null 2>&1; then
  printf '[OK]   gnome-keyring-daemon is running for this user.\n'
else
  printf '[INFO] gnome-keyring-daemon is not running in this shell.\n'
fi

command -v secret-tool >/dev/null 2>&1 || failed=1
exit "$failed"
KEYSTATUS
chmod 0755 /usr/local/bin/keyring-status

stage 58 "Installing and verifying Termix and its container runtime"
# Termix: web-based SSH terminal and server-management panel.
docker_diagnostics() {
  echo "=== Docker service state ===" >&2
  systemctl show docker.service \
    -p LoadState -p ActiveState -p SubState -p Result \
    -p ExecMainCode -p ExecMainStatus --no-pager >&2 || true
  systemctl status docker.service --no-pager -l >&2 || true
  echo "=== Docker daemon configuration ===" >&2
  if [[ -f /etc/docker/daemon.json ]]; then
    cat /etc/docker/daemon.json >&2 || true
    jq empty /etc/docker/daemon.json >&2 || true
    timeout --foreground 15s dockerd --validate \
      --config-file=/etc/docker/daemon.json >&2 || true
  else
    echo "/etc/docker/daemon.json does not exist." >&2
  fi
  echo "=== Docker journal ===" >&2
  journalctl -u docker.service -u containerd.service --since "$PROVISION_STARTED_AT" --no-pager -l >&2 || true
}

docker_socket_path() {
  if [[ -S /run/docker.sock ]]; then
    printf '%s' /run/docker.sock
  elif [[ -S /var/run/docker.sock ]]; then
    printf '%s' /var/run/docker.sock
  else
    return 1
  fi
}

docker_api_ping() {
  local socket response
  socket=$(docker_socket_path) || return 1
  response=$(timeout --foreground 5s curl -fsS \
    --unix-socket "$socket" http://localhost/_ping 2>/dev/null) || return 1
  [[ "$response" == "OK" ]]
}

docker_cli_ready() {
  timeout --foreground 10s docker version \
    --format '{{.Server.Version}}' >/dev/null 2>&1
}

wait_for_docker() {
  local attempt state api_seen=0
  for attempt in $(seq 1 45); do
    if docker_api_ping; then
      api_seen=1
      if docker_cli_ready; then
        return 0
      fi
    fi

    state=$(systemctl is-failed docker.service 2>/dev/null || true)
    [[ "$state" == failed ]] && return 1
    sleep 2
  done

  if ((api_seen)); then
    echo "ERROR: Docker API answered /_ping, but the Docker CLI could not negotiate with the daemon." >&2
    timeout --foreground 15s docker version >&2 || true
  else
    echo "ERROR: Docker did not expose a responsive Unix-socket API." >&2
  fi
  return 1
}

configure_nested_docker_storage() {
  local tmp_json backup=""
  install -d -m 0755 /etc/docker

  if [[ -s /etc/docker/daemon.json ]]; then
    backup="/etc/docker/daemon.json.pre-lxc-vfs.$(date +%Y%m%d-%H%M%S)"
    cp -a /etc/docker/daemon.json "$backup"
    if ! jq empty /etc/docker/daemon.json >/dev/null 2>&1; then
      echo "ERROR: Existing /etc/docker/daemon.json is not valid JSON; preserved as $backup." >&2
      return 1
    fi
    tmp_json=$(mktemp)
    jq '. + {"storage-driver":"vfs"}' /etc/docker/daemon.json >"$tmp_json"
    install -m 0644 "$tmp_json" /etc/docker/daemon.json
    rm -f "$tmp_json"
  else
    cat >/etc/docker/daemon.json <<'EOF'
{
  "storage-driver": "vfs"
}
EOF
  fi

  jq empty /etc/docker/daemon.json
  if ! timeout --foreground 15s dockerd --validate \
      --config-file=/etc/docker/daemon.json; then
    echo "ERROR: Docker rejected /etc/docker/daemon.json." >&2
    [[ -n "$backup" ]] && cp -a "$backup" /etc/docker/daemon.json
    return 1
  fi
}

wait_for_unit_active() {
  local unit=$1 timeout_seconds=$2 elapsed=0 state
  while ((elapsed < timeout_seconds)); do
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    [[ "$state" == active ]] && return 0
    [[ "$state" == failed ]] && return 1
    sleep 2
    ((elapsed += 2))
  done
  return 1
}

start_docker_once() {
  systemctl daemon-reload
  systemctl reset-failed containerd.service docker.service docker.socket 2>/dev/null || true

  systemctl start --no-block containerd.service
  if ! wait_for_unit_active containerd.service 90; then
    echo "ERROR: containerd did not become active within 90 seconds." >&2
    docker_diagnostics
    return 1
  fi

  systemctl start --no-block docker.service
  if ! wait_for_unit_active docker.service 120; then
    echo "ERROR: Docker service did not become active within 120 seconds." >&2
    docker_diagnostics
    return 1
  fi

  if ! wait_for_docker; then
    echo "ERROR: Docker service is active, but its API/CLI readiness check failed." >&2
    docker_diagnostics
    return 1
  fi
}

install_termix() {
  timeout --foreground 30m apt-get install -y --no-install-recommends \
    docker.io docker-compose
  systemctl enable docker.service containerd.service >/dev/null

  # Debian may start Docker from the package post-install script. Readiness is
  # checked through the daemon's /_ping API plus `docker version`; `docker info`
  # is intentionally not used because it may block in nested LXC environments.
  if wait_for_docker; then
    echo "Docker is already active and responsive; preserving its current configuration."
  else
    current_state=$(systemctl is-active docker.service 2>/dev/null || true)
    if [[ "$current_state" == active ]]; then
      echo "ERROR: Docker service is active but its Unix-socket API is not usable." >&2
      echo "The installer will not stop or reconfigure a running daemon automatically." >&2
      docker_diagnostics
      return 1
    fi

    echo "Docker is not active after package installation; attempting one non-blocking start."
    if ! start_docker_once; then
      journal_text=$(journalctl -u docker.service -u containerd.service --since "$PROVISION_STARTED_AT" --no-pager -l 2>/dev/null || true)
      if grep -Eqi 'overlay|overlay2|operation not permitted|failed to mount|invalid argument' <<<"$journal_text"; then
        echo "Docker startup indicates a nested-LXC storage-driver problem; applying vfs once." >&2
        timeout --foreground 60s systemctl stop docker.service docker.socket 2>/dev/null || true
        configure_nested_docker_storage
        start_docker_once || {
          echo "ERROR: Docker remains unavailable after the vfs fallback. Confirm nesting=1,keyctl=1." >&2
          docker_diagnostics
          return 1
        }
      else
        echo "ERROR: Docker could not be started. No storage-driver rewrite was attempted." >&2
        return 1
      fi
    fi
  fi

  printf 'Docker is ready. Server version: %s\n' \
    "$(timeout --foreground 8s docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
  docker_socket=$(docker_socket_path || true)
  if [[ -n "$docker_socket" ]]; then
    docker_driver=$(timeout --foreground 8s curl -fsS --unix-socket "$docker_socket" \
      http://localhost/info 2>/dev/null | jq -r '.Driver // "unknown"' 2>/dev/null || echo unavailable)
  else
    docker_driver=unavailable
  fi
  printf 'Docker storage driver: %s\n' "$docker_driver"

  if ! timeout --foreground 15s docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose v2 is not available after installing docker-compose." >&2
    docker compose version >&2 || true
    command -v docker-compose >&2 || true
    return 1
  fi

  usermod -aG docker "$DEV_USER"
  install -d -m 0755 /opt/termix /var/backups/termix
  docker volume create termix-data >/dev/null
  cat >/opt/termix/compose.yaml <<EOF
services:
  termix:
    image: $TERMIX_IMAGE
    container_name: termix
    restart: unless-stopped
    ports:
      - "$TERMIX_PORT:8080"
    volumes:
      - termix-data:/app/data
    environment:
      PORT: "8080"
    extra_hosts:
      - "host.docker.internal:host-gateway"
volumes:
  termix-data:
    name: termix-data
EOF
  chmod 0644 /opt/termix/compose.yaml
  timeout --foreground 30m docker compose -f /opt/termix/compose.yaml pull
  timeout --foreground 10m docker compose -f /opt/termix/compose.yaml up -d --remove-orphans

  cat >/etc/ai-development-termix.env <<EOF
TERMIX_ENABLED=1
TERMIX_PORT=$TERMIX_PORT
TERMIX_IMAGE=$TERMIX_IMAGE
TERMIX_COMPOSE_FILE=/opt/termix/compose.yaml
TERMIX_DATA_VOLUME=termix-data
EOF
  chmod 0644 /etc/ai-development-termix.env
}

cat >/usr/local/bin/termix-status <<'TERMIXSTATUS'
#!/usr/bin/env bash
set -Eeuo pipefail
check=0
[[ ${1:-} == --check ]] && check=1
source /etc/ai-development-termix.env 2>/dev/null || {
  echo "Termix is not configured."
  exit 1
}
if [[ ${TERMIX_ENABLED:-0} != 1 ]]; then
  echo "Termix is disabled."
  exit 0
fi
failed=0
container_state=$(docker inspect -f '{{.State.Status}}' termix 2>/dev/null || true)
listener=$(ss -H -lntp 2>/dev/null | awk -v port=":$TERMIX_PORT" '$4 ~ port "$" {print}')
published=$(docker port termix 8080/tcp 2>/dev/null || true)
http_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:$TERMIX_PORT/" || true)
[[ $(systemctl is-active docker.service 2>/dev/null || true) == active ]] || failed=1
[[ $container_state == running ]] || failed=1
[[ -n $listener || -n $published ]] || failed=1
if ! grep -Eq "(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]):$TERMIX_PORT([[:space:]]|$)" <<<"$listener"; then
  grep -Eq "^(0\.0\.0\.0|\[::\]):$TERMIX_PORT$" <<<"$published" || failed=1
fi
[[ $http_code =~ ^(2|3)[0-9][0-9]$ ]] || failed=1
printf 'Docker service:   %s\n' "$(systemctl is-active docker.service 2>/dev/null || true)"
printf 'Termix container: %s\n' "${container_state:-missing}"
printf 'Image:            %s\n' "$TERMIX_IMAGE"
printf 'Port:             %s\n' "$TERMIX_PORT"
printf 'Listener:         %s\n' "${listener:-not visible in ss}"
printf 'Published port:   %s\n' "${published:-missing}"
printf 'HTTP response:    %s\n' "${http_code:-none}"
for address in $(hostname -I 2>/dev/null); do
  [[ $address == *:* ]] || printf 'LAN URL:          http://%s:%s\n' "$address" "$TERMIX_PORT"
done
printf 'Local LXC host:   host.docker.internal:22\n'
if ((failed)); then
  printf 'Result:           FAIL\n'
  ((check)) && exit 1
else
  printf 'Result:           PASS\n'
fi
TERMIXSTATUS
chmod 0755 /usr/local/bin/termix-status

cat >/usr/local/sbin/termix-backup <<'TERMIXBACKUP'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-development-termix.env
stamp=$(date +%Y%m%d-%H%M%S)
backup="/var/backups/termix/termix-data-$stamp.tar.gz"
mountpoint=$(docker volume inspect -f '{{.Mountpoint}}' "$TERMIX_DATA_VOLUME")
install -d -m 0750 /var/backups/termix
docker compose -f "$TERMIX_COMPOSE_FILE" stop termix >/dev/null
trap 'docker compose -f "$TERMIX_COMPOSE_FILE" start termix >/dev/null 2>&1 || true' EXIT
tar -C "$mountpoint" -czf "$backup" .
chmod 0600 "$backup"
docker compose -f "$TERMIX_COMPOSE_FILE" start termix >/dev/null
trap - EXIT
printf '%s\n' "$backup"
TERMIXBACKUP
chmod 0750 /usr/local/sbin/termix-backup

cat >/usr/local/sbin/termix-update <<'TERMIXUPDATE'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-development-termix.env
/usr/local/sbin/termix-backup
docker compose -f "$TERMIX_COMPOSE_FILE" pull
docker compose -f "$TERMIX_COMPOSE_FILE" up -d --remove-orphans
/usr/local/bin/termix-status --check
TERMIXUPDATE
chmod 0750 /usr/local/sbin/termix-update

cat >/usr/local/sbin/termix-restart <<'TERMIXRESTART'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-development-termix.env
docker compose -f "$TERMIX_COMPOSE_FILE" restart termix
/usr/local/bin/termix-status --check
TERMIXRESTART
chmod 0750 /usr/local/sbin/termix-restart

cat >/usr/local/bin/termix-logs <<'TERMIXLOGS'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-development-termix.env
exec docker compose -f "$TERMIX_COMPOSE_FILE" logs --tail=200 -f termix
TERMIXLOGS
chmod 0755 /usr/local/bin/termix-logs

if [[ "$TERMIX_ENABLED" == "1" ]]; then
  install_termix
  for attempt in $(seq 1 60); do
    /usr/local/bin/termix-status --check >/dev/null 2>&1 && break
    sleep 2
  done
  /usr/local/bin/termix-status --check
else
  if command -v docker >/dev/null 2>&1 && [[ -f /opt/termix/compose.yaml ]]; then
    docker compose -f /opt/termix/compose.yaml down --remove-orphans || true
  fi
  cat >/etc/ai-development-termix.env <<EOF
TERMIX_ENABLED=0
TERMIX_PORT=$TERMIX_PORT
TERMIX_IMAGE=$TERMIX_IMAGE
TERMIX_COMPOSE_FILE=/opt/termix/compose.yaml
TERMIX_DATA_VOLUME=termix-data
EOF
  chmod 0644 /etc/ai-development-termix.env
fi

stage 68 "Installing selected AI coding agents"
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
  curl -fsSL --retry 3 --connect-timeout 20 --max-time 120 "$base/SHASUMS256.txt" -o "$tmp_dir/SHASUMS256.txt"
  node_file=$(awk -v arch="$node_arch" \
    '$2 ~ ("^node-v22\\.[0-9]+\\.[0-9]+-linux-" arch "\\.tar\\.xz$") {print $2}' \
    "$tmp_dir/SHASUMS256.txt" | sort -V | tail -n 1)
  [[ -n "$node_file" ]] || { echo 'Unable to determine the current Node.js 22 build.' >&2; rm -rf "$tmp_dir"; return 1; }

  curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 "$base/$node_file" -o "$tmp_dir/$node_file"
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
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
    https://downloads.claude.ai/claude-code-releases/latest \
    -o /tmp/claude-code-latest-version
  printf 'Available Claude Code release: %s\n' "$(tr -d '[:space:]' </tmp/claude-code-latest-version)"
  rm -f /tmp/claude-code-latest-version

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
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

  timeout --foreground 15m apt-get update
  timeout --foreground 30m apt-get install -y --no-install-recommends claude-code
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
  stage 69 "Installing Claude Code"
  install_agent claude 'Claude Code' install_claude_code
fi

if has_agent codex; then
  stage 71 "Installing OpenAI Codex CLI"
  install_agent codex 'OpenAI Codex CLI' \
    run_as_dev_shell 'set -o pipefail; timeout --foreground 20m bash -c "curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 https://chatgpt.com/codex/install.sh | CODEX_NON_INTERACTIVE=1 sh"'
fi

if has_agent gemini; then
  stage 73 "Installing Google Gemini CLI"
  install_agent gemini 'Google Gemini CLI' \
    run_as_dev timeout --foreground 20m npm install -g @google/gemini-cli@latest
fi

if has_agent copilot; then
  stage 75 "Installing GitHub Copilot CLI"
  install_agent copilot 'GitHub Copilot CLI' \
    run_as_dev env npm_config_ignore_scripts=false timeout --foreground 20m npm install -g @github/copilot@latest
fi

if has_agent aider; then
  stage 77 "Installing Aider"
  install_agent aider 'Aider' \
    run_as_dev_shell 'set -o pipefail; timeout --foreground 20m bash -c "curl -LsSf --retry 3 --connect-timeout 20 --max-time 600 https://aider.chat/install.sh | sh"'
fi

if has_agent opencode; then
  stage 79 "Installing OpenCode"
  install_agent opencode 'OpenCode' \
    run_as_dev_shell 'set -o pipefail; timeout --foreground 20m bash -c "curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 https://opencode.ai/install | bash"'
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

stage 80 "Installing Robot Framework and RobotCode"
# Stable system-level Robot Framework tool environment.
python3 -m venv /opt/robotframework
timeout --foreground 15m /opt/robotframework/bin/python -m pip install --upgrade pip setuptools wheel
timeout --foreground 30m /opt/robotframework/bin/python -m pip install --upgrade robotframework 'robotcode[all]'
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
- `github-tools-status` — verify GitHub CLI, GitHub Pull Requests extension, and login state
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

stage 88 "Installing and verifying code-server extensions"
# Open VSX extension installation. Core development extensions are verified;
# optional AI integrations remain best-effort because availability can vary.
code_server_extension_installed() {
  local extension=$1
  runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" USER="$DEV_USER" \
    code-server --list-extensions 2>/dev/null | grep -Fxiq -- "$extension"
}

install_required_extension() {
  local extension=$1
  local attempt

  if code_server_extension_installed "$extension"; then
    printf 'Required code-server extension already installed: %s\n' "$extension"
    return 0
  fi

  for attempt in 1 2 3; do
    printf 'Installing required code-server extension %s (attempt %s/3)...\n' \
      "$extension" "$attempt"
    if runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" USER="$DEV_USER" \
        code-server --install-extension "$extension" && \
        code_server_extension_installed "$extension"; then
      printf 'Verified required code-server extension: %s\n' "$extension"
      return 0
    fi
    sleep "$attempt"
  done

  echo "ERROR: required code-server extension was not installed: $extension" >&2
  return 1
}

install_optional_extension() {
  local extension=$1
  if code_server_extension_installed "$extension"; then
    return 0
  fi
  if ! runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" USER="$DEV_USER" \
      code-server --install-extension "$extension"; then
    echo "WARNING: optional code-server extension not installed: $extension"
  fi
}

install_required_extension ms-python.python
install_required_extension d-biehl.robotcode
install_required_extension GitHub.vscode-pull-request-github
if has_agent claude; then
  install_optional_extension anthropic.claude-code
fi
if has_agent codex; then
  install_optional_extension openai.chatgpt
fi
if has_agent gemini; then
  install_optional_extension Google.gemini-cli-vscode-ide-companion
fi

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

cat >/usr/local/bin/web-ide-status <<'WEBSTATUS'
#!/usr/bin/env bash
set -u

ACCESS_MODE="unknown"
CODE_SERVER_PORT="8080"
DEV_USER=$(cat /etc/ai-development-user 2>/dev/null || echo dev)
[[ -r /etc/ai-development-web.env ]] && source /etc/ai-development-web.env
service="code-server@$DEV_USER.service"
health_url="http://127.0.0.1:$CODE_SERVER_PORT/healthz"
check_only=0
[[ ${1:-} == "--check" ]] && check_only=1
failed=0

service_state=$(systemctl is-active "$service" 2>/dev/null || true)
listener=$(ss -H -lntp 2>/dev/null | awk -v port=":$CODE_SERVER_PORT" '$4 ~ port "$" {print}')
health=$(curl -fsS --max-time 4 "$health_url" 2>/dev/null || true)

[[ $service_state == active ]] || failed=1
[[ -n $listener ]] || failed=1
[[ $health == *'"status"'* ]] || failed=1

if [[ $ACCESS_MODE == lan ]]; then
  grep -Eq "(^|[[:space:]])(0\\.0\\.0\\.0|\\*|\\[::\\]):$CODE_SERVER_PORT([[:space:]]|$)" <<<"$listener" || failed=1
else
  grep -Eq "(^|[[:space:]])127\\.0\\.0\\.1:$CODE_SERVER_PORT([[:space:]]|$)" <<<"$listener" || failed=1
fi

if ((check_only == 0)); then
  printf 'Access mode:     %s\n' "$ACCESS_MODE"
  printf 'Service:         %s (%s)\n' "$service" "${service_state:-unknown}"
  printf 'Port:            %s\n' "$CODE_SERVER_PORT"
  printf 'Listener:        %s\n' "${listener:-not found}"
  printf 'Local health:    %s\n' "${health:-FAILED}"
  if [[ $ACCESS_MODE == lan ]]; then
    while IFS= read -r address; do
      [[ -n $address ]] && printf 'LAN URL:         http://%s:%s\n' "$address" "$CODE_SERVER_PORT"
    done < <(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\\.[0-9]+){3}$' || true)
  else
    printf 'Tunnel URL:      http://127.0.0.1:%s\n' "$CODE_SERVER_PORT"
  fi
  if ((failed)); then
    printf 'Result:          FAILED\n'
    printf '\nDiagnostics:\n'
    systemctl status "$service" --no-pager 2>/dev/null || true
    journalctl -u "$service" -n 40 --no-pager 2>/dev/null || true
  else
    printf 'Result:          PASS\n'
  fi
fi

exit "$failed"
WEBSTATUS
chmod 0755 /usr/local/bin/web-ide-status

cat >/usr/local/bin/file-manager-status <<'FILEMANAGERSTATUS'
#!/usr/bin/env bash
set -u
FILE_MANAGER_ENABLED=0
FILE_MANAGER_PORT=8081
FILE_MANAGER_ROOT=/srv/workspace
[[ -r /etc/ai-development-file-manager.env ]] && source /etc/ai-development-file-manager.env
check_only=0
[[ ${1:-} == --check ]] && check_only=1
failed=0

if [[ "$FILE_MANAGER_ENABLED" != "1" ]]; then
  ((check_only == 0)) && echo 'FileBrowser Quantum: disabled'
  exit 0
fi

service=filebrowser-quantum.service
health_url="http://127.0.0.1:$FILE_MANAGER_PORT/health"
root_url="http://127.0.0.1:$FILE_MANAGER_PORT/"
service_state=$(systemctl is-active "$service" 2>/dev/null || true)
listener=$(ss -H -lntp 2>/dev/null | awk -v port=":$FILE_MANAGER_PORT" '$4 ~ port "$" {print}')
health=$(curl -fsS --max-time 4 "$health_url" 2>/dev/null || true)
root_code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 4 "$root_url" 2>/dev/null || printf '000')
version=$(filebrowser version 2>&1 | head -n1 || filebrowser --version 2>&1 | head -n1 || true)

[[ "$service_state" == active ]] || failed=1
[[ -n "$listener" ]] || failed=1
if [[ -z "$health" && ! "$root_code" =~ ^(200|301|302|303|307|308|401|403)$ ]]; then
  failed=1
fi
grep -Eq "(^|[[:space:]])(0\\.0\\.0\\.0|\\*|\\[::\\]):$FILE_MANAGER_PORT([[:space:]]|$)" <<<"$listener" || failed=1

if ((check_only == 0)); then
  printf 'Version:          %s\n' "${version:-unknown}"
  printf 'Service:          %s (%s)\n' "$service" "${service_state:-unknown}"
  printf 'Workspace root:   %s\n' "$FILE_MANAGER_ROOT"
  printf 'Port:             %s\n' "$FILE_MANAGER_PORT"
  printf 'Listener:         %s\n' "${listener:-not found}"
  printf 'Local /health:    %s\n' "${health:-unavailable}"
  printf 'Local root HTTP:  %s\n' "${root_code:-000}"
  while IFS= read -r address; do
    [[ -n $address ]] && printf 'LAN URL:          http://%s:%s\n' "$address" "$FILE_MANAGER_PORT"
  done < <(hostname -I 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' || true)
  if ((failed)); then
    printf 'Result:           FAILED\n'
    systemctl status "$service" --no-pager 2>/dev/null || true
    journalctl -u "$service" -n 100 --no-pager 2>/dev/null || true
  else
    printf 'Result:           PASS\n'
  fi
fi
exit "$failed"
FILEMANAGERSTATUS
chmod 0755 /usr/local/bin/file-manager-status
if [[ "$FILE_MANAGER_ENABLED" == "1" ]]; then
  file-manager-status --check
fi

cat >/usr/local/sbin/file-manager-password-reset <<'FILEMANAGERRESET'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo 'Run with sudo: sudo file-manager-password-reset' >&2
  exit 1
fi
[[ -r /etc/ai-development-file-manager.env ]] && source /etc/ai-development-file-manager.env
[[ ${FILE_MANAGER_ENABLED:-0} == 1 ]] || { echo 'FileBrowser Quantum is disabled.' >&2; exit 1; }
read -r -s -p 'New FileBrowser admin password: ' first
echo
read -r -s -p 'Repeat password: ' second
echo
[[ ${#first} -ge 12 ]] || { echo 'Password must contain at least 12 characters.' >&2; exit 1; }
[[ "$first" =~ ^[A-Za-z0-9._~@%+=:-]+$ ]] || { echo 'Use letters, digits, and . _ ~ @ % + = : - only.' >&2; exit 1; }
[[ "$first" == "$second" ]] || { echo 'Passwords do not match.' >&2; exit 1; }
printf 'FILEBROWSER_ADMIN_PASSWORD=%s\n' "$first" >/etc/filebrowser-quantum.env
chmod 0600 /etc/filebrowser-quantum.env
systemctl restart filebrowser-quantum.service
file-manager-status --check
echo 'FileBrowser Quantum admin password updated.'
FILEMANAGERRESET
chmod 0750 /usr/local/sbin/file-manager-password-reset

cat >/usr/local/bin/github-tools-status <<'GITHUBSTATUS'
#!/usr/bin/env bash
set -u

failed=0
extension_id='GitHub.vscode-pull-request-github'
service_user=$(cat /etc/ai-development-user 2>/dev/null || whoami)
service_home=$(getent passwd "$service_user" 2>/dev/null | cut -d: -f6)
service_home=${service_home:-"/home/$service_user"}

as_service_user() {
  if [[ $(id -un) == "$service_user" ]]; then
    env HOME="$service_home" USER="$service_user" "$@"
  elif [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    runuser -u "$service_user" -- env HOME="$service_home" USER="$service_user" "$@"
  else
    echo "Run this command as $service_user or root." >&2
    return 1
  fi
}

printf 'GitHub CLI:       '
if command -v gh >/dev/null 2>&1; then
  printf 'PASS — %s\n' "$(gh --version 2>&1 | head -n 1)"
else
  printf 'FAIL — gh command is missing\n'
  failed=1
fi

printf 'GitHub extension: '
if command -v code-server >/dev/null 2>&1 && \
   as_service_user code-server --list-extensions 2>/dev/null | \
     grep -Fxiq -- "$extension_id"; then
  printf 'PASS — %s\n' "$extension_id"
else
  printf 'FAIL — %s is not installed\n' "$extension_id"
  failed=1
fi

printf 'GitHub login:     '
if command -v gh >/dev/null 2>&1 && \
   as_service_user gh auth status --hostname github.com >/dev/null 2>&1; then
  account=$(as_service_user gh api user --jq .login 2>/dev/null || true)
  printf 'AUTHENTICATED%s\n' "${account:+ — $account}"
else
  printf 'NOT CONFIGURED — run dev-auth or gh auth login --web\n'
fi

if [[ ${1:-} == '--check' ]]; then
  exit "$failed"
fi
exit 0
GITHUBSTATUS
chmod 0755 /usr/local/bin/github-tools-status
github-tools-status --check

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
printf 'Midnight Cmdr:   %s\n' "$(mc --version 2>&1 | head -n 1)"
if command -v node >/dev/null 2>&1; then
  printf 'Node.js:         %s\n' "$(node --version 2>&1)"
fi
printf 'code-server:     %s\n' "$(code-server --version 2>&1 | head -n 1)"
if command -v filebrowser >/dev/null 2>&1; then
  printf 'FileBrowser:     %s\n' "$(filebrowser version 2>&1 | head -n 1 || filebrowser --version 2>&1 | head -n 1)"
fi
printf 'SSH service:     %s\n' "$(systemctl is-active ssh 2>/dev/null || true)"
service_user=$(cat /etc/ai-development-user 2>/dev/null || whoami)
printf 'Web IDE service: %s\n' "$(systemctl is-active "code-server@$service_user" 2>/dev/null || true)"
printf '\nWeb IDE verification:\n'
web-ide-status || true
printf '\nWeb file manager:\n'
file-manager-status || true
printf '\nTermix web terminal:\n'
termix-status || true
printf '\nGitHub integration:\n'
github-tools-status || true
printf '\nCredential storage:\n'
keyring-status || true
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
GitHub integration: Run `dev-auth` for browser login and Git credential setup.
                    Run `github-tools-status` to verify the CLI, extension, and login.

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
1) GitHub CLI login and Git credential setup
g) Show GitHub integration status
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
    1) gh auth login --hostname github.com --git-protocol https --web && gh auth setup-git && github-tools-status ;;
    g|G) github-tools-status ;;
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
GitHub status:      github-tools-status
Web IDE check:      web-ide-status
Web files check:    file-manager-status
Web file manager:   http://LXC_IP:$FILE_MANAGER_PORT
Termix check:       termix-status
Termix web panel:   http://LXC_IP:$TERMIX_PORT
Termix update:      sudo termix-update
Termix backup:      sudo termix-backup
Password reset:     sudo file-manager-password-reset
Keyring check:      keyring-status
Keyring shell:      keyring-session
Terminal manager:   mc
Web manager root:   /srv/workspace
Provider key file:  ~/.config/ai-agents/env
Web IDE service:    systemctl status code-server@$DEV_USER

EOF

stage 96 "Running the final Robot Framework smoke test"
# Smoke test the installed Robot Framework environment.
cd "$PROJECT"
"$PROJECT/.venv/bin/python" -m robot --outputdir results tests
chown -R "$DEV_USER:$DEV_USER" "$PROJECT/results"

rm -f /root/claude-dev.env
if ((${#FAILED_AGENTS[@]} > 0)); then
  printf '%s\n' "${FAILED_AGENTS[@]}" >/var/log/ai-agent-install-failures
  chmod 0644 /var/log/ai-agent-install-failures
  stage 99 "Base environment complete; one or more optional AI agents failed"
  printf '[%s] Provisioning completed with AI-agent failures: %s\n' \
    "$(date '+%F %T')" "${FAILED_AGENTS[*]}"
  exit 20
fi
rm -f /var/log/ai-agent-install-failures
stage 100 "Provisioning completed successfully"
printf '[%s] Provisioning completed\n' "$(date '+%F %T')"
PROVISION
  chmod 0700 "$provision_file"

  pct push "$CTID" "$env_file" /root/claude-dev.env --perms 0600 >>"$LOG_FILE" 2>&1
  pct push "$CTID" "$provision_file" /root/claude-dev-provision.sh --perms 0700 >>"$LOG_FILE" 2>&1
  rm -rf "$tmp_dir"
}

ensure_termix_lxc_features() {
  [[ "$TERMIX_ENABLED" == "1" ]] || return 0
  local current="" merged="" state="" was_running=0 feature
  current=$(pct config "$CTID" 2>/dev/null | sed -n 's/^features:[[:space:]]*//p')
  merged="$current"
  for feature in nesting=1 keyctl=1; do
    if [[ ",$merged," != *",$feature,"* ]]; then
      merged+="${merged:+,}$feature"
    fi
  done
  [[ "$merged" == "$current" ]] && return 0

  state=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
  [[ "$state" == running ]] && was_running=1
  log "Enabling LXC features required by Termix nested Docker: $merged"
  if ((was_running)); then
    pct stop "$CTID" >>"$LOG_FILE" 2>&1
  fi
  pct set "$CTID" --features "$merged" >>"$LOG_FILE" 2>&1
  if ((was_running)); then
    pct start "$CTID" >>"$LOG_FILE" 2>&1
    local attempts=0
    until pct exec "$CTID" -- true >/dev/null 2>&1; do
      sleep 2
      ((attempts += 1))
      if ((attempts >= 30)); then
        show_error_details "LXC $CTID did not become ready after enabling Termix container features."
        return 1
      fi
    done
  fi
}

provision_container() {
  local rc=0
  PROVISION_WARNING=""
  if [[ "$FILE_MANAGER_ENABLED" == "1" && "$FILE_MANAGER_PORT" == "$CODE_SERVER_PORT" ]]; then
    show_error_details "FileBrowser Quantum and code-server cannot use the same TCP port: $CODE_SERVER_PORT"
    return 1
  fi
  if [[ "$TERMIX_ENABLED" == "1" && ( "$TERMIX_PORT" == "$CODE_SERVER_PORT" || ( "$FILE_MANAGER_ENABLED" == "1" && "$TERMIX_PORT" == "$FILE_MANAGER_PORT" ) ) ]]; then
    show_error_details "Termix must use a different TCP port from code-server and FileBrowser Quantum."
    return 1
  fi
  ensure_termix_lxc_features || return 1
  PROVISION_RUN_ID="$(date +%Y%m%d-%H%M%S)-${CTID}-$$-$RANDOM"
  log "Starting LXC provisioning run $PROVISION_RUN_ID"
  write_provision_files
  msg_info "Installing the headless development toolchain inside LXC $CTID…

This includes package upgrades, code-server, FileBrowser Quantum, Termix, selected AI coding agents, Python, Robot Framework, GitHub CLI, helper commands, and smoke tests."

  set +e
  run_provision_with_progress
  rc=$?
  set -e

  if ((rc == 20)); then
    PROVISION_WARNING=$(pct exec "$CTID" -- bash -lc       'printf "The environment is operational, but these selected AI agents failed to install: "; paste -sd", " /var/log/ai-agent-install-failures 2>/dev/null || true'       2>/dev/null || true)
    pct exec "$CTID" -- bash -lc 'p=$(cat /run/ai-dev-provision.log-path 2>/dev/null || readlink -f /var/log/claude-dev-provision.log 2>/dev/null || true); printf \"=== Current LXC provision log: %s ===\\n\" \"${p:-unavailable}\"; [[ -n $p && -f $p ]] && tail -n 120 \"$p\"' >>"$LOG_FILE" 2>&1 || true
  elif ((rc != 0)); then
    pct exec "$CTID" -- bash -lc 'p=$(cat /run/ai-dev-provision.log-path 2>/dev/null || readlink -f /var/log/claude-dev-provision.log 2>/dev/null || true); printf \"=== Current LXC provision log: %s ===\\n\" \"${p:-unavailable}\"; [[ -n $p && -f $p ]] && tail -n 160 \"$p\"' >>"$LOG_FILE" 2>&1 || true
    if ((rc == 124)); then
      show_error_details "Provisioning run $PROVISION_RUN_ID inside LXC $CTID exceeded the 90-minute watchdog. The container was left intact. Review the final displayed stage and logs before retrying."
    else
      show_error_details "Provisioning run $PROVISION_RUN_ID failed inside LXC $CTID. The container was left intact for diagnosis."
    fi
    return 1
  fi

  pct exec "$CTID" -- rm -f /root/claude-dev-provision.sh /root/claude-dev.env >/dev/null 2>&1 || true
  pct set "$CTID" --protection 1 >>"$LOG_FILE" 2>&1

  verify_web_ide_access || return 1
  verify_file_manager_access || return 1
  verify_termix_access
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

verify_web_ide_access() {
  local ip=""
  local health_url=""
  local response=""
  local attempt=0

  log "Verifying code-server inside LXC $CTID"
  if ! pct exec "$CTID" -- /usr/local/bin/web-ide-status --check >>"$LOG_FILE" 2>&1; then
    pct exec "$CTID" -- /usr/local/bin/web-ide-status >>"$LOG_FILE" 2>&1 || true
    show_error_details "code-server failed its internal service, listener, or HTTP health verification in LXC $CTID. The container was left intact for diagnosis."
    return 1
  fi

  if [[ "$ACCESS_MODE" != "lan" ]]; then
    log "code-server internal verification passed in tunnel mode"
    return 0
  fi

  ip=$(wait_for_ct_ipv4 || true)
  if [[ -z "$ip" ]]; then
    show_error_details "code-server is healthy inside LXC $CTID, but the container IPv4 address could not be detected."
    return 1
  fi

  health_url="http://$ip:$CODE_SERVER_PORT/healthz"
  log "Verifying direct LAN access from the Proxmox host: $health_url"
  for attempt in $(seq 1 20); do
    response=$(curl -fsS --max-time 4 "$health_url" 2>>"$LOG_FILE" || true)
    if [[ "$response" == *'"status"'* ]]; then
      log "Direct LAN HTTP verification passed: $response"
      return 0
    fi
    sleep 1
  done

  {
    echo "Direct LAN HTTP verification failed: $health_url"
    echo "Container configuration:"
    pct config "$CTID" || true
    echo
    echo "Container web status:"
    pct exec "$CTID" -- /usr/local/bin/web-ide-status || true
    echo
    echo "Container routes:"
    pct exec "$CTID" -- ip route || true
    echo
    echo "Proxmox firewall status:"
    command -v pve-firewall >/dev/null 2>&1 && pve-firewall status || true
  } >>"$LOG_FILE" 2>&1

  show_error_details "code-server is running inside LXC $CTID, but it is not reachable from the Proxmox host at:

$health_url

Check the LXC network address, bridge/VLAN, and Proxmox firewall rules for TCP port $CODE_SERVER_PORT. Run the helper's Web IDE verification action after correcting the network policy."
  return 1
}

verify_file_manager_access() {
  local ip="" health_url="" response="" attempt=0
  if [[ "$FILE_MANAGER_ENABLED" != "1" ]]; then
    log "FileBrowser Quantum is disabled; skipping verification"
    return 0
  fi

  log "Verifying FileBrowser Quantum inside LXC $CTID"
  if ! pct exec "$CTID" -- /usr/local/bin/file-manager-status --check >>"$LOG_FILE" 2>&1; then
    pct exec "$CTID" -- /usr/local/bin/file-manager-status >>"$LOG_FILE" 2>&1 || true
    show_error_details "FileBrowser Quantum failed its internal service, listener, or HTTP health verification in LXC $CTID."
    return 1
  fi

  ip=$(wait_for_ct_ipv4 || true)
  if [[ -z "$ip" ]]; then
    show_error_details "FileBrowser Quantum is healthy inside LXC $CTID, but the container IPv4 address could not be detected."
    return 1
  fi
  health_url="http://$ip:$FILE_MANAGER_PORT/health"
  local root_url="http://$ip:$FILE_MANAGER_PORT/" code="000"
  log "Verifying FileBrowser Quantum from the Proxmox host: $health_url"
  for attempt in $(seq 1 40); do
    response=$(curl -fsS --max-time 4 "$health_url" 2>>"$LOG_FILE" || true)
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 4 "$root_url" 2>>"$LOG_FILE" || printf '000')
    if [[ -n "$response" || "$code" =~ ^(200|301|302|303|307|308|401|403)$ ]]; then
      log "FileBrowser Quantum LAN verification passed: health=${response:-unavailable}, root_http=$code"
      return 0
    fi
    sleep 1
  done

  {
    echo "FileBrowser Quantum diagnostics for LXC $CTID"
    pct exec "$CTID" -- file-manager-status || true
    pct exec "$CTID" -- journalctl -u filebrowser-quantum.service -n 80 --no-pager || true
    pct config "$CTID" || true
  } >>"$LOG_FILE" 2>&1

  show_error_details "FileBrowser Quantum is running inside LXC $CTID, but it is not reachable from the Proxmox host at:

$health_url
or:
http://$ip:$FILE_MANAGER_PORT/

Check the FileBrowser service journal, configured listener, bridge, VLAN, LXC address, and Proxmox firewall policy for TCP port $FILE_MANAGER_PORT."
  return 1
}

verify_termix_access() {
  local ip="" url="" code="" attempt=0
  if [[ "$TERMIX_ENABLED" != "1" ]]; then
    log "Termix is disabled; skipping verification"
    return 0
  fi
  log "Verifying Termix inside LXC $CTID"
  if ! pct exec "$CTID" -- /usr/local/bin/termix-status --check >>"$LOG_FILE" 2>&1; then
    pct exec "$CTID" -- /usr/local/bin/termix-status >>"$LOG_FILE" 2>&1 || true
    pct exec "$CTID" -- docker logs --tail 120 termix >>"$LOG_FILE" 2>&1 || true
    show_error_details "Termix failed its Docker, container, listener, or HTTP verification in LXC $CTID."
    return 1
  fi
  ip=$(wait_for_ct_ipv4 || true)
  [[ -n $ip ]] || { show_error_details "Termix is healthy inside LXC $CTID, but its IPv4 address could not be detected."; return 1; }
  url="http://$ip:$TERMIX_PORT/"
  log "Verifying Termix from the Proxmox host: $url"
  for attempt in $(seq 1 30); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "$url" 2>>"$LOG_FILE" || true)
    [[ $code =~ ^(2|3)[0-9][0-9]$ ]] && { log "Termix LAN verification passed with HTTP $code"; return 0; }
    sleep 2
  done
  {
    echo "Termix diagnostics for LXC $CTID"
    pct exec "$CTID" -- termix-status || true
    pct exec "$CTID" -- docker logs --tail 120 termix || true
    pct config "$CTID" || true
  } >>"$LOG_FILE" 2>&1
  show_error_details "Termix is running inside LXC $CTID, but it is not reachable from the Proxmox host at:\n\n$url\n\nCheck TCP port $TERMIX_PORT, bridge/VLAN configuration, and Proxmox firewall policy."
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
    printf 'FILE_MANAGER_ENABLED=%q\n' "$FILE_MANAGER_ENABLED"
    printf 'FILE_MANAGER_PORT=%q\n' "$FILE_MANAGER_PORT"
    printf 'FILE_MANAGER_PASSWORD=%q\n' "$FILE_MANAGER_PASSWORD"
    printf 'TERMIX_ENABLED=%q\n' "$TERMIX_ENABLED"
    printf 'TERMIX_PORT=%q\n' "$TERMIX_PORT"
    printf 'TERMIX_IMAGE=%q\n' "$TERMIX_IMAGE"
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
    echo "Web files:    $([[ "$FILE_MANAGER_ENABLED" == "1" ]] && echo enabled || echo disabled)"
    echo "Termix:       $([[ "$TERMIX_ENABLED" == "1" ]] && echo enabled || echo disabled)"
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
    if [[ "$FILE_MANAGER_ENABLED" == "1" ]]; then
      echo
      echo "Web file manager: http://${ip:-CONTAINER_IP}:${FILE_MANAGER_PORT}"
      echo "Web file manager user: admin"
      echo "Web file manager password: $FILE_MANAGER_PASSWORD"
      echo "Managed directory: /srv/workspace"
    fi
    if [[ "$TERMIX_ENABLED" == "1" ]]; then
      echo
      echo "Termix: http://${ip:-CONTAINER_IP}:${TERMIX_PORT}"
      echo "Complete the administrator setup in the browser on first access."
      echo "To add this LXC as an SSH host from Termix, use host.docker.internal:22."
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
Web IDE check: PASS
Web file manager check: $([[ "$FILE_MANAGER_ENABLED" == "1" ]] && echo PASS || echo disabled)
Termix check: $([[ "$TERMIX_ENABLED" == "1" ]] && echo PASS || echo disabled)
${DEV_PASSWORD:+Initial SSH password: $DEV_PASSWORD
}
$access_text

$([[ "$FILE_MANAGER_ENABLED" == "1" ]] && printf "Web file manager:\nhttp://%s:%s\nUser: admin\nPassword: %s\nManaged path: /srv/workspace\n" "${ip:-CONTAINER_IP}" "$FILE_MANAGER_PORT" "$FILE_MANAGER_PASSWORD")
$([[ "$TERMIX_ENABLED" == "1" ]] && printf "Termix:\nhttp://%s:%s\nCreate the administrator account on first access.\nUse host.docker.internal:22 to connect back to this LXC.\n" "${ip:-CONTAINER_IP}" "$TERMIX_PORT")

After SSH login, run:
  web-ide-status
  file-manager-status
  termix-status
  keyring-status
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

  load_defaults || return 0
  mode=$(menu_box "INSTALLATION MODE" \
    "Choose a configuration mode." \
    "default" "Recommended infrastructure defaults plus AI-agent selection" \
    "advanced" "Configure resources and access; CTID remains automatic" \
    "cancel" "Return to the main menu") || return 0

  case "$mode" in
    default) configure_default_mode || return 0 ;;
    advanced) configure_advanced_mode || return 0 ;;
    *) return 0 ;;
  esac

  # Re-check immediately before confirmation in case another task allocated
  # the previously selected ID while the user completed the wizard.
  refresh_new_ctid || return 0

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
  FILE_MANAGER_ENABLED="1"
  FILE_MANAGER_PORT="$DEFAULT_FILE_MANAGER_PORT"
  FILE_MANAGER_PASSWORD=""
  TERMIX_ENABLED="0"
  TERMIX_PORT="$DEFAULT_TERMIX_PORT"
  TERMIX_IMAGE="ghcr.io/lukegus/termix:latest"
  # shellcheck disable=SC1090
  source "$state_file"
  if [[ "$FILE_MANAGER_ENABLED" == "1" && -z "$FILE_MANAGER_PASSWORD" ]]; then
    FILE_MANAGER_PASSWORD=$(openssl rand -hex 16)
  fi
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

  if ask_yes_no "WEB IDE ACCESS" \
    "Current Web IDE mode: $ACCESS_MODE
Current port: $CODE_SERVER_PORT

Change the code-server access mode or TCP port?" no; then
    local web_choice
    web_choice=$(menu_box "WEB IDE ACCESS" \
      "Choose how code-server will be exposed." \
      "lan" "Direct LXC IP access with password authentication" \
      "tunnel" "Loopback only; connect through an SSH tunnel") || return 0
    ACCESS_MODE=$web_choice
    prompt_integer CODE_SERVER_PORT "WEB IDE PORT" "code-server TCP port:" "$CODE_SERVER_PORT" 1024 65535 || return 0
    if [[ "$ACCESS_MODE" == "lan" && -z "$CODE_SERVER_PASSWORD" ]]; then
      CODE_SERVER_PASSWORD=$(openssl rand -hex 16)
    elif [[ "$ACCESS_MODE" == "tunnel" ]]; then
      CODE_SERVER_PASSWORD=""
    fi
  fi

  if ask_yes_no "WEB FILE MANAGER"     "Current FileBrowser Quantum state: $([[ "$FILE_MANAGER_ENABLED" == "1" ]] && echo enabled || echo disabled)
Current port: $FILE_MANAGER_PORT
Managed directory: /srv/workspace

Change the web file-manager setting or TCP port?" no; then
    if ask_yes_no "WEB FILE MANAGER" "Enable FileBrowser Quantum with password authentication?" yes; then
      FILE_MANAGER_ENABLED="1"
      prompt_integer FILE_MANAGER_PORT "FILE MANAGER PORT"         "FileBrowser Quantum TCP port:" "$FILE_MANAGER_PORT" 1024 65535 || return 0
      if [[ "$FILE_MANAGER_PORT" == "$CODE_SERVER_PORT" ]]; then
        msg_warn "The web file manager and code-server cannot use the same TCP port."
        return 0
      fi
      [[ -n "$FILE_MANAGER_PASSWORD" ]] || FILE_MANAGER_PASSWORD=$(openssl rand -hex 16)
    else
      FILE_MANAGER_ENABLED="0"
    fi
  fi

  if ask_yes_no "TERMIX WEB TERMINAL"     "Current Termix state: $([[ "$TERMIX_ENABLED" == "1" ]] && echo enabled || echo disabled)
Current port: $TERMIX_PORT

Change the Termix setting or TCP port?" no; then
    if ask_yes_no "TERMIX WEB TERMINAL" "Enable Termix with browser-based SSH terminal access?" yes; then
      TERMIX_ENABLED="1"
      prompt_integer TERMIX_PORT "TERMIX PORT" "Termix TCP port:" "$TERMIX_PORT" 1024 65535 || return 0
      if [[ "$TERMIX_PORT" == "$CODE_SERVER_PORT" || ( "$FILE_MANAGER_ENABLED" == "1" && "$TERMIX_PORT" == "$FILE_MANAGER_PORT" ) ]]; then
        msg_warn "Termix must use a different TCP port from code-server and FileBrowser Quantum."
        return 0
      fi
    else
      TERMIX_ENABLED="0"
    fi
  fi

  if ! ask_yes_no "UPDATE / REPAIR" \
    "Re-run the idempotent provisioning process in LXC $CTID?

This updates Debian packages, code-server, Python tooling, Robot Framework,
RobotCode, FileBrowser Quantum, Termix, selected AI agents, helper commands, extensions, and the starter workspace.
Existing projects under /srv/workspace are preserved.

Selected agents: $(selected_agents_display)
Web file manager: $([[ "$FILE_MANAGER_ENABLED" == "1" ]] && echo "enabled on port $FILE_MANAGER_PORT" || echo disabled)
Termix: $([[ "$TERMIX_ENABLED" == "1" ]] && echo "enabled on port $TERMIX_PORT" || echo disabled)" yes; then
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
    ACCESS_MODE="lan"
    CODE_SERVER_PORT="$DEFAULT_PORT"
    CODE_SERVER_PASSWORD=$(openssl rand -hex 16)
  fi

  detected_agents=$(pct exec "$CTID" -- bash -lc \
    'if [[ -r /etc/ai-agent-selection ]]; then source /etc/ai-agent-selection; printf "%s" "${SELECTED_AGENTS:-}"; fi' \
    2>/dev/null || true)
  SELECTED_AGENTS=${detected_agents:-claude}
  FILE_MANAGER_ENABLED=$(pct exec "$CTID" -- bash -lc     'if [[ -r /etc/ai-development-file-manager.env ]]; then source /etc/ai-development-file-manager.env; printf "%s" "${FILE_MANAGER_ENABLED:-0}"; else printf 0; fi'     2>/dev/null || echo 0)
  FILE_MANAGER_PORT=$(pct exec "$CTID" -- bash -lc     'if [[ -r /etc/ai-development-file-manager.env ]]; then source /etc/ai-development-file-manager.env; printf "%s" "${FILE_MANAGER_PORT:-8081}"; else printf 8081; fi'     2>/dev/null || echo 8081)
  if [[ "$FILE_MANAGER_ENABLED" != "1" ]]; then
    FILE_MANAGER_ENABLED="1"
  fi
  FILE_MANAGER_PASSWORD=$(openssl rand -hex 16)
  TERMIX_ENABLED=$(pct exec "$CTID" -- bash -lc 'if [[ -r /etc/ai-development-termix.env ]]; then source /etc/ai-development-termix.env; printf "%s" "${TERMIX_ENABLED:-0}"; elif docker inspect termix >/dev/null 2>&1; then printf 1; else printf 0; fi' 2>/dev/null || echo 0)
  TERMIX_PORT=$(pct exec "$CTID" -- bash -lc 'if [[ -r /etc/ai-development-termix.env ]]; then source /etc/ai-development-termix.env; printf "%s" "${TERMIX_PORT:-8082}"; else printf 8082; fi' 2>/dev/null || echo 8082)
  TERMIX_IMAGE="ghcr.io/lukegus/termix:latest"

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
Web files: enabled on port $FILE_MANAGER_PORT
Termix: $([[ "$TERMIX_ENABLED" == "1" ]] && echo "enabled on port $TERMIX_PORT" || echo disabled)
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
Web files:    $([[ "$FILE_MANAGER_ENABLED" == "1" ]] && echo "http://${ip:-CONTAINER_IP}:$FILE_MANAGER_PORT (admin / $FILE_MANAGER_PASSWORD)" || echo disabled)
Termix:       $([[ "$TERMIX_ENABLED" == "1" ]] && echo "http://${ip:-CONTAINER_IP}:$TERMIX_PORT" || echo disabled)

Web IDE access:
$access

Useful host commands:
pct enter $CTID
pct exec $CTID -- web-ide-status
pct exec $CTID -- file-manager-status
pct exec $CTID -- termix-status
pct exec $CTID -- docker logs --tail 100 termix
pct exec $CTID -- systemctl status filebrowser-quantum.service
pct exec $CTID -- keyring-status
pct exec $CTID -- systemctl status code-server@$DEV_USER
pct exec $CTID -- tail -n 100 /var/log/claude-dev-provision.log

State file:
$STATE_DIR/$CTID.conf" 25 88
}

verify_managed_web_ide() {
  local id
  local ip
  id=$(select_managed_ctid "Select a container whose web IDE should be verified.") || return 0
  load_state "$id"
  CTID=$id

  if [[ "$(pct status "$CTID" 2>/dev/null | awk '{print $2}')" != "running" ]]; then
    msg_warn "LXC $CTID is not running. Start it before verification."
    return 0
  fi

  if verify_web_ide_access && verify_file_manager_access && verify_termix_access; then
    ip=$(get_ct_ipv4)
    if [[ "$ACCESS_MODE" == "lan" ]]; then
      whiptail --backtitle "$BACKTITLE" --title "WEB IDE VERIFIED" --msgbox \
        "code-server service, listener, internal HTTP health, and Proxmox-host LAN access passed. FileBrowser Quantum and Termix were also checked when enabled.\n\nOpen:\nhttp://${ip:-CONTAINER_IP}:${CODE_SERVER_PORT}" 14 78
    else
      whiptail --backtitle "$BACKTITLE" --title "WEB IDE VERIFIED" --msgbox \
        "code-server service, loopback listener, and internal HTTP health passed. FileBrowser Quantum and Termix were also checked when enabled.\n\nThis container is configured for SSH-tunnel access on port $CODE_SERVER_PORT." 14 78
    fi
  fi
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
      "1" "Create a new LXC (next free CTID selected automatically)" \
      "2" "Update or repair a managed development LXC" \
      "3" "Adopt and repair an incomplete existing LXC" \
      "4" "Verify Web IDE, file manager, and Termix HTTP access" \
      "5" "Show access and status information" \
      "6" "Open a managed container console" \
      "7" "Show this run's log file" \
      "8" "Exit") || break

    case "$choice" in
      1) new_installation ;;
      2) update_managed_container ;;
      3) adopt_existing_container ;;
      4) verify_managed_web_ide ;;
      5) show_managed_info ;;
      6) open_container_shell ;;
      7)
        whiptail --backtitle "$BACKTITLE" --title "RUN LOG" --scrolltext --textbox "$LOG_FILE" 30 100
        ;;
      8) break ;;
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
• Termix browser SSH terminal, host manager, tunnels, and remote files
• FileBrowser Quantum for /srv/workspace on a separate authenticated port
• GitHub Pull Requests and Issues extension for code-server
• Python and virtual environments
• Robot Framework and RobotCode
• Git and GitHub CLI
• Verified code-server, FileBrowser Quantum, and Termix services, listeners, and HTTP health checks
• GNOME Keyring, libsecret, Python keyring, pass, and headless PIN entry
• SSH access, agent-management helpers, and build tools

The script runs on the Proxmox host, selects the next free CTID automatically for new installations, and provisions the LXC." 22 82

  main_menu
  clear 2>/dev/null || true
  printf '%s finished. Log: %s\n' "$SCRIPT_NAME" "$LOG_FILE"
}

main "$@"
