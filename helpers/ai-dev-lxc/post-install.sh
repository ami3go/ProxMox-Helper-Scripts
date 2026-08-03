#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Interactive post-install provisioner for an existing Debian LXC.
# Run as root on the Proxmox VE host after creating the container.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="2.3.0"
readonly BACKTITLE="AI Development LXC • Post-install"
readonly LOG_DIR="/var/log/ai-dev-lxc-post-install"
readonly DEFAULT_USER="dev"
readonly DEFAULT_PORT="8080"
readonly EXPECTED_CLAUDE_FINGERPRINT="31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE"

LOG_FILE=""
VERBOSE_ACTIVE=0
CTID=""
DEV_USER="$DEFAULT_USER"
DEV_PASSWORD=""
SSH_KEY_CONTENT=""
PASSWORD_AUTH="yes"
CODE_SERVER_PORT="$DEFAULT_PORT"
CODE_SERVER_PASSWORD=""
GIT_NAME=""
GIT_EMAIL=""
UPGRADE_PACKAGES="yes"
INSTALL_ROBOT="yes"
INSTALL_GITHUB="yes"
INSTALL_CLAUDE="yes"
INSTALL_CODE_SERVER="yes"
CONFIGURE_DHCP="yes"
FIX_PVE_CONSOLE="yes"

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    printf 'ERROR: Run this script as root on the Proxmox VE host.\n' >&2
    exit 1
  fi
}

