#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_SRC="$SCRIPT_DIR/ai-dev-tui"
TARGET_DIR="${HOME}/.local/bin"
TARGET="${TARGET_DIR}/ai-dev-tui"

GUEST_MODE=false
CTID=""
DEV_USER="dev"
ASSUME_YES=false
HOST_TEMPLATE_FILE=""

usage() {
  cat <<'EOF'
Usage: install.sh [--guest] [--ctid ID] [--user NAME] [--yes]

Run with no flags (or --ctid) on a Proxmox VE host to create a new,
unprivileged Debian LXC and install AI Dev OmniRoute TUI inside it.

Run --guest, or run this script directly inside an existing
Debian/Ubuntu container or VM, to just install the TUI locally for the
current user.

The installer is intentionally verbose: each meaningful step and command is
printed to the console and command output is streamed live. Only short polling
and existence probes are kept quiet.

  --ctid ID     Create/use this specific CTID instead of auto-allocating one
  --user NAME   Non-root user created inside the new LXC (default: dev)
  --yes         Skip the confirmation prompt before creating the LXC
  --guest       Force local install; skip Proxmox host detection
EOF
}

while (($#)); do
  case "$1" in
    --guest) GUEST_MODE=true; shift ;;
    --ctid) CTID=${2:?missing CTID}; shift 2 ;;
    --user) DEV_USER=${2:?missing username}; shift 2 ;;
    --yes|--non-interactive) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# DEV_USER is passed to useradd/runuser/chown and is also used as part of a
