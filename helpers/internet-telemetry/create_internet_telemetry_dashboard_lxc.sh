#!/usr/bin/env bash
#
# create_internet_telemetry_dashboard_lxc.sh
#
# Creates a Debian LXC container on a Proxmox VE host and installs the
# internet-telemetry monitoring service + web dashboard inside it.
#
# EDIT THE CONFIGURATION BLOCK BELOW BEFORE RUNNING.
# Every variable can also be overridden via environment, e.g.:
#   OUTAGE_AFTER_SEC=30 ./create_internet_telemetry_dashboard_lxc.sh
#
# Run as root on the Proxmox host, from the directory that also contains:
#   network_telemetry_dashboard.py
#   internet-telemetry-dashboard.service
#   internet-telemetry.logrotate
#
set -euo pipefail

# =============================================================================
# USER CONFIGURATION — edit these values for your network
# =============================================================================
: "${CTID:=120}"
: "${CT_HOSTNAME:=internet-telemetry}"
: "${TEMPLATE_STORAGE:=local}"
: "${ROOTFS_STORAGE:=local-lvm}"
: "${DISK_GB:=8}"
: "${CORES:=1}"
: "${MEMORY_MB:=512}"
: "${SWAP_MB:=256}"
: "${BRIDGE:=vmbr0}"
: "${LAN_IP_CIDR:=192.168.1.20/24}"       # static IP of the monitoring container
: "${GATEWAY:=192.168.1.1}"
: "${DNS_SERVER:=192.168.1.1}"

: "${DREAM_IP:=192.168.1.1}"              # Dream Router LAN IP
: "${PROVIDER_IPS:=192.168.100.1 192.168.0.1}"   # space-separated
: "${PUBLIC_PINGS:=1.1.1.1 8.8.8.8 9.9.9.9}"     # space-separated
: "${DNS_NAMES:=google.com cloudflare.com ui.com}"
: "${TCP_TARGETS:=1.1.1.1:443 8.8.8.8:53 google.com:443}"

: "${INTERVAL_SEC:=10}"
: "${OUTAGE_AFTER_SEC:=600}"
: "${LATENCY_WARNING_MS:=150}"
: "${TRAFFIC_LIMIT_PCT:=3.0}"
: "${MIN_DOWNLINK_MBPS:=10}"
: "${MIN_UPLINK_MBPS:=2}"
: "${DASHBOARD_BIND:=0.0.0.0}"
: "${DASHBOARD_PORT:=8080}"
: "${ASSUME_YES:=0}"                       # set 1 to skip the confirmation prompt
# =============================================================================

SERVICE_NAME="internet-telemetry-dashboard.service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_FILE="$SCRIPT_DIR/network_telemetry_dashboard.py"
UNIT_FILE="$SCRIPT_DIR/internet-telemetry-dashboard.service"
LOGROTATE_FILE="$SCRIPT_DIR/internet-telemetry.logrotate"
LAN_IP="${LAN_IP_CIDR%%/*}"

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ]            || die "This script must run as root on the Proxmox host."
command -v pct  >/dev/null 2>&1 || die "pct not found. Run this on a Proxmox VE host."
command -v pveam >/dev/null 2>&1 || die "pveam not found. Run this on a Proxmox VE host."
[ -f "$APP_FILE" ]              || die "Missing $APP_FILE (must sit next to this script)."
[ -f "$UNIT_FILE" ]             || die "Missing $UNIT_FILE (must sit next to this script)."
[ -f "$LOGROTATE_FILE" ]        || die "Missing $LOGROTATE_FILE (must sit next to this script)."

if pct status "$CTID" >/dev/null 2>&1; then
    die "Container CTID $CTID already exists. Choose another CTID."
fi

