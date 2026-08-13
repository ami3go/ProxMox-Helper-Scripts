#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Docker-free variant of ai-dev-claude.sh. Creates a new Proxmox VE LXC and
# provisions it with a web IDE (code-server), a web file manager
# (FileBrowser Quantum), a web terminal (ttyd), a static link dashboard,
# GitHub CLI, and Claude Code -- with no Docker, no nesting/keyctl LXC
# features, and no Termix/Homepage container images. Run as root on a
# Proxmox host.
#
# See PLAN.md in this directory (the "Docker-free variant" section) for the
# design, and README.md for usage and manual follow-up steps.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="0.1.0"
readonly BACKTITLE="AI Dev Claude (No Docker) • Proxmox VE"
readonly STATE_DIR="/etc/ai-dev-claude"
readonly LOG_DIR="/var/log/ai-dev-claude"
readonly DEFAULT_HOSTNAME="ai-dev-claude"
readonly DEFAULT_USER="dev"
readonly DEFAULT_CORES="4"
readonly DEFAULT_MEMORY="8192"
readonly DEFAULT_SWAP="2048"
readonly DEFAULT_DISK="40"
readonly DEFAULT_CODE_SERVER_PORT="8080"
readonly DEFAULT_FILE_MANAGER_PORT="8081"
readonly DEFAULT_WEB_TERMINAL_PORT="8082"
readonly DEFAULT_DASHBOARD_PORT="3000"

# ---------- Early flags that must not require root/Proxmox ----------

case "${1:-}" in
  --version|-v) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
esac

LOG_FILE=""
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
TEMPLATE_FILE=""
TEMPLATE_VOLID=""
CODE_SERVER_PORT="$DEFAULT_CODE_SERVER_PORT"
FILE_MANAGER_PORT="$DEFAULT_FILE_MANAGER_PORT"
WEB_TERMINAL_PORT="$DEFAULT_WEB_TERMINAL_PORT"
DASHBOARD_PORT="$DEFAULT_DASHBOARD_PORT"
DEV_PASSWORD=""
CODE_SERVER_PASSWORD=""
FILE_MANAGER_PASSWORD=""
TTYD_PASSWORD=""
SSH_KEY_CONTENT=""
GIT_NAME=""
GIT_EMAIL=""
ASSUME_YES=false

usage() {
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Usage: $SCRIPT_NAME [--yes] [--ctid ID] [--version] [--help]

Run as root on a Proxmox VE host. Creates a new LXC sized for Claude Code
development and installs code-server, FileBrowser Quantum, ttyd (a web
terminal), a static link dashboard, GitHub CLI, and Claude Code inside it --
no Docker anywhere, so the container needs no nesting/keyctl features.
Reboots the container once provisioning finishes, then re-verifies every
service and finalizes the dashboard with the container's real IP address.

  --yes            Fully automatic: no confirmation prompts, defaults used
  --ctid ID         Create (or re-provision) this specific CTID
  --version, -v     Print the script version and exit
  --help, -h        Show this help and exit

See PLAN.md and README.md in this script's directory for details.
EOF
}

while (($#)); do
  case "$1" in
    --yes|--non-interactive|--auto) ASSUME_YES=true; shift ;;
    --ctid) CTID=${2:?missing CTID}; shift 2 ;;
    --version|-v) printf '%s\n' "$SCRIPT_VERSION"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# ---------- Logging and small UI helpers ----------

init_logging() {
  install -d -m 0700 "$STATE_DIR" "$LOG_DIR"
  LOG_FILE="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG_FILE"
}

say() {
  printf '%s\n' "$*"
  log "$*"
}

stage() {
  printf '\n==== [%s] %s ====\n' "$(date +%T)" "$1"
  log "STAGE: $1"
}

show_error_details() {
  local message=${1:-"An unexpected error occurred."}
  echo
  echo "ERROR: $message" >&2
  if [[ -n "$LOG_FILE" && -s "$LOG_FILE" ]]; then
    echo "Recent log output:" >&2
    tail -n 25 "$LOG_FILE" | sed 's/[^[:print:]\t]//g' >&2
  fi
  echo "Full log: $LOG_FILE" >&2
}

on_error() {
  local rc=$? line=${BASH_LINENO[0]:-unknown} command=${BASH_COMMAND:-unknown}
  show_error_details "Failure at line $line (exit $rc): $command"
  exit "$rc"
}
trap on_error ERR
trap 'log "Interrupted by user"; exit 130' INT TERM

ensure_whiptail() {
  command -v whiptail >/dev/null 2>&1 && return 0
  apt-get update >>"$LOG_FILE" 2>&1
  DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail >>"$LOG_FILE" 2>&1
  command -v whiptail >/dev/null 2>&1 || { echo "whiptail is required for the configuration prompts." >&2; exit 1; }
}

ask_yes_no() {
  local title=$1 text=$2 default=${3:-yes}
  $ASSUME_YES && { [[ "$default" == yes ]]; return; }
  local option=--yesno
  [[ "$default" == no ]] && option=--defaultno
  whiptail --backtitle "$BACKTITLE" --title "$title" "$option" "$text" 16 78
}

input_box() {
  local title=$1 text=$2 default=${3:-}
  $ASSUME_YES && { printf '%s' "$default"; return; }
  whiptail --backtitle "$BACKTITLE" --title "$title" --inputbox "$text" 12 78 "$default" 3>&1 1>&2 2>&3
}

msg_info() {
  $ASSUME_YES || { whiptail --backtitle "$BACKTITLE" --title "PLEASE WAIT" --infobox "$1" 8 72; sleep 0.1; }
  log "INFO: $1"
}