check_proxmox_host() {
  local missing=() cmd
  for cmd in pct pveversion awk sed grep base64 openssl ip; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done
  if ((${#missing[@]})); then
    printf 'ERROR: This script must run on a Proxmox VE host. Missing: %s\n' "${missing[*]}" >&2
    exit 1
  fi
}

ensure_whiptail() {
  command -v whiptail >/dev/null 2>&1 && return 0
  printf 'whiptail is required. Installing it on the Proxmox host...\n'
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y whiptail
}

init_logging() {
  install -d -m 0700 "$LOG_DIR"
  LOG_FILE="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S).log"
  : >"$LOG_FILE"
  chmod 0600 "$LOG_FILE"
}

log_line() {
  local level=$1
  shift
  local line="[$(date '+%F %T')] [$level] $*"
  printf '%s\n' "$line" | tee -a "$LOG_FILE"
}

begin_verbose_output() {
  [[ $VERBOSE_ACTIVE == 1 ]] && return 0
  VERBOSE_ACTIVE=1
  clear 2>/dev/null || true
  printf '%s\n' '========================================================================' | tee -a "$LOG_FILE"
  log_line INFO "AI Development LXC post-install v$SCRIPT_VERSION"
  log_line INFO "Proxmox host log: $LOG_FILE"
  printf '%s\n\n' '========================================================================' | tee -a "$LOG_FILE"
}

run_step() {
  local label=$1
  shift
  local started rc elapsed
  started=$(date +%s)
  log_line STEP "START: $label"
  set +e
  "$@" 2>&1 | tee -a "$LOG_FILE"
  rc=${PIPESTATUS[0]}
  set -e
  elapsed=$(( $(date +%s) - started ))
  if ((rc == 0)); then
    log_line STEP "DONE: $label (${elapsed}s)"
  else
    log_line ERROR "FAILED: $label (exit $rc after ${elapsed}s)"
  fi
  return "$rc"
}

show_error() {
  local message=${1:-"An unexpected error occurred."}
  local excerpt=""
  [[ -s $LOG_FILE ]] && excerpt=$(tail -n 22 "$LOG_FILE" | sed 's/[^[:print:]\t]//g')
  whiptail --backtitle "$BACKTITLE" --title "ERROR" --scrolltext --msgbox \
    "$message

${excerpt:+Recent output:
$excerpt

}Full host log:
$LOG_FILE" 26 96 || true
}

on_error() {
  local rc=$?
  local line=${BASH_LINENO[0]:-unknown}
  local command=${BASH_COMMAND:-unknown}
  printf '[%s] [ERROR] Failure at line %s (exit %s): %s\n' \
    "$(date '+%F %T')" "$line" "$rc" "$command" >>"${LOG_FILE:-/tmp/ai-dev-post-install-error.log}"
  show_error "Post-install failed at line $line."
  exit "$rc"
}
trap on_error ERR
trap 'log_line WARN "Interrupted by user"; exit 130' INT TERM

input_box() {
  local title=$1 prompt=$2 default=${3:-}
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --inputbox "$prompt" 13 82 "$default" 3>&1 1>&2 2>&3
}

password_box() {
  local title=$1 prompt=$2
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --passwordbox "$prompt" 13 82 3>&1 1>&2 2>&3
}

menu_box() {
  local title=$1 prompt=$2
  shift 2
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --menu "$prompt" 22 90 13 "$@" 3>&1 1>&2 2>&3
}

checklist_box() {
  local title=$1 prompt=$2
  shift 2
  whiptail --backtitle "$BACKTITLE" --title "$title" \
    --separate-output --checklist "$prompt" 24 96 14 "$@" 3>&1 1>&2 2>&3
}

ask_yes_no() {
  local title=$1 prompt=$2 default=${3:-yes}
  local flags=()
  [[ $default == no ]] && flags=(--defaultno)
  whiptail --backtitle "$BACKTITLE" --title "$title" "${flags[@]}" \
    --yesno "$prompt" 15 86
}

is_valid_username() {
  [[ $1 =~ ^[a-z_][a-z0-9_-]{0,30}$ ]]
}

is_valid_port() {
  [[ $1 =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535))
}

list_containers() {
  local id hostname status
  while IFS= read -r id; do
    [[ -n $id ]] || continue
    hostname=$(pct config "$id" 2>/dev/null | awk -F': ' '$1 == "hostname" {print $2; exit}')
    status=$(pct status "$id" 2>/dev/null | awk '{print $2}')
    printf '%s\t%s (%s)\n' "$id" "${hostname:-unnamed}" "${status:-unknown}"
  done < <(pct list 2>/dev/null | awk 'NR > 1 {print $1}')
}

select_container() {
  local entries=() id description
  while IFS=$'\t' read -r id description; do
    [[ -n $id ]] && entries+=("$id" "$description")
  done < <(list_containers)
  if ((${#entries[@]} == 0)); then
    show_error "No LXC containers were found on this Proxmox node."
    exit 1
  fi
  CTID=$(whiptail --backtitle "$BACKTITLE" --title "SELECT LXC" \
    --menu "Select the existing Debian LXC to configure." 22 86 13 \
    "${entries[@]}" 3>&1 1>&2 2>&3) || exit 0
}

collect_user_settings() {
  local value choice
  while true; do
    value=$(input_box "DEVELOPMENT USER" \
      "Linux account used for SSH, code-server, Claude Code, Python, and Robot Framework:" \
      "$DEV_USER") || exit 0
    if is_valid_username "$value"; then
      DEV_USER=$value
      break
    fi
    whiptail --title "INVALID USERNAME" --msgbox "Use a valid lowercase Linux username." 9 70
  done

  choice=$(menu_box "SSH AUTHENTICATION" \
    "Choose initial SSH authentication for '$DEV_USER'. Direct LAN SSH will use the LXC DHCP address." \
    "password" "Generate a strong temporary password" \
    "host-key" "Copy /root/.ssh/authorized_keys from the Proxmox host" \
    "both" "Temporary password plus Proxmox host keys" \
    "paste-key" "Paste an OpenSSH public key") || exit 0

  case $choice in
    password)
      DEV_PASSWORD=$(openssl rand -hex 12)
      PASSWORD_AUTH=yes
      ;;
    host-key)
      [[ -s /root/.ssh/authorized_keys ]] || {
        whiptail --title "SSH KEY NOT FOUND" --msgbox "/root/.ssh/authorized_keys is missing or empty." 10 76
        collect_user_settings
        return
      }
      SSH_KEY_CONTENT=$(cat /root/.ssh/authorized_keys)
      DEV_PASSWORD=$(openssl rand -hex 12)
      PASSWORD_AUTH=no
      ;;
    both)
      DEV_PASSWORD=$(openssl rand -hex 12)
      PASSWORD_AUTH=yes
      [[ -s /root/.ssh/authorized_keys ]] && SSH_KEY_CONTENT=$(cat /root/.ssh/authorized_keys)
      ;;
    paste-key)
      SSH_KEY_CONTENT=$(input_box "SSH PUBLIC KEY" "Paste one OpenSSH public key:" "") || exit 0
      [[ $SSH_KEY_CONTENT =~ ^(ssh-|ecdsa-|sk-ssh-|sk-ecdsa-) ]] || {
        whiptail --title "INVALID KEY" --msgbox "The text does not look like an OpenSSH public key." 10 76
        collect_user_settings
        return
      }
      DEV_PASSWORD=$(openssl rand -hex 12)
      PASSWORD_AUTH=no
      ;;
  esac
}

collect_web_settings() {
  local value custom
  while true; do
    value=$(input_box "WEB IDE PORT" \
      "code-server will listen directly on all LXC interfaces. Enter its TCP port:" \
      "$CODE_SERVER_PORT") || exit 0
    if is_valid_port "$value"; then
      CODE_SERVER_PORT=$value
      break
    fi
    whiptail --title "INVALID PORT" --msgbox "Enter a port from 1024 through 65535." 9 70
  done

  if ask_yes_no "WEB IDE PASSWORD" "Generate a strong code-server password automatically?" yes; then
    CODE_SERVER_PASSWORD=$(openssl rand -hex 16)
  else
    while true; do
      custom=$(password_box "WEB IDE PASSWORD" "Enter a code-server password of at least 12 characters:") || exit 0
      if ((${#custom} >= 12)); then
        CODE_SERVER_PASSWORD=$custom
        break
      fi
      whiptail --title "WEAK PASSWORD" --msgbox "Use at least 12 characters." 9 70
    done
  fi
}

collect_components() {
  local selected
  selected=$(checklist_box "ENVIRONMENT COMPONENTS" \
    "Select the components to install or repair. Core SSH and development packages are always installed." \
    "code-server" "Browser-based VS Code panel on the DHCP address" ON \
    "claude" "Claude Code from Anthropic's signed stable APT repository" ON \
    "robot" "Python venv, Robot Framework, RobotCode, and sample tests" ON \
    "github" "GitHub CLI and Git credential integration helper" ON) || exit 0

  INSTALL_CODE_SERVER=no
  INSTALL_CLAUDE=no
  INSTALL_ROBOT=no
  INSTALL_GITHUB=no
  while IFS= read -r item; do
    case $item in
      code-server) INSTALL_CODE_SERVER=yes ;;
      claude) INSTALL_CLAUDE=yes ;;
      robot) INSTALL_ROBOT=yes ;;
      github) INSTALL_GITHUB=yes ;;
    esac
  done <<<"$selected"

  if [[ $INSTALL_CODE_SERVER == no && $INSTALL_CLAUDE == no && $INSTALL_ROBOT == no && $INSTALL_GITHUB == no ]]; then
    whiptail --title "NO COMPONENTS" --msgbox "Select at least one development component." 9 72
    collect_components
    return
  fi

  ask_yes_no "SYSTEM UPDATE" "Run apt-get dist-upgrade before provisioning?" yes \
    && UPGRADE_PACKAGES=yes || UPGRADE_PACKAGES=no
}

collect_git_identity() {
  if ask_yes_no "GIT IDENTITY" "Configure a global Git author name and email for '$DEV_USER'?" no; then
    GIT_NAME=$(input_box "GIT AUTHOR" "Git author name:" "") || exit 0
    GIT_EMAIL=$(input_box "GIT EMAIL" "Git author email:" "") || exit 0
  fi
}

container_config_value() {
  local key=$1
  pct config "$CTID" 2>/dev/null | awk -F': ' -v key="$key" '$1 == key {print $2; exit}'
}

normalize_net0_to_dhcp() {
  local net0 cleaned
  net0=$(container_config_value net0)
  [[ -n $net0 ]] || return 1
  cleaned=$(printf '%s' "$net0" \
    | sed -E 's/(^|,)ip=[^,]*//g; s/(^|,)gw=[^,]*//g; s/(^|,)firewall=[^,]*//g; s/,,+/,/g; s/^,//; s/,$//')
  [[ -n $cleaned ]] && cleaned+=","
  cleaned+="ip=dhcp,firewall=0"
  run_step "Configure LXC $CTID primary interface for DHCP" pct set "$CTID" --net0 "$cleaned"
}

prepare_container() {
  local status
  status=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
  if [[ $FIX_PVE_CONSOLE == yes ]]; then
    run_step "Set Proxmox web console mode to direct shell" pct set "$CTID" --cmode shell
  fi

  if [[ $CONFIGURE_DHCP == yes ]]; then
    local net0
    net0=$(container_config_value net0)
    if [[ $net0 != *"ip=dhcp"* || $net0 != *"firewall=0"* ]]; then
      normalize_net0_to_dhcp
      if [[ $status == running ]]; then
        run_step "Restart LXC $CTID to apply DHCP networking" pct reboot "$CTID"
        sleep 4
      fi
    fi
  fi

  status=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
  if [[ $status != running ]]; then
    run_step "Start LXC $CTID" pct start "$CTID"
  fi

  local count=0
  log_line STEP "START: Wait for LXC $CTID command execution"
  until pct exec "$CTID" -- true >/dev/null 2>&1; do
    sleep 2
    ((count += 1))
    log_line INFO "Container readiness check $count/30"
    if ((count >= 30)); then
      log_line ERROR "LXC $CTID did not become ready"
      return 1
    fi
  done
  log_line STEP "DONE: LXC $CTID accepts commands"

  local os_id
  os_id=$(pct exec "$CTID" -- bash -lc '. /etc/os-release; printf "%s" "$ID"' 2>/dev/null || true)
  if [[ $os_id != debian && $os_id != ubuntu ]]; then
    show_error "LXC $CTID is not Debian or Ubuntu. Detected OS ID: ${os_id:-unknown}."
    return 1
  fi
}

b64() {
  printf '%s' "$1" | base64 -w 0
}

write_payload() {
  local tmp_dir env_file provision_file
  tmp_dir=$(mktemp -d)
  env_file="$tmp_dir/post-install.env"
  provision_file="$tmp_dir/post-install-provision.sh"

  cat >"$env_file" <<EOF
DEV_USER_B64=$(b64 "$DEV_USER")
DEV_PASSWORD_B64=$(b64 "$DEV_PASSWORD")
SSH_KEY_B64=$(b64 "$SSH_KEY_CONTENT")
PASSWORD_AUTH_B64=$(b64 "$PASSWORD_AUTH")
CODE_SERVER_PORT_B64=$(b64 "$CODE_SERVER_PORT")
CODE_SERVER_PASSWORD_B64=$(b64 "$CODE_SERVER_PASSWORD")
GIT_NAME_B64=$(b64 "$GIT_NAME")
GIT_EMAIL_B64=$(b64 "$GIT_EMAIL")
UPGRADE_PACKAGES_B64=$(b64 "$UPGRADE_PACKAGES")
INSTALL_ROBOT_B64=$(b64 "$INSTALL_ROBOT")
INSTALL_GITHUB_B64=$(b64 "$INSTALL_GITHUB")
INSTALL_CLAUDE_B64=$(b64 "$INSTALL_CLAUDE")
INSTALL_CODE_SERVER_B64=$(b64 "$INSTALL_CODE_SERVER")
EXPECTED_CLAUDE_FINGERPRINT_B64=$(b64 "$EXPECTED_CLAUDE_FINGERPRINT")
EOF
  chmod 0600 "$env_file"

  cat >"$provision_file" <<'PROVISION'
#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly LOG_FILE="/var/log/ai-dev-post-install.log"
readonly ENV_FILE="/root/ai-dev-post-install.env"
PROVISION_STARTED=$(date +%s)
CURRENT_STEP="initialization"

: >"$LOG_FILE"
chmod 0600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

log() {
  local level=$1
  shift
  printf '[%s] [%s] %s\n' "$(date '+%F %T')" "$level" "$*"
}

step() {
  CURRENT_STEP=$1
  printf '\n%s\n' '------------------------------------------------------------------------'
  log STEP "$CURRENT_STEP"
  printf '%s\n' '------------------------------------------------------------------------'
}

on_error() {
  local rc=$?
  local line=${BASH_LINENO[0]:-unknown}
  log ERROR "Step failed: $CURRENT_STEP"
  log ERROR "Line $line, exit $rc, command: ${BASH_COMMAND:-unknown}"
  log ERROR "Full LXC log: $LOG_FILE"
  exit "$rc"
}
trap on_error ERR

[[ -r $ENV_FILE ]] || { log ERROR "Missing $ENV_FILE"; exit 2; }
# shellcheck disable=SC1090
source "$ENV_FILE"
decode() { printf '%s' "$1" | base64 -d; }

DEV_USER=$(decode "$DEV_USER_B64")
DEV_PASSWORD=$(decode "$DEV_PASSWORD_B64")
SSH_KEY_CONTENT=$(decode "$SSH_KEY_B64")
PASSWORD_AUTH=$(decode "$PASSWORD_AUTH_B64")
CODE_SERVER_PORT=$(decode "$CODE_SERVER_PORT_B64")
CODE_SERVER_PASSWORD=$(decode "$CODE_SERVER_PASSWORD_B64")
GIT_NAME=$(decode "$GIT_NAME_B64")
GIT_EMAIL=$(decode "$GIT_EMAIL_B64")
UPGRADE_PACKAGES=$(decode "$UPGRADE_PACKAGES_B64")
INSTALL_ROBOT=$(decode "$INSTALL_ROBOT_B64")
INSTALL_GITHUB=$(decode "$INSTALL_GITHUB_B64")
INSTALL_CLAUDE=$(decode "$INSTALL_CLAUDE_B64")
INSTALL_CODE_SERVER=$(decode "$INSTALL_CODE_SERVER_B64")
EXPECTED_CLAUDE_FINGERPRINT=$(decode "$EXPECTED_CLAUDE_FINGERPRINT_B64")

[[ $DEV_USER =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { log ERROR "Invalid development username"; exit 2; }
[[ $CODE_SERVER_PORT =~ ^[0-9]+$ ]] || { log ERROR "Invalid code-server port"; exit 2; }

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

step "Inspect operating system and network"
cat /etc/os-release
uname -a
printf 'Addresses before provisioning: %s\n' "$(hostname -I 2>/dev/null || true)"
printf 'Memory:\n'; free -h || true
printf 'Disk:\n'; df -h / /home /tmp || true

step "Refresh Debian package indexes"
apt-get update

if [[ $UPGRADE_PACKAGES == yes ]]; then
  step "Upgrade installed Debian packages"
  apt-get -y dist-upgrade
fi

step "Install base development, SSH, Python, Git, and diagnostics packages"
apt-get install -y --no-install-recommends \
  sudo openssh-server ca-certificates curl wget gnupg git \
  build-essential python3 python3-dev python3-pip python3-venv pipx \
  jq ripgrep fd-find tmux nano vim-tiny less unzip zip rsync \
  shellcheck openssl make cmake pkg-config procps iproute2 net-tools \
  locales lsb-release

if [[ $INSTALL_GITHUB == yes ]]; then
  step "Install GitHub CLI"
  if ! command -v gh >/dev/null 2>&1; then
    install -d -m 0755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
      "$(dpkg --print-architecture)" >/etc/apt/sources.list.d/github-cli.list
    apt-get update
    apt-get install -y gh
  fi
  gh --version | head -n 1
fi

step "Create or repair the development account"
if ! id "$DEV_USER" >/dev/null 2>&1; then
  useradd --create-home --shell /bin/bash "$DEV_USER"
fi
usermod -aG sudo,dialout "$DEV_USER"
DEV_HOME=$(getent passwd "$DEV_USER" | cut -d: -f6)
[[ -n $DEV_HOME ]] || { log ERROR "Unable to determine home for $DEV_USER"; exit 2; }
if [[ -n $DEV_PASSWORD ]]; then
  printf '%s:%s\n' "$DEV_USER" "$DEV_PASSWORD" | chpasswd
fi
install -d -m 0750 -o "$DEV_USER" -g "$DEV_USER" /srv/workspace

step "Configure SSH for direct LAN access"
install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "$DEV_HOME/.ssh"
if [[ -n $SSH_KEY_CONTENT ]]; then
  printf '%s\n' "$SSH_KEY_CONTENT" >"$DEV_HOME/.ssh/authorized_keys"
  chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.ssh/authorized_keys"
  chmod 0600 "$DEV_HOME/.ssh/authorized_keys"
fi
install -d -m 0755 /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-ai-development-lxc.conf <<EOF
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication $PASSWORD_AUTH
KbdInteractiveAuthentication no
X11Forwarding no
AllowUsers $DEV_USER
EOF
sshd -t
systemctl enable --now ssh
systemctl restart ssh

if [[ $INSTALL_CODE_SERVER == yes ]]; then
  step "Install or update code-server"
  curl -fsSL --retry 3 --retry-delay 2 https://code-server.dev/install.sh \
    -o /tmp/install-code-server.sh
  sh /tmp/install-code-server.sh
  rm -f /tmp/install-code-server.sh

  step "Configure code-server for direct DHCP/LAN access"
  install -d -m 0700 -o "$DEV_USER" -g "$DEV_USER" "$DEV_HOME/.config/code-server"
  yaml_password=${CODE_SERVER_PASSWORD//\'/\'\'}
  cat >"$DEV_HOME/.config/code-server/config.yaml" <<EOF
bind-addr: 0.0.0.0:$CODE_SERVER_PORT
auth: password
password: '$yaml_password'
cert: false
disable-telemetry: true
EOF
  chown "$DEV_USER:$DEV_USER" "$DEV_HOME/.config/code-server/config.yaml"
  chmod 0600 "$DEV_HOME/.config/code-server/config.yaml"
  systemctl enable --now "code-server@$DEV_USER.service"
  systemctl restart "code-server@$DEV_USER.service"
  systemctl --no-pager --full status "code-server@$DEV_USER.service" || true
  ss -lntp | grep ":$CODE_SERVER_PORT" || true
fi

if [[ $INSTALL_CLAUDE == yes ]]; then
  step "Check Claude Code architecture and CPU requirements"
  arch=$(dpkg --print-architecture)
  case $arch in
    amd64)
      if ! grep -qw avx /proc/cpuinfo; then
        log ERROR "Claude Code requires AVX on x86-64, but AVX is not exposed to this LXC."
        exit 31
      fi
      ;;
    arm64) ;;
    *) log ERROR "Unsupported Claude Code architecture: $arch"; exit 31 ;;
  esac

  step "Install Claude Code signing key and stable APT repository"
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL --retry 3 --retry-delay 2 \
    https://downloads.claude.ai/keys/claude-code.asc \
    -o /etc/apt/keyrings/claude-code.asc
  fingerprint=$(gpg --batch --show-keys --with-colons /etc/apt/keyrings/claude-code.asc 2>/dev/null \
    | awk -F: '$1 == "fpr" {print toupper($10); exit}')
  printf 'Anthropic signing-key fingerprint: %s\n' "${fingerprint:-not detected}"
  if [[ $fingerprint != "$EXPECTED_CLAUDE_FINGERPRINT" ]]; then
    log ERROR "Anthropic signing-key fingerprint mismatch"
    exit 32
  fi
  printf '%s\n' \
    'deb [signed-by=/etc/apt/keyrings/claude-code.asc] https://downloads.claude.ai/claude-code/apt/stable stable main' \
    >/etc/apt/sources.list.d/claude-code.list
  apt-get update

  step "Install or update Claude Code"
  apt-get install -y --no-install-recommends claude-code
  runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" claude --version
fi

if [[ $INSTALL_ROBOT == yes ]]; then
  step "Create Python and Robot Framework workspace"
  PROJECT=/srv/workspace/robot-demo
  install -d -m 0750 -o "$DEV_USER" -g "$DEV_USER" "$PROJECT/tests" "$PROJECT/.vscode"
  cat >"$PROJECT/requirements.txt" <<'EOF'
robotframework
robotcode[all]
pytest
ruff
EOF
  cat >"$PROJECT/tests/smoke.robot" <<'EOF'
*** Settings ***
Documentation    Post-install environment smoke test.

*** Test Cases ***
Development Environment Is Ready
    Log    AI Development LXC post-install is operational.
    Should Be Equal As Integers    ${1 + 1}    2
EOF
  cat >"$PROJECT/.vscode/settings.json" <<'EOF'
{
    "python.defaultInterpreterPath": "${workspaceFolder}/.venv/bin/python",
    "python.terminal.activateEnvironment": true
}
EOF
  if [[ ! -x $PROJECT/.venv/bin/python ]]; then
    python3 -m venv "$PROJECT/.venv"
  fi
  "$PROJECT/.venv/bin/python" -m pip install --upgrade pip setuptools wheel
  "$PROJECT/.venv/bin/python" -m pip install --upgrade -r "$PROJECT/requirements.txt"
  chown -R "$DEV_USER:$DEV_USER" "$PROJECT"

  step "Install code-server development extensions"
  if command -v code-server >/dev/null 2>&1; then
    install_extension() {
      local extension=$1
      if ! runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" USER="$DEV_USER" \
          code-server --install-extension "$extension"; then
        log WARN "Extension was not installed: $extension"
      fi
    }
    install_extension ms-python.python
    install_extension d-biehl.robotcode
    [[ $INSTALL_CLAUDE == yes ]] && install_extension anthropic.claude-code
    [[ $INSTALL_GITHUB == yes ]] && install_extension github.vscode-pull-request-github
  fi

  step "Run Robot Framework smoke test"
  cd "$PROJECT"
  "$PROJECT/.venv/bin/python" -m robot --outputdir results tests
  chown -R "$DEV_USER:$DEV_USER" "$PROJECT/results"
fi

step "Configure Git defaults and first-login helper"
if [[ -n $GIT_NAME ]]; then
  runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" git config --global user.name "$GIT_NAME"
fi
if [[ -n $GIT_EMAIL ]]; then
  runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" git config --global user.email "$GIT_EMAIL"
fi
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" git config --global init.defaultBranch main
runuser -u "$DEV_USER" -- env HOME="$DEV_HOME" git config --global pull.rebase false

cat >/usr/local/bin/ai-dev-first-login <<'FIRSTLOGIN'
#!/usr/bin/env bash
set -u
if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
  echo 'Run this command as the normal development user.' >&2
  exit 1
fi
while true; do
  cat <<'EOF'

AI Development First-login Menu
-------------------------------
1) Authenticate GitHub CLI
2) Start Claude Code login
3) Check Claude Code installation
4) Show environment status
5) Open Robot Framework example
q) Quit
EOF
  read -r -p 'Select: ' choice
  case $choice in
    1)
      if command -v gh >/dev/null 2>&1; then
        gh auth login --hostname github.com --git-protocol https --web && gh auth setup-git
      else
        echo 'GitHub CLI is not installed.'
      fi
      ;;
    2)
      if command -v claude >/dev/null 2>&1; then
        cd /srv/workspace
        claude
      else
        echo 'Claude Code is not installed.'
      fi
      ;;
    3)
      claude --version 2>/dev/null || true
      claude doctor 2>/dev/null || true
      ;;
    4)
      ai-dev-status
      ;;
    5)
      cd /srv/workspace/robot-demo 2>/dev/null || { echo 'Robot example is not installed.'; continue; }
      printf 'Workspace: %s\n' "$PWD"
      printf 'Activate with: source .venv/bin/activate\n'
      ;;
    q|Q) exit 0 ;;
    *) echo 'Invalid selection.' ;;
  esac