# sudoers filename. Restrict it to a normal portable Linux account name before
# any guest or host-side command runs.
if [[ ! "$DEV_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
  echo "Invalid --user value: $DEV_USER" >&2
  echo "Use 1-32 lowercase letters, digits, underscores or hyphens; the first character must be a letter or underscore." >&2
  exit 2
fi

if [[ -n "$CTID" && ! "$CTID" =~ ^[1-9][0-9]{1,8}$ ]]; then
  echo "Invalid --ctid value: $CTID" >&2
  exit 2
fi

stamp() {
  date '+%F %T'
}

step() {
  printf '\n[%s] ==== %s ====\n' "$(stamp)" "$*" >&2
}

info() {
  printf '[%s] INFO: %s\n' "$(stamp)" "$*" >&2
}

warn() {
  printf '[%s] WARNING: %s\n' "$(stamp)" "$*" >&2
}

print_command() {
  printf '[%s] + ' "$(stamp)" >&2
  printf '%q ' "$@" >&2
  printf '\n' >&2
}

run_cmd() {
  print_command "$@"
  "$@"
}

sudo_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "sudo is required to install OS packages." >&2
    exit 1
  fi
}

# ---------- Proxmox host mode: create an LXC, then install inside it ----------

host_next_ctid() {
  pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9'
}

host_pick_storage() {
  local content=$1
  pvesm status --content "$content" 2>/dev/null | awk 'NR==2{print $1}' || true
}

host_default_bridge() {
  ip -o link show type bridge 2>/dev/null | awk -F': ' '{print $2}' | grep -m1 '^vmbr' || true
}

host_ensure_template() {
  local storage=$1 available installed

  step "Refresh Proxmox LXC template catalog"
  print_command pveam update
  if ! pveam update; then
    warn "pveam update failed; continuing with the currently available catalog."
  fi

  step "Inspect available Debian templates"
  print_command pveam available --section system
  available=$(pveam available --section system)
  printf '%s\n' "$available"

  HOST_TEMPLATE_FILE=$(printf '%s\n' "$available" | awk '$2 ~ /^debian-13-standard/{print $2}' | sort -V | tail -1)
  if [[ -z "$HOST_TEMPLATE_FILE" ]]; then
    HOST_TEMPLATE_FILE=$(printf '%s\n' "$available" | awk '$2 ~ /^debian-12-standard/{print $2}' | sort -V | tail -1)
  fi
  [[ -n "$HOST_TEMPLATE_FILE" ]] || { echo "No Debian LXC template found via 'pveam available'." >&2; exit 1; }
  info "Selected template: $HOST_TEMPLATE_FILE"

  step "Inspect templates already stored on $storage"
  print_command pveam list "$storage"
  installed=$(pveam list "$storage" 2>/dev/null || true)
  [[ -n "$installed" ]] && printf '%s\n' "$installed"

  if ! printf '%s\n' "$installed" | awk 'NR>1{print $1}' | grep -Fxq "${storage}:vztmpl/${HOST_TEMPLATE_FILE}"; then
    step "Download Debian template"
    run_cmd pveam download "$storage" "$HOST_TEMPLATE_FILE"
  else
    info "Template is already present on $storage."
  fi
}

host_wait_ready() {
  local id=$1 i
  step "Wait for LXC $id command execution"
  for i in $(seq 1 60); do
    if pct exec "$id" -- true >/dev/null 2>&1; then
      info "LXC $id is ready after attempt $i/60."
      return 0
    fi
    info "LXC $id not ready yet (attempt $i/60); retrying in 2 seconds."
    sleep 2
  done
  return 1
}

host_create_and_provision() {
  [[ "$(id -u)" -eq 0 ]] || { echo "Run as root on the Proxmox host." >&2; exit 1; }
  command -v pct >/dev/null 2>&1 || { echo "pct not found; run this on a Proxmox VE host, or pass --guest." >&2; exit 1; }

  step "Resolve Proxmox defaults"
  if [[ -z "$CTID" ]]; then
    CTID=$(host_next_ctid)
    info "Auto-selected next free CTID: ${CTID:-unavailable}"
  else
    info "Using requested CTID: $CTID"
  fi
  [[ "$CTID" =~ ^[1-9][0-9]{1,8}$ ]] || { echo "Could not determine a valid free CTID; pass --ctid explicitly." >&2; exit 1; }

  local template_storage rootfs_storage bridge template_file
  template_storage=$(host_pick_storage vztmpl); : "${template_storage:=local}"
  rootfs_storage=$(host_pick_storage rootdir); : "${rootfs_storage:=local-lvm}"
  bridge=$(host_default_bridge); : "${bridge:=vmbr0}"
  info "Template storage: $template_storage"
  info "Rootfs storage:   $rootfs_storage"
  info "Network bridge:   $bridge"

  if pct status "$CTID" >/dev/null 2>&1; then
    step "Use existing LXC $CTID"
    run_cmd pct status "$CTID"
    run_cmd pct config "$CTID"
    info "LXC $CTID already exists; provisioning it directly."
  else
    host_ensure_template "$template_storage"
    template_file=$HOST_TEMPLATE_FILE
    echo
    echo "About to create LXC $CTID:"
    echo "  Hostname:   ai-dev-omniroute"
    echo "  Template:   ${template_storage}:vztmpl/${template_file}"
    echo "  Resources:  2 cores / 2048 MB RAM / 512 MB swap / 8 GB disk on $rootfs_storage"
    echo "  Network:    DHCP on $bridge"
    echo "  Dev user:   $DEV_USER (passwordless sudo)"
    echo
    if ! $ASSUME_YES; then
      read -r -p "Proceed? [y/N] " reply
      [[ "$reply" =~ ^[Yy] ]] || { echo "Aborted."; exit 0; }
    fi

    step "Create LXC $CTID"
    run_cmd pct create "$CTID" "${template_storage}:vztmpl/${template_file}" \
      --hostname ai-dev-omniroute \
      --cores 2 --memory 2048 --swap 512 \
      --rootfs "${rootfs_storage}:8" \
      --net0 "name=eth0,bridge=${bridge},ip=dhcp" \
      --unprivileged 1 \
      --features nesting=1,keyctl=1 \
      --onboot 1
  fi

  step "Ensure LXC $CTID is running"
  local ct_status
  ct_status=$(pct status "$CTID" | awk '{print $2}')
  info "Current state: ${ct_status:-unknown}"
  if [[ "$ct_status" != running ]]; then
    run_cmd pct start "$CTID"
  else
    info "LXC $CTID is already running."
  fi
  host_wait_ready "$CTID" || { echo "LXC $CTID did not become ready in time." >&2; exit 1; }

  step "Install base packages inside LXC $CTID"
  run_cmd pct exec "$CTID" -- bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y sudo openssh-server && systemctl enable --now ssh'

  step "Create or verify development user $DEV_USER"
  if ! pct exec "$CTID" -- id "$DEV_USER" >/dev/null 2>&1; then
    run_cmd pct exec "$CTID" -- useradd -m -s /bin/bash "$DEV_USER"
  else
    info "User $DEV_USER already exists."
  fi

  step "Configure passwordless sudo for $DEV_USER"
  run_cmd pct exec "$CTID" -- bash -c 'user=$1; printf "%s ALL=(ALL) NOPASSWD:ALL\n" "$user" >"/etc/sudoers.d/90-$user"; chmod 0440 "/etc/sudoers.d/90-$user"' _ "$DEV_USER"

  step "Build OmniRoute TUI provisioning archive"
  local archive
  archive=$(mktemp --suffix=.tar.gz)
  info "Temporary archive: $archive"
  if ! run_cmd tar -czf "$archive" -C "$(dirname "$SCRIPT_DIR")" "$(basename "$SCRIPT_DIR")"; then
    rm -f "$archive"
    return 1
  fi
  run_cmd ls -lh "$archive"

  step "Push provisioning archive into LXC $CTID"
  if ! run_cmd pct push "$CTID" "$archive" /root/ai-dev-omniroute-tui.tar.gz --perms 0600; then
    rm -f "$archive"
    return 1
  fi
  run_cmd rm -f "$archive"

  step "Extract OmniRoute TUI inside LXC $CTID"
  run_cmd pct exec "$CTID" -- rm -rf /opt/ai-dev-omniroute-tui
  run_cmd pct exec "$CTID" -- mkdir -p /opt/ai-dev-omniroute-tui
  run_cmd pct exec "$CTID" -- tar -xzf /root/ai-dev-omniroute-tui.tar.gz -C /opt/ai-dev-omniroute-tui --strip-components=1
  run_cmd pct exec "$CTID" -- rm -f /root/ai-dev-omniroute-tui.tar.gz
  run_cmd pct exec "$CTID" -- chown -R "$DEV_USER:$DEV_USER" /opt/ai-dev-omniroute-tui

  step "Install AI Dev OmniRoute TUI as $DEV_USER"
  run_cmd pct exec "$CTID" -- runuser -u "$DEV_USER" -- /opt/ai-dev-omniroute-tui/install.sh --guest

  step "Collect final container status"
  run_cmd pct status "$CTID"
  local ip
  ip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
  info "Detected LXC IP: ${ip:-unavailable}"

  echo
  echo "LXC $CTID (ai-dev-omniroute) is ready."
  echo "  Console: pct enter $CTID , then: su - $DEV_USER"
  if [[ -n "$ip" ]]; then
    echo "  SSH:     ssh ${DEV_USER}@${ip} (configure a password or SSH key first)"
  fi
  echo "  Then run: ai-dev-tui"
}

if ! $GUEST_MODE && command -v pct >/dev/null 2>&1 && [[ -d /etc/pve ]]; then
  step "AI Dev OmniRoute LXC installer started on Proxmox host"
  host_create_and_provision
  exit 0
fi

# ---------- Guest/local mode: install the TUI for the current user ----------

step "Install AI Dev OmniRoute TUI locally"
info "Current user: $(id -un)"
info "Target: $TARGET"

if command -v apt-get >/dev/null 2>&1; then
  step "Install local TUI dependencies"
  print_command sudo_cmd apt-get update
  sudo_cmd apt-get update
  print_command sudo_cmd apt-get install -y dialog curl git jq ca-certificates
  sudo_cmd apt-get install -y dialog curl git jq ca-certificates
fi

step "Install TUI executable"
run_cmd mkdir -p "$TARGET_DIR"
run_cmd install -m 0755 "$APP_SRC" "$TARGET"

case ":$PATH:" in
  *":$HOME/.local/bin:"*)
    info "$HOME/.local/bin is already on PATH."
    ;;
  *)
    step "Add user-local binaries to login PATH"
    cat >>"$HOME/.profile" <<'EOF'

# User-local binaries
if [ -d "$HOME/.local/bin" ]; then
  PATH="$HOME/.local/bin:$PATH"
fi
EOF
    info "Updated $HOME/.profile."
    ;;
esac

echo
echo "Installed: $TARGET"
echo "Run:"
echo "  $TARGET"
echo
echo "Or open a new login shell and run:"
echo "  ai-dev-tui"