msg_warn() {
  $ASSUME_YES || whiptail --backtitle "$BACKTITLE" --title "WARNING" --msgbox "$1" 12 76
  log "WARNING: $1"
}

is_integer_range() { local v=$1 min=$2 max=$3; [[ "$v" =~ ^[0-9]+$ ]] && ((v >= min && v <= max)); }
valid_hostname() { local v=$1; [[ ${#v} -le 63 && "$v" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; }
valid_username() { local v=$1; [[ "$v" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]; }

prompt_validated() {
  local var=$1 title=$2 prompt=$3 default=$4 validator=$5 error=$6
  $ASSUME_YES && { printf -v "$var" '%s' "$default"; return 0; }
  local value
  while true; do
    value=$(input_box "$title" "$prompt" "$default") || return 1
    if "$validator" "$value"; then printf -v "$var" '%s' "$value"; return 0; fi
    msg_warn "$error"
  done
}

prompt_integer() {
  local var=$1 title=$2 prompt=$3 default=$4 min=$5 max=$6
  $ASSUME_YES && { printf -v "$var" '%s' "$default"; return 0; }
  local value
  while true; do
    value=$(input_box "$title" "$prompt"$'\n\n'"Allowed range: $min-$max" "$default") || return 1
    if is_integer_range "$value" "$min" "$max"; then printf -v "$var" '%s' "$value"; return 0; fi
    msg_warn "Enter a whole number between $min and $max."
  done
}

# ---------- Proxmox discovery ----------

check_proxmox_host() {
  local required=(pveversion pct pvesm pveam pvesh ip awk sed grep openssl) missing=() cmd
  for cmd in "${required[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
  if ((${#missing[@]})); then
    echo "This script must run on a Proxmox VE host. Missing commands: ${missing[*]}" >&2
    exit 1
  fi
  log "Host version: $(pveversion 2>/dev/null || true)"
}

next_ctid() {
  local candidate
  candidate=$(pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9')
  [[ "$candidate" =~ ^[0-9]+$ ]] && ((candidate >= 100)) || candidate=100
  while pct status "$candidate" >/dev/null 2>&1; do ((candidate += 1)); done
  printf '%s\n' "$candidate"
}

list_template_storages() { pvesm status --content vztmpl 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}'; }
list_rootfs_storages() { pvesm status --content rootdir 2>/dev/null | awk 'NR>1 && $3=="active"{print $1}'; }
list_bridges() { ip -o link show 2>/dev/null | awk -F': ' '$2 ~ /^vmbr[[:alnum:]_.-]*$/{print $2}'; }

select_default_storage() {
  local preferred=$1; shift
  local entry
  for entry in "$@"; do [[ "$entry" == "$preferred" ]] && { printf '%s' "$entry"; return; }; done
  printf '%s' "${1:-}"
}

ensure_template_downloaded() {
  local arch
  arch=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  msg_info "Refreshing the Proxmox appliance-template index..."
  timeout --foreground 10m pveam update >>"$LOG_FILE" 2>&1 || true

  TEMPLATE_FILE=$(pveam available --section system 2>/dev/null \
    | awk -v arch="$arch" '$2 ~ /^debian-(13|12)-standard_/ && $2 ~ arch {print $2}' \
    | sort -V | tail -n1)
  if [[ -z "$TEMPLATE_FILE" ]]; then
    TEMPLATE_FILE=$(pveam available --section system 2>/dev/null \
      | awk '$2 ~ /^debian-.*-standard_/{print $2}' | sort -V | tail -n1)
  fi
  [[ -n "$TEMPLATE_FILE" ]] || { echo "No Debian standard LXC template found." >&2; exit 1; }
  TEMPLATE_VOLID="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_FILE}"

  if pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR>1{print $1}' | grep -Fxq "$TEMPLATE_VOLID"; then
    log "Template already present: $TEMPLATE_VOLID"
    return 0
  fi
  msg_info "Downloading $TEMPLATE_FILE to $TEMPLATE_STORAGE..."
  timeout --foreground 30m pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_FILE" >>"$LOG_FILE" 2>&1
}

get_ct_ipv4() {
  pct exec "$CTID" -- bash -lc "hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+(\.[0-9]+){3}\$'" 2>/dev/null || true
}

wait_for_ct_ready() {
  local i
  for i in $(seq 1 60); do pct exec "$CTID" -- true >/dev/null 2>&1 && return 0; sleep 2; done
  return 1
}

wait_for_ct_ipv4() {
  local ip="" count=0
  while ((count < 30)); do
    ip=$(get_ct_ipv4)
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
    sleep 2; ((count += 1))
  done
  return 1
}

# ---------- Configuration ----------

gather_configuration() {
  next_ctid_value=$(next_ctid)
  [[ -n "$CTID" ]] || CTID="$next_ctid_value"

  mapfile -t template_storages < <(list_template_storages)
  mapfile -t rootfs_storages < <(list_rootfs_storages)
  mapfile -t bridges < <(list_bridges)
  TEMPLATE_STORAGE=$(select_default_storage local "${template_storages[@]}"); [[ -n "$TEMPLATE_STORAGE" ]] || TEMPLATE_STORAGE="local"
  ROOTFS_STORAGE=$(select_default_storage local-lvm "${rootfs_storages[@]}"); [[ -n "$ROOTFS_STORAGE" ]] || ROOTFS_STORAGE="local-lvm"
  BRIDGE=$(select_default_storage vmbr0 "${bridges[@]}"); [[ -n "$BRIDGE" ]] || BRIDGE="vmbr0"

  if ! $ASSUME_YES; then
    if ! ask_yes_no "AI DEV CLAUDE (NO DOCKER)" \
      "Create a new LXC (CTID $CTID) sized for Claude Code development?

Defaults: $DEFAULT_CORES cores / ${DEFAULT_MEMORY} MiB RAM / ${DEFAULT_SWAP} MiB swap / ${DEFAULT_DISK} GiB disk, DHCP on $BRIDGE.

Choose No to customize hostname, dev user, sizing, and ports first." yes; then
      prompt_validated CT_HOSTNAME "HOSTNAME" "Container hostname:" "$CT_HOSTNAME" valid_hostname \
        "Use a valid DNS-style hostname without spaces." || exit 0
      prompt_validated DEV_USER "DEV USER" "Linux development username:" "$DEV_USER" valid_username \
        "Use a lowercase Linux username." || exit 0
      prompt_integer CORES "CPU" "CPU cores:" "$CORES" 1 64 || exit 0
      prompt_integer MEMORY "MEMORY" "RAM in MiB:" "$MEMORY" 1024 262144 || exit 0
      prompt_integer SWAP "SWAP" "Swap in MiB:" "$SWAP" 0 65536 || exit 0
      prompt_integer DISK_SIZE "DISK" "Root disk in GiB:" "$DISK_SIZE" 16 2048 || exit 0
      prompt_integer CODE_SERVER_PORT "WEB IDE PORT" "code-server TCP port:" "$CODE_SERVER_PORT" 1024 65535 || exit 0
      prompt_integer FILE_MANAGER_PORT "FILE MANAGER PORT" "FileBrowser Quantum TCP port:" "$FILE_MANAGER_PORT" 1024 65535 || exit 0
      prompt_integer WEB_TERMINAL_PORT "WEB TERMINAL PORT" "ttyd TCP port:" "$WEB_TERMINAL_PORT" 1024 65535 || exit 0
      prompt_integer DASHBOARD_PORT "DASHBOARD PORT" "Static dashboard TCP port:" "$DASHBOARD_PORT" 1024 65535 || exit 0
    fi
    if ask_yes_no "GIT IDENTITY" "Configure a global Git author name and email for '$DEV_USER'?" no; then
      GIT_NAME=$(input_box "GIT AUTHOR" "Git author name:" "") || true
      GIT_EMAIL=$(input_box "GIT EMAIL" "Git author email:" "") || true
    fi
  fi

  if [[ "$CODE_SERVER_PORT" == "$FILE_MANAGER_PORT" || "$CODE_SERVER_PORT" == "$WEB_TERMINAL_PORT" || "$CODE_SERVER_PORT" == "$DASHBOARD_PORT" \
     || "$FILE_MANAGER_PORT" == "$WEB_TERMINAL_PORT" || "$FILE_MANAGER_PORT" == "$DASHBOARD_PORT" || "$WEB_TERMINAL_PORT" == "$DASHBOARD_PORT" ]]; then
    show_error_details "code-server, FileBrowser Quantum, ttyd, and the dashboard must each use a different TCP port."
    exit 1
  fi

  DEV_PASSWORD=$(openssl rand -hex 12)
  CODE_SERVER_PASSWORD=$(openssl rand -hex 16)
  FILE_MANAGER_PASSWORD=$(openssl rand -hex 16)
  TTYD_PASSWORD=$(openssl rand -hex 16)
  if [[ -s /root/.ssh/authorized_keys ]]; then
    if $ASSUME_YES || ask_yes_no "SSH KEY" \
      "Reuse the public keys from /root/.ssh/authorized_keys for the container's '$DEV_USER' account?" yes; then
      SSH_KEY_CONTENT=$(cat /root/.ssh/authorized_keys)
    fi
  fi

  if ! $ASSUME_YES; then
    whiptail --backtitle "$BACKTITLE" --title "CONFIRM DEPLOYMENT" --yesno \
      "Container ID:     $CTID
Hostname:          $CT_HOSTNAME
Dev user:          $DEV_USER
CPU / RAM / swap:  $CORES cores / ${MEMORY} MiB / ${SWAP} MiB
Root disk:         ${DISK_SIZE} GiB on $ROOTFS_STORAGE
Network:           DHCP on $BRIDGE
SSH:               generated password$([[ -n "$SSH_KEY_CONTENT" ]] && printf ' + host authorized_keys')

Web IDE (code-server):        port $CODE_SERVER_PORT
File manager (FileBrowser):   port $FILE_MANAGER_PORT
Web terminal (ttyd):          port $WEB_TERMINAL_PORT
Dashboard (static page):      port $DASHBOARD_PORT

Also installs: GitHub CLI, Claude Code. No Docker, no nesting/keyctl
features -- everything runs as plain systemd services.
The container will reboot once, then a finalize pass verifies every
service and updates the dashboard with the confirmed IP address.

Create LXC $CTID now?" 28 88
  fi
}

# ---------- Container creation ----------

create_container() {
  if pct status "$CTID" >/dev/null 2>&1; then
    say "LXC $CTID already exists; re-provisioning it in place."
    return 0
  fi
  ensure_template_downloaded
  local net0="name=eth0,bridge=$BRIDGE,type=veth,firewall=1,ip=dhcp"
  say "Creating unprivileged Debian LXC $CTID ($CORES cores / ${MEMORY} MiB / ${DISK_SIZE} GiB)..."
  pct create "$CTID" "$TEMPLATE_VOLID" \
    --hostname "$CT_HOSTNAME" \
    --ostype debian \
    --unprivileged 1 \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "${ROOTFS_STORAGE}:${DISK_SIZE}" \
    --net0 "$net0" \
    --onboot 1 \
    --startup "order=20,up=30" \
    --tags "development;claude;ai-dev-claude;no-docker" \
    >>"$LOG_FILE" 2>&1
}

start_container() {
  if [[ "$(pct status "$CTID" | awk '{print $2}')" != running ]]; then
    say "Starting LXC $CTID..."
    pct start "$CTID" >>"$LOG_FILE" 2>&1
  fi
  wait_for_ct_ready || { show_error_details "LXC $CTID did not become ready in time."; exit 1; }
}

# ---------- Provisioning payload ----------
# Built as two files: a small env file (host values, safely quoted) and a
# provisioning script. The provisioning script is a single-quoted heredoc so
# it is pushed byte-for-byte with no host-side expansion; it sources the env
# file as its first action. This avoids the class of quoting bug where a
# remote command built by string-interpolating a bash -lc argument silently
# breaks (see the ai-dev-lxc CHANGELOG/history for exactly that bug).

write_env_file() {
  local target=$1
  {
    printf 'DEV_USER=%q\n' "$DEV_USER"
    printf 'CODE_SERVER_PORT=%q\n' "$CODE_SERVER_PORT"
    printf 'FILE_MANAGER_PORT=%q\n' "$FILE_MANAGER_PORT"
    printf 'WEB_TERMINAL_PORT=%q\n' "$WEB_TERMINAL_PORT"
    printf 'DASHBOARD_PORT=%q\n' "$DASHBOARD_PORT"
    printf 'DEV_PASSWORD=%q\n' "$DEV_PASSWORD"
    printf 'CODE_SERVER_PASSWORD=%q\n' "$CODE_SERVER_PASSWORD"
    printf 'FILE_MANAGER_PASSWORD=%q\n' "$FILE_MANAGER_PASSWORD"
    printf 'TTYD_PASSWORD=%q\n' "$TTYD_PASSWORD"
    printf 'SSH_KEY_CONTENT=%q\n' "$SSH_KEY_CONTENT"
    printf 'GIT_NAME=%q\n' "$GIT_NAME"
    printf 'GIT_EMAIL=%q\n' "$GIT_EMAIL"
  } >"$target"
  chmod 0600 "$target"
}

write_provision_script() {
  cat >"$1" <<'PROVISION'
#!/usr/bin/env bash
set -Eeuo pipefail
source /root/ai-dev-claude.env
DEV_HOME="/home/$DEV_USER"
PROVISION_STARTED_AT=$(date -Is)

stage() { printf '\n==== [%s] %s ====\n' "$(date +%T)" "$1"; }

stage "1/8: Base packages, development user, SSH, workspace"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get -y upgrade
apt-get install -y \
  sudo openssh-server ca-certificates curl wget git gh gnupg lsb-release \
  build-essential python3 python3-pip unzip zip jq tmux nano vim ripgrep \
  apt-transport-https
systemctl enable --now ssh

id "$DEV_USER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$DEV_USER"
usermod -aG sudo "$DEV_USER"
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DEV_USER" >"/etc/sudoers.d/90-$DEV_USER"
chmod 0440 "/etc/sudoers.d/90-$DEV_USER"
[[ -n "$DEV_PASSWORD" ]] && printf '%s:%s\n' "$DEV_USER" "$DEV_PASSWORD" | chpasswd

install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "$DEV_HOME/.ssh"
if [[ -n "$SSH_KEY_CONTENT" ]]; then
  printf '%s\n' "$SSH_KEY_CONTENT" >>"$DEV_HOME/.ssh/authorized_keys"
  chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.ssh/authorized_keys"
  chmod 0600 "$DEV_HOME/.ssh/authorized_keys"
fi
install -d -m 0755 -o "$DEV_USER" -g "$DEV_USER" /srv/workspace

if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
  runuser -u "$DEV_USER" -- git config --global user.name "$GIT_NAME"
  runuser -u "$DEV_USER" -- git config --global user.email "$GIT_EMAIL"
fi
runuser -u "$DEV_USER" -- git config --global init.defaultBranch main
runuser -u "$DEV_USER" -- git config --global --add safe.directory /srv/workspace

stage "2/8: Installing and verifying code-server (web IDE)"
curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 300 \
  https://code-server.dev/install.sh -o /tmp/install-code-server.sh
timeout --foreground 15m sh /tmp/install-code-server.sh
rm -f /tmp/install-code-server.sh

install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "$DEV_HOME/.config/code-server"
cat >"$DEV_HOME/.config/code-server/config.yaml" <<EOF
bind-addr: 0.0.0.0:$CODE_SERVER_PORT
auth: password
password: $CODE_SERVER_PASSWORD
cert: false
disable-telemetry: true
EOF
chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.config/code-server/config.yaml"
chmod 0600 "$DEV_HOME/.config/code-server/config.yaml"
systemctl enable --now "code-server@$DEV_USER.service"

verify_code_server() {
  local service="code-server@$DEV_USER.service" health_url="http://127.0.0.1:$CODE_SERVER_PORT/healthz" attempt health
  for attempt in $(seq 1 30); do
    health=$(curl -fsS --max-time 4 "$health_url" 2>/dev/null || true)
    systemctl is-active --quiet "$service" && [[ "$health" == *'"status"'* ]] && { echo "code-server health check passed: $health"; return 0; }
    sleep 1
  done
  echo "ERROR: code-server did not pass its health check at $health_url." >&2
  systemctl status "$service" --no-pager >&2 || true
  journalctl -u "$service" --since "$PROVISION_STARTED_AT" --no-pager >&2 || true
  return 1
}
verify_code_server

stage "3/8: Installing and verifying FileBrowser Quantum (web file manager)"
install_filebrowser_quantum() {
  local arch asset_name api_url release_json tag_name asset_url tmp_binary version_text major config_file

  case "$(dpkg --print-architecture)" in
    amd64) arch="amd64" ;;
    arm64) arch="arm64" ;;
    *) echo "ERROR: FileBrowser Quantum has no binary for $(dpkg --print-architecture)." >&2; return 1 ;;
  esac
  asset_name="linux-${arch}-filebrowser"
  api_url="https://api.github.com/repos/gtsteffaniak/filebrowser/releases/latest"
  release_json=$(mktemp); tmp_binary=$(mktemp)

  if curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 90 \
      -H 'Accept: application/vnd.github+json' "$api_url" -o "$release_json"; then
    tag_name=$(jq -r '.tag_name // empty' "$release_json")
    asset_url=$(jq -r --arg name "$asset_name" '.assets[]? | select(.name == $name) | .browser_download_url' "$release_json" | head -n1)
  fi
  rm -f "$release_json"
  [[ -n "${asset_url:-}" && "$asset_url" != "null" ]] || asset_url="https://github.com/gtsteffaniak/filebrowser/releases/latest/download/${asset_name}"

  curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 600 "$asset_url" -o "$tmp_binary"
  chmod 0755 "$tmp_binary"
  version_text=$("$tmp_binary" version 2>&1 || "$tmp_binary" --version 2>&1 || true)
  major=$(sed -nE 's/.*[^0-9]([0-9]+)\.[0-9]+\.[0-9]+.*/\1/p' <<<"${tag_name:-$version_text}" | head -n1)
  [[ "$major" =~ ^[0-9]+$ ]] || major=1
  install -m 0755 "$tmp_binary" /usr/local/bin/filebrowser
  rm -f "$tmp_binary"

  install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" \
    "$DEV_HOME/.config/filebrowser" "$DEV_HOME/.local/share/filebrowser" "$DEV_HOME/.cache/filebrowser"
  config_file="$DEV_HOME/.config/filebrowser/config.yaml"

  if [[ "$major" -ge 2 ]]; then
    cat >"$config_file" <<EOF
http:
  port: $FILE_MANAGER_PORT
  listen: "0.0.0.0"
  baseURL: "/"
server:
  database:
    path: "$DEV_HOME/.local/share/filebrowser/filebrowser.sqlite"
  cacheDir: "$DEV_HOME/.cache/filebrowser"
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
  else
    cat >"$config_file" <<EOF
server:
  port: $FILE_MANAGER_PORT
  database: "$DEV_HOME/.local/share/filebrowser/database.db"
  cacheDir: "$DEV_HOME/.cache/filebrowser"
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
EnvironmentFile=/etc/filebrowser-quantum.env
ExecStart=/usr/local/bin/filebrowser -c \${FILEBROWSER_CONFIG}
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now filebrowser-quantum.service
}
install_filebrowser_quantum

verify_filebrowser() {
  local attempt code
  for attempt in $(seq 1 30); do
    systemctl is-active --quiet filebrowser-quantum.service && \
      code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:$FILE_MANAGER_PORT/" 2>/dev/null || true) && \
      [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] && { echo "FileBrowser Quantum health check passed (HTTP $code)."; return 0; }
    sleep 1
  done
  echo "ERROR: FileBrowser Quantum did not pass its HTTP health check." >&2
  systemctl status filebrowser-quantum.service --no-pager >&2 || true
  return 1
}
verify_filebrowser

stage "4/8: Installing and verifying ttyd (web terminal)"
# ttyd is a single static binary: no Docker, no Node.js toolchain, no native
# module compilation. It wraps `login` in a browser terminal, so it must run
# as root (login needs privilege to switch to the authenticated user) and
# needs -W/--writable or the browser terminal would be read-only -- useless
# for actually typing a login prompt.
install_ttyd() {
  local arch asset tag base tmp_binary sums expected actual

  case "$(dpkg --print-architecture)" in
    amd64) arch="x86_64" ;;
    arm64) arch="aarch64" ;;
    armhf) arch="armhf" ;;
    *) echo "ERROR: ttyd has no static binary for $(dpkg --print-architecture)." >&2; return 1 ;;
  esac
  asset="ttyd.$arch"

  tag=$(curl -fsSL --retry 3 --connect-timeout 20 --max-time 30 \
    -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/tsl0922/ttyd/releases/latest" 2>/dev/null \
    | jq -r '.tag_name // empty' || true)
  if [[ -n "$tag" ]]; then
    base="https://github.com/tsl0922/ttyd/releases/download/$tag"
  else
    base="https://github.com/tsl0922/ttyd/releases/latest/download"
  fi

  tmp_binary=$(mktemp)
  curl -fL --retry 3 --retry-all-errors --connect-timeout 20 --max-time 120 \
    "$base/$asset" -o "$tmp_binary"

  # Compare hashes directly rather than sha256sum -c: the release's
  # SHA256SUMS file references the asset by its release filename
  # (ttyd.x86_64), not the local temp path, so -c would look for a
  # same-named file in the current directory and always fail to find it.
  sums=$(curl -fsSL --retry 3 --connect-timeout 20 --max-time 30 "$base/SHA256SUMS" 2>/dev/null || true)
  if [[ -n "$sums" ]]; then
    expected=$(grep -E "[[:space:]]\*?${asset}\$" <<<"$sums" | awk '{print $1}' | head -n1)
    if [[ -n "$expected" ]]; then
      actual=$(sha256sum "$tmp_binary" | awk '{print $1}')
      if [[ "$expected" != "$actual" ]]; then
        echo "ERROR: ttyd checksum mismatch (expected $expected, got $actual)." >&2
        rm -f "$tmp_binary"
        return 1
      fi
    fi
  fi
  install -m 0755 "$tmp_binary" /usr/local/bin/ttyd
  rm -f "$tmp_binary"
  /usr/local/bin/ttyd --version
}
install_ttyd

cat >/etc/systemd/system/ttyd.service <<EOF
[Unit]
Description=ttyd web terminal
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ttyd --port $WEB_TERMINAL_PORT --writable -c $DEV_USER:$TTYD_PASSWORD login
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ttyd.service

verify_ttyd() {
  local attempt code
  for attempt in $(seq 1 30); do
    systemctl is-active --quiet ttyd.service && \
      code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 4 -u "$DEV_USER:$TTYD_PASSWORD" "http://127.0.0.1:$WEB_TERMINAL_PORT/" 2>/dev/null || true) && \
      [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] && { echo "ttyd health check passed (HTTP $code)."; return 0; }
    sleep 1
  done
  echo "ERROR: ttyd did not pass its HTTP health check." >&2
  systemctl status ttyd.service --no-pager >&2 || true
  journalctl -u ttyd.service --since "$PROVISION_STARTED_AT" --no-pager >&2 || true
  return 1
}
verify_ttyd

stage "5/8: Installing the static link dashboard (no Docker)"
install -d -m 0755 /opt/dashboard

cat >/usr/local/sbin/dashboard-refresh <<'REFRESH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-dev-claude.env
ip=$(hostname -I 2>/dev/null | awk '{print $1}')
[[ -n "$ip" ]] || { echo "Could not determine an IPv4 address." >&2; exit 1; }
cat >/opt/dashboard/index.html <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI Dev Claude</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
         background:#14161a; color:#e6e8eb; padding:2.5rem 1.5rem; }
  main { max-width: 640px; margin: 0 auto; }
  h1 { font-size:1.4rem; margin:0 0 .25rem; }
  p.sub { color:#9aa1ab; margin:0 0 2rem; }
  ul { list-style:none; padding:0; margin:0; display:grid; gap:.75rem; }
  a.card { display:block; padding:1rem 1.25rem; border-radius:.6rem; background:#1e2127;
           border:1px solid #2a2e36; text-decoration:none; color:inherit; transition:border-color .15s; }
  a.card:hover { border-color:#5b8def; }
  a.card .name { font-weight:600; font-size:1.05rem; }
  a.card .desc { color:#9aa1ab; font-size:.88rem; margin-top:.2rem; }
  footer { margin-top:2rem; color:#5c626c; font-size:.8rem; }
</style>
</head>
<body>
<main>
  <h1>AI Dev Claude</h1>
  <p class="sub">$ip</p>
  <ul>
    <li><a class="card" href="http://$ip:$CODE_SERVER_PORT">
      <div class="name">Web IDE (code-server)</div>
      <div class="desc">Browser-based VS Code, sign in with the generated password</div>
    </a></li>
    <li><a class="card" href="http://$ip:$FILE_MANAGER_PORT">
      <div class="name">File Manager (FileBrowser Quantum)</div>
      <div class="desc">Manage files under /srv/workspace, admin / generated password</div>
    </a></li>
    <li><a class="card" href="http://$ip:$WEB_TERMINAL_PORT">
      <div class="name">Web Terminal (ttyd)</div>
      <div class="desc">Browser-based shell, HTTP + Linux login required</div>
    </a></li>
  </ul>
  <footer>ai-dev-claude-no-docker &middot; static dashboard, no Docker</footer>
</main>
</body>
</html>
HTML
chmod 0644 /opt/dashboard/index.html
printf 'Dashboard updated for IP %s -> http://%s:%s\n' "$ip" "$ip" "$DASHBOARD_PORT"
REFRESH
chmod 0750 /usr/local/sbin/dashboard-refresh
/usr/local/sbin/dashboard-refresh

cat >/etc/systemd/system/ai-dev-dashboard.service <<EOF
[Unit]
Description=AI Dev Claude static dashboard
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/bin/python3 -m http.server $DASHBOARD_PORT --bind 0.0.0.0 --directory /opt/dashboard
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now ai-dev-dashboard.service

verify_dashboard() {
  local attempt code
  for attempt in $(seq 1 30); do
    systemctl is-active --quiet ai-dev-dashboard.service && \
      code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 4 "http://127.0.0.1:$DASHBOARD_PORT/" 2>/dev/null || true) && \
      [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] && { echo "Dashboard health check passed (HTTP $code)."; return 0; }
    sleep 1
  done
  echo "ERROR: Dashboard did not pass its HTTP health check." >&2
  systemctl status ai-dev-dashboard.service --no-pager >&2 || true
  return 1
}
verify_dashboard

stage "6/8: Verifying GitHub CLI"
gh --version

stage "7/8: Installing Claude Code"
install_claude_code() {
  local deb_arch fingerprint expected="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE" \
    key_file="/etc/apt/keyrings/claude-code.asc" source_file="/etc/apt/sources.list.d/claude-code.list"

  deb_arch=$(dpkg --print-architecture)
  case "$deb_arch" in
    amd64)
      if ! grep -qw avx /proc/cpuinfo; then
        echo "ERROR: Claude Code requires AVX on x86-64, which this Proxmox node's CPU does not expose." >&2
        return 1
      fi
      ;;
    arm64) ;;
    *) echo "ERROR: Claude Code is unsupported on architecture: $deb_arch" >&2; return 1 ;;
  esac

  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
    https://downloads.claude.ai/keys/claude-code.asc -o "$key_file"
  fingerprint=$(gpg --batch --show-keys --with-colons "$key_file" 2>/dev/null | awk -F: '$1=="fpr"{print toupper($10); exit}')
  if [[ "$fingerprint" != "$expected" ]]; then
    echo "ERROR: Anthropic signing-key fingerprint verification failed (got ${fingerprint:-none})." >&2
    rm -f "$key_file"
    return 1
  fi
  printf 'deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main\n' >"$source_file"
  timeout --foreground 15m apt-get update
  timeout --foreground 30m apt-get install -y --no-install-recommends claude-code
  runuser -u "$DEV_USER" -- claude --version
}
install_claude_code

stage "8/8: Installing helper commands (status, menu, OmniRoute connect)"
cat >/etc/ai-dev-claude.env <<EOF
DEV_USER=$DEV_USER
CODE_SERVER_PORT=$CODE_SERVER_PORT
FILE_MANAGER_PORT=$FILE_MANAGER_PORT
WEB_TERMINAL_PORT=$WEB_TERMINAL_PORT
DASHBOARD_PORT=$DASHBOARD_PORT
EOF
chmod 0644 /etc/ai-dev-claude.env

cat >/usr/local/bin/claude-dev-status <<'STATUS'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-dev-claude.env
ip=$(hostname -I 2>/dev/null | awk '{print $1}')
printf 'Container:      %s (%s)\n' "$(hostname)" "${ip:-unknown}"
printf 'Web IDE:        http://%s:%s  [%s]\n' "$ip" "$CODE_SERVER_PORT" "$(systemctl is-active "code-server@$DEV_USER.service" 2>/dev/null || echo unknown)"
printf 'File Manager:   http://%s:%s  [%s]\n' "$ip" "$FILE_MANAGER_PORT" "$(systemctl is-active filebrowser-quantum.service 2>/dev/null || echo unknown)"
printf 'Web Terminal:   http://%s:%s  [%s]\n' "$ip" "$WEB_TERMINAL_PORT" "$(systemctl is-active ttyd.service 2>/dev/null || echo unknown)"
printf 'Dashboard:      http://%s:%s  [%s]\n' "$ip" "$DASHBOARD_PORT" "$(systemctl is-active ai-dev-dashboard.service 2>/dev/null || echo unknown)"
printf 'GitHub CLI:     %s\n' "$(gh --version 2>&1 | head -n1)"
if sudo -u "$DEV_USER" -H gh auth status --hostname github.com >/dev/null 2>&1; then
  printf 'GitHub login:   authenticated\n'
else
  printf 'GitHub login:   not configured -- run: claude-dev-menu\n'
fi
printf 'Claude Code:    %s\n' "$(command -v claude >/dev/null 2>&1 && claude --version 2>&1 || echo 'not found')"
if [[ -f "/home/$DEV_USER/.claude/settings.json" ]] && jq -e '.env.ANTHROPIC_BASE_URL' "/home/$DEV_USER/.claude/settings.json" >/dev/null 2>&1; then
  printf 'OmniRoute:      connected (%s)\n' "$(jq -r '.env.ANTHROPIC_BASE_URL' "/home/$DEV_USER/.claude/settings.json")"
else
  printf 'OmniRoute:      not connected\n'
fi
STATUS
chmod 0755 /usr/local/bin/claude-dev-status

cat >/usr/local/sbin/claude-omniroute-connect <<'CONNECT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-dev-claude.env
DEV_HOME="/home/$DEV_USER"
read -r -p 'OmniRoute base URL (e.g. http://192.168.1.50:20128): ' base_url
[[ -n "$base_url" ]] || { echo "Base URL is required." >&2; exit 1; }
read -r -s -p 'OmniRoute API key (leave blank if none): ' api_key
echo
install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "$DEV_HOME/.claude"
settings_file="$DEV_HOME/.claude/settings.json"
[[ -s "$settings_file" ]] || printf '{}\n' >"$settings_file"
tmp=$(mktemp)
jq --arg url "$base_url" --arg key "$api_key" \
  '.env = ((.env // {}) + {ANTHROPIC_BASE_URL: $url} + (if $key != "" then {ANTHROPIC_AUTH_TOKEN: $key} else {} end))' \
  "$settings_file" >"$tmp"
install -m 0600 -o "$DEV_USER" -g "$DEV_USER" "$tmp" "$settings_file"
rm -f "$tmp"
echo "Claude Code is now configured to use OmniRoute at $base_url."
CONNECT
chmod 0750 /usr/local/sbin/claude-omniroute-connect

cat >/usr/local/sbin/claude-omniroute-disconnect <<'DISCONNECT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-dev-claude.env
settings_file="/home/$DEV_USER/.claude/settings.json"
[[ -f "$settings_file" ]] || { echo "No Claude Code settings file found."; exit 0; }
tmp=$(mktemp)
jq 'if .env then .env |= del(.ANTHROPIC_BASE_URL, .ANTHROPIC_AUTH_TOKEN) else . end' "$settings_file" >"$tmp"
install -m 0600 -o "$DEV_USER" -g "$DEV_USER" "$tmp" "$settings_file"
rm -f "$tmp"
echo "Claude Code no longer routes through OmniRoute."
DISCONNECT
chmod 0750 /usr/local/sbin/claude-omniroute-disconnect

cat >/usr/local/bin/claude-dev-menu <<'MENU'
#!/usr/bin/env bash
set -u
source /etc/ai-dev-claude.env
while true; do
  cat <<'EOF'

AI Dev Claude -- menu
----------------------
1) Show status / URLs
2) GitHub CLI login (browser)
3) Claude Code login
4) Connect Claude Code to OmniRoute
5) Disconnect Claude Code from OmniRoute
6) Refresh dashboard links (after an IP change)
q) Quit
EOF
  read -r -p 'Select: ' choice
  case "$choice" in
    1) claude-dev-status ;;
    2) sudo -u "$DEV_USER" -H gh auth login --hostname github.com --git-protocol https --web && sudo -u "$DEV_USER" -H gh auth setup-git ;;
    3) sudo -u "$DEV_USER" -H claude ;;
    4) sudo /usr/local/sbin/claude-omniroute-connect ;;
    5) sudo /usr/local/sbin/claude-omniroute-disconnect ;;
    6) sudo /usr/local/sbin/dashboard-refresh ;;
    q|Q) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