done
FIRSTLOGIN
chmod 0755 /usr/local/bin/ai-dev-first-login

cat >/usr/local/bin/ai-dev-status <<EOF
#!/usr/bin/env bash
set -u
printf 'Host:              %s\n' "\$(hostname -f 2>/dev/null || hostname)"
printf 'DHCP/LAN address:  %s\n' "\$(hostname -I 2>/dev/null || true)"
printf 'SSH:               %s\n' "\$(systemctl is-active ssh 2>/dev/null || true)"
printf 'Development user:  %s\n' "$DEV_USER"
printf 'Python:            %s\n' "\$(python3 --version 2>&1)"
printf 'Git:               %s\n' "\$(git --version 2>&1)"
if command -v gh >/dev/null 2>&1; then printf 'GitHub CLI:        %s\n' "\$(gh --version 2>&1 | head -n 1)"; fi
if command -v claude >/dev/null 2>&1; then printf 'Claude Code:       %s\n' "\$(claude --version 2>&1 | head -n 1)"; fi
if command -v code-server >/dev/null 2>&1; then
  printf 'code-server:       %s\n' "\$(code-server --version 2>&1 | head -n 1)"
  printf 'Web IDE service:   %s\n' "\$(systemctl is-active code-server@$DEV_USER 2>/dev/null || true)"
  printf 'Web IDE URL:       http://%s:$CODE_SERVER_PORT\n' "\$(hostname -I 2>/dev/null | awk '{print \$1}')"