# ---------------------------------------------------------------------------
# Show configuration and confirm
# ---------------------------------------------------------------------------
cat <<EOF

  Internet telemetry LXC — configuration review
  ---------------------------------------------
  CTID / hostname     : $CTID / $CT_HOSTNAME
  Storage             : template=$TEMPLATE_STORAGE rootfs=$ROOTFS_STORAGE
  Resources           : ${CORES} core, ${MEMORY_MB} MB RAM, ${SWAP_MB} MB swap, ${DISK_GB} GB disk
  Bridge              : $BRIDGE
  Container IP        : $LAN_IP_CIDR (gateway $GATEWAY, DNS $DNS_SERVER)

  Dream Router IP     : $DREAM_IP
  Provider IPs        : $PROVIDER_IPS
  Public ping targets : $PUBLIC_PINGS
  DNS names           : $DNS_NAMES
  TCP targets         : $TCP_TARGETS

  Interval / outage   : ${INTERVAL_SEC}s / ${OUTAGE_AFTER_SEC}s
  Traffic budget      : ${TRAFFIC_LIMIT_PCT}% of min(${MIN_DOWNLINK_MBPS}, ${MIN_UPLINK_MBPS}) Mbps
  Dashboard           : http://${LAN_IP}:${DASHBOARD_PORT}  (bind $DASHBOARD_BIND)

EOF
if [ "$ASSUME_YES" != "1" ]; then
    read -r -p "Create container with these settings? [y/N] " ans
    case "$ans" in [yY]|[yY][eE][sS]) ;; *) die "Aborted by user. Edit the configuration block and rerun." ;; esac
fi

# ---------------------------------------------------------------------------
# Debian template
# ---------------------------------------------------------------------------
info "Locating Debian LXC template"
pveam update >/dev/null 2>&1 || true
TEMPLATE_NAME="$(pveam available --section system 2>/dev/null \
    | awk '{print $2}' | grep -E '^debian-1[2-9].*standard.*(amd64|arm64)' | sort -V | tail -1 || true)"
[ -n "$TEMPLATE_NAME" ] || die "No debian-12+ standard template found via 'pveam available'."

if ! pveam list "$TEMPLATE_STORAGE" 2>/dev/null | grep -q "$TEMPLATE_NAME"; then
    info "Downloading template $TEMPLATE_NAME to $TEMPLATE_STORAGE"
    pveam download "$TEMPLATE_STORAGE" "$TEMPLATE_NAME"
else
    info "Template $TEMPLATE_NAME already present"
fi
TEMPLATE_REF="${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE_NAME}"

# ---------------------------------------------------------------------------
# Create + start container
# ---------------------------------------------------------------------------
info "Creating unprivileged LXC $CTID ($CT_HOSTNAME)"
pct create "$CTID" "$TEMPLATE_REF" \
    --hostname "$CT_HOSTNAME" \
    --unprivileged 1 \
    --cores "$CORES" \
    --memory "$MEMORY_MB" \
    --swap "$SWAP_MB" \
    --rootfs "${ROOTFS_STORAGE}:${DISK_GB}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=${LAN_IP_CIDR},gw=${GATEWAY}" \
    --nameserver "$DNS_SERVER" \
    --onboot 1 \
    --start 0

info "Starting container"
pct start "$CTID"

info "Waiting for container network"
for i in $(seq 1 30); do
    if pct exec "$CTID" -- ip -4 addr show eth0 2>/dev/null | grep -q "inet "; then
        break
    fi
    sleep 2
    [ "$i" -eq 30 ] && die "Container network did not come up."
done

# ---------------------------------------------------------------------------
# Install packages inside the container
# ---------------------------------------------------------------------------
info "Installing packages inside the container (this can take a minute)"
pct exec "$CTID" -- bash -c \
    "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && \
     apt-get install -y -qq python3 iputils-ping iproute2 dnsutils curl ca-certificates nano logrotate"

# ---------------------------------------------------------------------------
# Verify ICMP works inside the unprivileged LXC
# ---------------------------------------------------------------------------
info "Verifying ICMP ping works inside the container"
if ! pct exec "$CTID" -- ping -c1 -W2 "$GATEWAY" >/dev/null 2>&1; then
    cat >&2 <<'EOF'
ERROR: ping does not work inside the unprivileged container.

Every telemetry sample would be COLLECTOR_ERROR. Common cause: the kernel
sysctl net.ipv4.ping_group_range does not cover the container's mapped GIDs.

Fix on the Proxmox HOST, then restart the container:

    echo 'net.ipv4.ping_group_range = 0 2147483647' > /etc/sysctl.d/99-ping.conf
    sysctl --system
    pct restart <CTID>

Then rerun the failed check:

    pct exec <CTID> -- ping -c1 <GATEWAY>
EOF
    exit 1
fi