done
MENU
chmod 0755 /usr/local/bin/claude-dev-menu

echo
echo "Provisioning completed successfully."
PROVISION
}

# ---------- Run provisioning ----------

run_provisioning() {
  local env_file provision_file
  env_file=$(mktemp)
  provision_file=$(mktemp)
  write_env_file "$env_file"
  write_provision_script "$provision_file"

  pct push "$CTID" "$env_file" /root/ai-dev-claude.env --perms 0600
  pct push "$CTID" "$provision_file" /root/ai-dev-claude-provision.sh --perms 0700
  rm -f "$env_file" "$provision_file"

  say "Provisioning LXC $CTID (this streams live below and is also saved to $LOG_FILE)..."
  set +e
  pct exec "$CTID" -- bash /root/ai-dev-claude-provision.sh 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e
  if ((rc != 0)); then
    show_error_details "Provisioning failed inside LXC $CTID (exit $rc). The container was left intact for diagnosis."
    exit 1
  fi
  pct exec "$CTID" -- rm -f /root/ai-dev-claude-provision.sh /root/ai-dev-claude.env
}

# ---------- Reboot and finalize ----------

reboot_and_finalize() {
  stage "Rebooting LXC $CTID so every service starts fresh"
  pct reboot "$CTID" >>"$LOG_FILE" 2>&1
  wait_for_ct_ready || { show_error_details "LXC $CTID did not come back up after reboot."; exit 1; }

  stage "Finalizing: confirming IP and re-verifying every service"
  set +e
  pct exec "$CTID" -- bash -c '
    set -Eeuo pipefail
    /usr/local/sbin/dashboard-refresh
    source /etc/ai-dev-claude.env
    for i in $(seq 1 30); do
      cs=$(systemctl is-active "code-server@$DEV_USER.service" 2>/dev/null || true)
      fb=$(systemctl is-active filebrowser-quantum.service 2>/dev/null || true)
      tt=$(systemctl is-active ttyd.service 2>/dev/null || true)
      db=$(systemctl is-active ai-dev-dashboard.service 2>/dev/null || true)
      [[ "$cs" == active && "$fb" == active && "$tt" == active && "$db" == active ]] && break
      sleep 2
    done
    printf "Post-reboot status: code-server=%s filebrowser=%s ttyd=%s dashboard=%s\n" "$cs" "$fb" "$tt" "$db"
    [[ "$cs" == active && "$fb" == active && "$tt" == active && "$db" == active ]]
  ' 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e
  if ((rc != 0)); then
    show_error_details "One or more services did not come back up after reboot. The container was left intact for diagnosis."
    exit 1
  fi
}