fi
printf 'Post-install log:  %s\n' "$LOG_FILE"
EOF
chmod 0755 /usr/local/bin/ai-dev-status

cat >/etc/motd <<EOF

AI Development LXC
------------------
Development user:  $DEV_USER
Workspace:         /srv/workspace
Web IDE:           http://<DHCP-IP>:$CODE_SERVER_PORT
First-login menu:  ai-dev-first-login
Environment status: ai-dev-status
Provisioning log:  $LOG_FILE

EOF

step "Verify services and summarize installation"
systemctl is-active ssh
if [[ $INSTALL_CODE_SERVER == yes ]]; then
  systemctl is-active "code-server@$DEV_USER.service"
fi
printf 'Addresses after provisioning: %s\n' "$(hostname -I 2>/dev/null || true)"
printf 'Claude Code: %s\n' "$(claude --version 2>&1 | head -n 1 || echo not-installed)"
printf 'code-server: %s\n' "$(code-server --version 2>&1 | head -n 1 || echo not-installed)"
printf 'Python: %s\n' "$(python3 --version 2>&1)"

rm -f "$ENV_FILE"
PROVISION_ELAPSED=$(( $(date +%s) - PROVISION_STARTED ))
log INFO "Post-install completed successfully in ${PROVISION_ELAPSED}s"
log INFO "Full LXC log: $LOG_FILE"
PROVISION
  chmod 0700 "$provision_file"

  run_step "Copy post-install configuration into LXC $CTID" \
    pct push "$CTID" "$env_file" /root/ai-dev-post-install.env --perms 0600
  run_step "Copy post-install provisioner into LXC $CTID" \
    pct push "$CTID" "$provision_file" /root/ai-dev-post-install.sh --perms 0700
  rm -rf "$tmp_dir"
}