info "Testing provider router IPs (informational only)"
for ip in $PROVIDER_IPS; do
    if pct exec "$CTID" -- ping -c1 -W2 "$ip" >/dev/null 2>&1; then
        echo "    provider $ip: answers"
    else
        echo "    provider $ip: no answer (expected in ISP bridge mode; WAN_DOWN fallback will apply)"
    fi
done

# ---------------------------------------------------------------------------
# Deploy application, config, systemd unit, logrotate
# ---------------------------------------------------------------------------
info "Deploying application files"
pct exec "$CTID" -- mkdir -p /opt/internet-telemetry /etc/internet-telemetry /var/log/internet-telemetry/events
pct push "$CTID" "$APP_FILE"       /opt/internet-telemetry/network_telemetry_dashboard.py
pct push "$CTID" "$UNIT_FILE"      /etc/systemd/system/internet-telemetry-dashboard.service
pct push "$CTID" "$LOGROTATE_FILE" /etc/logrotate.d/internet-telemetry

# Build config.json from the variables above.
json_array() { # space-separated words -> ["a","b"]
    local out="[" first=1 w
    for w in $1; do
        [ $first -eq 1 ] && first=0 || out+=","
        out+="\"$w\""
    done
    echo "${out}]"
}
CONFIG_TMP="$(mktemp)"
cat > "$CONFIG_TMP" <<EOF
{
  "dream_ip": "$DREAM_IP",
  "provider_ips": $(json_array "$PROVIDER_IPS"),
  "public_ping_targets": $(json_array "$PUBLIC_PINGS"),
  "dns_names": $(json_array "$DNS_NAMES"),
  "tcp_targets": $(json_array "$TCP_TARGETS"),
  "interval_sec": $INTERVAL_SEC,
  "outage_after_sec": $OUTAGE_AFTER_SEC,
  "latency_warning_ms": $LATENCY_WARNING_MS,
  "state_confirm_samples": 2,
  "slow_consecutive_samples": 3,
  "monitoring_traffic_limit_percent": $TRAFFIC_LIMIT_PCT,
  "minimum_expected_downlink_mbps": $MIN_DOWNLINK_MBPS,
  "minimum_expected_uplink_mbps": $MIN_UPLINK_MBPS,
  "adaptive_backoff_enabled": true,
  "dashboard_bind": "$DASHBOARD_BIND",
  "dashboard_port": $DASHBOARD_PORT,
  "log_dir": "/var/log/internet-telemetry",
  "keep_samples": 360
}
EOF
pct push "$CTID" "$CONFIG_TMP" /etc/internet-telemetry/config.json
rm -f "$CONFIG_TMP"

info "Enabling and starting $SERVICE_NAME"
pct exec "$CTID" -- systemctl daemon-reload
pct exec "$CTID" -- systemctl enable --now internet-telemetry-dashboard.service

info "Waiting for the dashboard to answer"
DASH_OK=0
for i in $(seq 1 15); do
    if pct exec "$CTID" -- curl -fsS "http://127.0.0.1:${DASHBOARD_PORT}/healthz" >/dev/null 2>&1; then
        DASH_OK=1; break
    fi
    sleep 2
done
if [ "$DASH_OK" -ne 1 ]; then
    echo "WARNING: dashboard did not answer on /healthz yet. Check:" >&2
    echo "    pct exec $CTID -- journalctl -u $SERVICE_NAME -n 50" >&2
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
cat <<EOF

============================================================
  Internet telemetry container is ready
============================================================

  Container ID : $CTID
  Hostname     : $CT_HOSTNAME
  Container IP : $LAN_IP
  Service      : $SERVICE_NAME
  Log dir      : /var/log/internet-telemetry

Dashboard available at:

    http://${LAN_IP}:${DASHBOARD_PORT}

Configuration page:

    http://${LAN_IP}:${DASHBOARD_PORT}/config

Useful commands:

    pct enter $CTID
    pct exec $CTID -- systemctl status $SERVICE_NAME
    pct exec $CTID -- journalctl -u $SERVICE_NAME -f
    pct exec $CTID -- ls -lah /var/log/internet-telemetry
    pct exec $CTID -- tail -n 20 /var/log/internet-telemetry/summary_*.csv

If you ever lock yourself out by changing the dashboard bind/port:

    pct exec $CTID -- nano /etc/internet-telemetry/config.json
    pct exec $CTID -- systemctl restart $SERVICE_NAME

EOF
