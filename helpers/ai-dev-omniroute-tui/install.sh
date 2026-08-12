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

usage() {
  cat <<'EOF'
Usage: install.sh [--guest] [--ctid ID] [--user NAME] [--yes]

Run with no flags (or --ctid) on a Proxmox VE host to create a new,
unprivileged Debian LXC and install AI Dev OmniRoute TUI inside it.

Run --guest, or run this script directly inside an existing
Debian/Ubuntu container or VM, to just install the TUI locally for the
current user.

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
  local storage=$1 file
  pveam update >/dev/null 2>&1 || true
  file=$(pveam available --section system 2>/dev/null | awk '$2 ~ /^debian-13-standard/{print $2}' | sort -V | tail -1)
  if [[ -z "$file" ]]; then
    file=$(pveam available --section system 2>/dev/null | awk '$2 ~ /^debian-12-standard/{print $2}' | sort -V | tail -1)
  fi
  [[ -n "$file" ]] || { echo "No Debian LXC template found via 'pveam available'." >&2; exit 1; }
  if ! pveam list "$storage" 2>/dev/null | awk 'NR>1{print $1}' | grep -Fxq "${storage}:vztmpl/${file}"; then
    echo "Downloading $file to $storage..." >&2
    pveam download "$storage" "$file" >&2
  fi
  printf '%s' "$file"
}

host_wait_ready() {
  local id=$1 i
  for i in $(seq 1 60); do
    pct exec "$id" -- true >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

host_create_and_provision() {
  [[ "$(id -u)" -eq 0 ]] || { echo "Run as root on the Proxmox host." >&2; exit 1; }
  command -v pct >/dev/null 2>&1 || { echo "pct not found; run this on a Proxmox VE host, or pass --guest." >&2; exit 1; }

  [[ -n "$CTID" ]] || CTID=$(host_next_ctid)
  [[ "$CTID" =~ ^[1-9][0-9]{1,8}$ ]] || { echo "Could not determine a valid free CTID; pass --ctid explicitly." >&2; exit 1; }

  local template_storage rootfs_storage bridge template_file
  template_storage=$(host_pick_storage vztmpl); : "${template_storage:=local}"
  rootfs_storage=$(host_pick_storage rootdir); : "${rootfs_storage:=local-lvm}"
  bridge=$(host_default_bridge); : "${bridge:=vmbr0}"

  if pct status "$CTID" >/dev/null 2>&1; then
    echo "LXC $CTID already exists; provisioning it directly."
  else
    template_file=$(host_ensure_template "$template_storage")
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
    pct create "$CTID" "${template_storage}:vztmpl/${template_file}" \
      --hostname ai-dev-omniroute \
      --cores 2 --memory 2048 --swap 512 \
      --rootfs "${rootfs_storage}:8" \
      --net0 "name=eth0,bridge=${bridge},ip=dhcp" \
      --unprivileged 1 \
      --features nesting=1,keyctl=1 \
      --onboot 1
  fi

  if [[ "$(pct status "$CTID" | awk '{print $2}')" != running ]]; then
    pct start "$CTID"
  fi
  host_wait_ready "$CTID" || { echo "LXC $CTID did not become ready in time." >&2; exit 1; }

  echo "Installing base packages inside LXC $CTID..."
  pct exec "$CTID" -- bash -lc 'apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y sudo openssh-server && systemctl enable --now ssh'
  if ! pct exec "$CTID" -- id "$DEV_USER" >/dev/null 2>&1; then
    pct exec "$CTID" -- useradd -m -s /bin/bash "$DEV_USER"
  fi
  pct exec "$CTID" -- bash -c 'user=$1; printf "%s ALL=(ALL) NOPASSWD:ALL\n" "$user" >"/etc/sudoers.d/90-$user"; chmod 0440 "/etc/sudoers.d/90-$user"' _ "$DEV_USER"

  echo "Pushing AI Dev OmniRoute TUI into LXC $CTID..."
  local archive
  archive=$(mktemp --suffix=.tar.gz)
  if ! tar -czf "$archive" -C "$(dirname "$SCRIPT_DIR")" "$(basename "$SCRIPT_DIR")"; then
    rm -f "$archive"
    return 1
  fi
  if ! pct push "$CTID" "$archive" /root/ai-dev-omniroute-tui.tar.gz --perms 0600; then
    rm -f "$archive"
    return 1
  fi
  rm -f "$archive"
  pct exec "$CTID" -- rm -rf /opt/ai-dev-omniroute-tui
  pct exec "$CTID" -- mkdir -p /opt/ai-dev-omniroute-tui
  pct exec "$CTID" -- tar -xzf /root/ai-dev-omniroute-tui.tar.gz -C /opt/ai-dev-omniroute-tui --strip-components=1
  pct exec "$CTID" -- rm -f /root/ai-dev-omniroute-tui.tar.gz
  pct exec "$CTID" -- chown -R "$DEV_USER:$DEV_USER" /opt/ai-dev-omniroute-tui

  echo "Installing AI Dev OmniRoute TUI as $DEV_USER..."
  pct exec "$CTID" -- runuser -u "$DEV_USER" -- /opt/ai-dev-omniroute-tui/install.sh --guest

  local ip
  ip=$(pct exec "$CTID" -- hostname -I 2>/dev/null | awk '{print $1}')
  echo
  echo "LXC $CTID (ai-dev-omniroute) is ready."
  echo "  Console: pct enter $CTID , then: su - $DEV_USER"
  if [[ -n "$ip" ]]; then
    echo "  SSH:     ssh ${DEV_USER}@${ip} (configure a password or SSH key first)"
  fi
  echo "  Then run: ai-dev-tui"
}

if ! $GUEST_MODE && command -v pct >/dev/null 2>&1 && [[ -d /etc/pve ]]; then
  host_create_and_provision
  exit 0
fi

# ---------- Guest/local mode: install the TUI for the current user ----------

echo "Installing AI Dev OmniRoute TUI..."

if command -v apt-get >/dev/null 2>&1; then
  sudo_cmd apt-get update
  sudo_cmd apt-get install -y dialog curl git jq ca-certificates
fi

mkdir -p "$TARGET_DIR"
install -m 0755 "$APP_SRC" "$TARGET"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *)
    cat >>"$HOME/.profile" <<'EOF'

# User-local binaries
if [ -d "$HOME/.local/bin" ]; then
  PATH="$HOME/.local/bin:$PATH"
fi
EOF
    ;;
esac

echo
echo "Installed: $TARGET"
echo "Run:"
echo "  $TARGET"
echo
echo "Or open a new login shell and run:"
echo "  ai-dev-tui"