get_lxc_ip() {
  pct exec "$CTID" -- bash -lc \
    "hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+(\.[0-9]+){3}$'" \
    2>/dev/null || true
}

wait_for_ip() {
  local ip="" count=0
  while ((count < 30)); do
    ip=$(get_lxc_ip)
    [[ -n $ip ]] && { printf '%s' "$ip"; return 0; }
    sleep 2
    ((count += 1))
    log_line INFO "Waiting for DHCP address $count/30"
  done
  return 1
}

write_access_file() {
  local ip=$1
  local file="/root/ai-dev-lxc-${CTID}-post-install-access.txt"
  {
    echo "AI Development LXC post-install"
    echo "================================"
    echo "Container ID: $CTID"
    echo "DHCP address: ${ip:-not detected}"
    echo "Development user: $DEV_USER"
    if [[ -n $DEV_PASSWORD ]]; then
      if [[ $PASSWORD_AUTH == yes ]]; then
        echo "Initial SSH and sudo password: $DEV_PASSWORD"
      else
        echo "Sudo password (SSH password login disabled): $DEV_PASSWORD"
      fi
    fi
    echo "SSH: ssh $DEV_USER@${ip:-LXC_IP}"
    if [[ $INSTALL_CODE_SERVER == yes ]]; then
      echo "Web IDE: http://${ip:-LXC_IP}:$CODE_SERVER_PORT"
      echo "Web IDE password: $CODE_SERVER_PASSWORD"
    fi
    echo "Proxmox web console mode: shell"
    echo "First-login menu: ai-dev-first-login"
    echo "Host log: $LOG_FILE"
    echo "LXC log: /var/log/ai-dev-post-install.log"
  } >"$file"
  chmod 0600 "$file"
  printf '%s' "$file"
}