# ---------- Final summary ----------

final_summary() {
  local ip
  ip=$(wait_for_ct_ipv4 || true)
  local body
  body=$(cat <<EOF
LXC $CTID ($CT_HOSTNAME) is ready. No Docker was installed.

Dashboard:      http://${ip:-CONTAINER_IP}:$DASHBOARD_PORT
Web IDE:        http://${ip:-CONTAINER_IP}:$CODE_SERVER_PORT  (password: $CODE_SERVER_PASSWORD)
File Manager:   http://${ip:-CONTAINER_IP}:$FILE_MANAGER_PORT  (admin / $FILE_MANAGER_PASSWORD)
Web Terminal:   http://${ip:-CONTAINER_IP}:$WEB_TERMINAL_PORT  ($DEV_USER / $TTYD_PASSWORD, then Linux login)

SSH:            ssh $DEV_USER@${ip:-CONTAINER_IP}  (password: $DEV_PASSWORD)
Console:        pct enter $CTID , then: su - $DEV_USER

Still needed inside the container (run: claude-dev-menu):
  - GitHub CLI login (browser device code)
  - Claude Code login (run 'claude' once as $DEV_USER)
  - Optionally: connect Claude Code to OmniRoute

Log: $LOG_FILE
EOF
)
  echo
  echo "$body"
  $ASSUME_YES || whiptail --backtitle "$BACKTITLE" --title "COMPLETED" --scrolltext --msgbox "$body" 26 88 || true
}

# ---------- Entry point ----------

main() {
  [[ "$(id -u)" -eq 0 ]] || { echo "Run as root on the Proxmox host." >&2; exit 1; }
  init_logging
  check_proxmox_host
  ensure_whiptail
  log "$SCRIPT_NAME v$SCRIPT_VERSION started (assume_yes=$ASSUME_YES)"

  gather_configuration
  create_container
  start_container
  run_provisioning
  reboot_and_finalize
  final_summary
}

main "$@"