write_managed_state() {
  local state_dir="/etc/claude-dev-lxc"
  local state_file="$state_dir/$CTID.conf"
  local hostname rootfs_storage bridge
  hostname=$(container_config_value hostname)
  rootfs_storage=$(container_config_value rootfs | cut -d: -f1)
  bridge=$(container_config_value net0 | sed -n 's/.*bridge=\([^,]*\).*/\1/p')
  install -d -m 0700 "$state_dir"
  {
    printf 'CTID=%q\n' "$CTID"
    printf 'CT_HOSTNAME=%q\n' "${hostname:-ai-dev}"
    printf 'DEV_USER=%q\n' "$DEV_USER"
    printf 'ACCESS_MODE=%q\n' "lan"
    printf 'CODE_SERVER_PORT=%q\n' "$CODE_SERVER_PORT"
    printf 'CODE_SERVER_PASSWORD=%q\n' "$CODE_SERVER_PASSWORD"
    printf 'PASSWORD_AUTH=%q\n' "$PASSWORD_AUTH"
    printf 'ROOTFS_STORAGE=%q\n' "$rootfs_storage"
    printf 'TEMPLATE_STORAGE=%q\n' ""
    printf 'BRIDGE=%q\n' "$bridge"
    printf 'SELECTED_AGENTS=%q\n' "claude"
    printf 'CREATED_AT=%q\n' "$(date --iso-8601=seconds)"
  } >"$state_file"
  chmod 0600 "$state_file"
  log_line INFO "Registered LXC $CTID for future Update/repair actions: $state_file"
}

show_summary() {
  local hostname status net0 selected
  hostname=$(container_config_value hostname)
  status=$(pct status "$CTID" 2>/dev/null | awk '{print $2}')
  net0=$(container_config_value net0)
  selected="code-server=$INSTALL_CODE_SERVER, Claude=$INSTALL_CLAUDE, Robot=$INSTALL_ROBOT, GitHub=$INSTALL_GITHUB"
  whiptail --backtitle "$BACKTITLE" --title "CONFIRM POST-INSTALL" --scrolltext --yesno \
    "Container:       $CTID (${hostname:-unknown})
Status:          $status
Primary network: $net0
Network policy:  DHCP and direct LAN access
Proxmox console: cmode=shell
Development user: $DEV_USER
SSH password auth: $PASSWORD_AUTH
Web IDE port:   $CODE_SERVER_PORT
Components:     $selected
System upgrade: $UPGRADE_PACKAGES

The script is idempotent and preserves files under /srv/workspace. Continue?" 26 94
}

main() {
  require_root
  check_proxmox_host
  ensure_whiptail
  init_logging

  whiptail --backtitle "$BACKTITLE" --title "AI DEVELOPMENT POST-INSTALL" --msgbox \
    "Use this utility after creating a Debian LXC in Proxmox.

It configures DHCP-based direct LAN access, SSH, code-server, Python, Robot Framework, GitHub CLI, Claude Code, verbose logs, and a working Proxmox web console.

The Proxmox console fix sets cmode=shell, which opens a root shell directly instead of depending on an in-container TTY login service." 20 88

  select_container
  collect_user_settings
  collect_components
  if [[ $INSTALL_CODE_SERVER == yes ]]; then
    collect_web_settings
  fi
  collect_git_identity
  show_summary || exit 0

  begin_verbose_output
  log_line INFO "Selected LXC $CTID"
  log_line INFO "All actions are streamed to the console and $LOG_FILE"
  prepare_container
  write_payload
  run_step "Provision AI development environment inside LXC $CTID" \
    pct exec "$CTID" -- /root/ai-dev-post-install.sh
  pct exec "$CTID" -- rm -f /root/ai-dev-post-install.sh /root/ai-dev-post-install.env >/dev/null 2>&1 || true

  local ip access_file
  ip=$(wait_for_ip || true)
  write_managed_state
  access_file=$(write_access_file "$ip")

  log_line INFO "Post-install completed for LXC $CTID"
  log_line INFO "DHCP address: ${ip:-not detected}"
  log_line INFO "Access details: $access_file"

  local web_summary="" password_summary=""
  if [[ -n $DEV_PASSWORD ]]; then
    if [[ $PASSWORD_AUTH == yes ]]; then
      password_summary="Initial SSH and sudo password: $DEV_PASSWORD"
    else
      password_summary="Sudo password (SSH password login disabled): $DEV_PASSWORD"
    fi
  fi
  if [[ $INSTALL_CODE_SERVER == yes ]]; then
    web_summary="Web IDE: http://${ip:-LXC_IP}:$CODE_SERVER_PORT
Web IDE password: $CODE_SERVER_PASSWORD
"
  fi
  whiptail --backtitle "$BACKTITLE" --title "POST-INSTALL COMPLETE" --scrolltext --msgbox \
    "LXC $CTID is configured.

DHCP address: ${ip:-not detected}
SSH: ssh $DEV_USER@${ip:-LXC_IP}
$password_summary
$web_summary
Proxmox web console:
Open the container Console in the Proxmox UI. It now uses cmode=shell and should open a root shell directly.

Complete Claude and GitHub authentication from SSH or the code-server terminal:
  ai-dev-first-login

Host log:
$LOG_FILE

LXC log:
/var/log/ai-dev-post-install.log

Access details:
$access_file" 32 96
}

main "$@"
