#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Proxy/SSO overlay for ai-dev-claude-no-docker.sh.
#
# Creates/re-provisions the LXC with the proven no-Docker helper, then converts
# all browser-facing services to localhost-only backends behind Caddy +
# Authelia. One Authelia login unlocks the dashboard, code-server,
# FileBrowser Quantum, and ttyd. Docker is never installed by this wrapper.

set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_VERSION="0.1.0"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_HELPER="$SCRIPT_DIR/ai-dev-claude-no-docker.sh"
readonly STATE_DIR="/etc/ai-dev-claude"
readonly LOG_DIR="/var/log/ai-dev-claude"
readonly AUTHELIA_KEY_FINGERPRINT="192085915BD608A458AC58DCE461FA1531286EEA"

CTID=""
ASSUME_YES=false
SSO_DOMAIN=""
SSO_DOMAIN_EXPLICIT=false
SSO_USERNAME=""
SSO_PASSWORD=""
SESSION_SECRET=""
STORAGE_ENCRYPTION_KEY=""
RESET_JWT_SECRET=""
LOG_FILE=""

usage() {
  cat <<EOF
$SCRIPT_NAME v$SCRIPT_VERSION

Usage:
  $SCRIPT_NAME [--ctid ID] [--domain DOMAIN] [--yes]
  $SCRIPT_NAME --help
  $SCRIPT_NAME --version

Creates/re-provisions the normal Docker-free Claude development LXC, then
adds a localhost-only reverse-proxy/SSO layer:

  Caddy + Authelia -> one web login
  Dashboard        -> https://home.DOMAIN
  code-server      -> https://code.DOMAIN
  FileBrowser      -> https://files.DOMAIN
  ttyd             -> https://term.DOMAIN
  Authelia portal  -> https://auth.DOMAIN

DOMAIN must be a normal DNS domain you control or can override in local DNS,
for example: dev.example.net. Special-use names such as .local, .localhost,
.home.arpa, .test, .invalid, and .example are intentionally rejected because
Authelia's shared-cookie SSO expects a normal multi-label domain.

The proxy uses Caddy's internal CA, so client devices must trust the generated
Caddy root certificate. The script copies that certificate to the Proxmox host
and prints its path at the end.

Options:
  --ctid ID       Create/re-provision this CTID. If omitted, allocate next ID.
  --domain NAME   SSO base domain (services become auth.NAME, home.NAME, ...).
  --yes           Non-interactive. Requires --domain for a new proxy setup.
  --version, -v   Print version.
  --help, -h      Show help.
EOF
}

while (($#)); do
  case "$1" in
    --ctid)
      CTID=${2:?missing CTID}
      shift 2
      ;;
    --domain)
      SSO_DOMAIN=${2:?missing domain}
      SSO_DOMAIN_EXPLICIT=true
      shift 2
      ;;
    --yes|--non-interactive|--auto)
      ASSUME_YES=true
      shift
      ;;
    --version|-v)
      printf '%s\n' "$SCRIPT_VERSION"
      exit 0
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"
}

fail() {
  echo "ERROR: $*" >&2
  [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]] && echo "Log: $LOG_FILE" >&2
  exit 1
}

valid_domain() {
  local domain=${1,,}
  [[ "$domain" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]] || return 1
  case "$domain" in
    localhost|*.localhost|local|*.local|home.arpa|*.home.arpa|test|*.test|invalid|*.invalid|example|*.example)
      return 1
      ;;
  esac
}

next_ctid() {
  local candidate
  candidate=$(pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9')
  [[ "$candidate" =~ ^[0-9]+$ ]] && ((candidate >= 100)) || candidate=100
  while pct status "$candidate" >/dev/null 2>&1; do ((candidate += 1)); done
  printf '%s\n' "$candidate"
}

wait_for_ct_ready() {
  local i
  for i in $(seq 1 60); do
    pct exec "$CTID" -- true >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

get_ct_ipv4() {
  pct exec "$CTID" -- bash -lc "hostname -I 2>/dev/null | tr ' ' '\n' | grep -m1 -E '^[0-9]+(\.[0-9]+){3}\$'" 2>/dev/null || true
}

prompt_domain() {
  local value=""
  if command -v whiptail >/dev/null 2>&1; then
    value=$(whiptail --title "SSO DOMAIN" --inputbox \
      "Enter the base DNS domain for this LXC.\n\nExamples:\n  dev.example.net\n  claude.example.org\n\nThe services will be auth.<domain>, home.<domain>, code.<domain>, files.<domain>, and term.<domain>.\n\nUse local DNS/hosts entries to point these names at the LXC IP." \
      20 86 "${SSO_DOMAIN:-}" 3>&1 1>&2 2>&3) || exit 0
  else
    read -r -p "SSO base domain (for example dev.example.net): " value
  fi
  SSO_DOMAIN=${value,,}
}

load_or_create_proxy_state() {
  local state_file="$STATE_DIR/no_docker_proxy_${CTID}.env"
  local requested_domain="$SSO_DOMAIN"

  install -d -m 0700 "$STATE_DIR" "$LOG_DIR"
  if [[ -s "$state_file" ]]; then
    # This file is generated only by this script, root-owned and mode 0600.
    # shellcheck disable=SC1090
    source "$state_file"
    if $SSO_DOMAIN_EXPLICIT; then
      SSO_DOMAIN="$requested_domain"
    fi
  fi

  if [[ -z "$SSO_DOMAIN" ]]; then
    if $ASSUME_YES; then
      fail "--yes requires --domain on the first proxy/SSO setup for CTID $CTID."
    fi
    prompt_domain
  fi
  valid_domain "$SSO_DOMAIN" || fail "Invalid SSO domain '$SSO_DOMAIN'. Use a normal multi-label DNS domain, not a special-use LAN suffix."

  [[ -n "$SSO_PASSWORD" ]] || SSO_PASSWORD=$(openssl rand -base64 24 | tr '/+' '_-' | tr -d '\n')
  [[ -n "$SESSION_SECRET" ]] || SESSION_SECRET=$(openssl rand -hex 64)
  [[ -n "$STORAGE_ENCRYPTION_KEY" ]] || STORAGE_ENCRYPTION_KEY=$(openssl rand -hex 64)
  [[ -n "$RESET_JWT_SECRET" ]] || RESET_JWT_SECRET=$(openssl rand -hex 64)

  {
    printf 'SSO_DOMAIN=%q\n' "$SSO_DOMAIN"
    printf 'SSO_USERNAME=%q\n' "$SSO_USERNAME"
    printf 'SSO_PASSWORD=%q\n' "$SSO_PASSWORD"
    printf 'SESSION_SECRET=%q\n' "$SESSION_SECRET"
    printf 'STORAGE_ENCRYPTION_KEY=%q\n' "$STORAGE_ENCRYPTION_KEY"
    printf 'RESET_JWT_SECRET=%q\n' "$RESET_JWT_SECRET"
  } >"$state_file"
  chmod 0600 "$state_file"
}

run_base_helper() {
  local -a args=(--ctid "$CTID")
  $ASSUME_YES && args+=(--yes)

  [[ -x "$BASE_HELPER" ]] || fail "Base helper is missing or not executable: $BASE_HELPER"
  log "Running base Docker-free LXC helper for CTID $CTID..."
  "$BASE_HELPER" "${args[@]}"
  wait_for_ct_ready || fail "LXC $CTID is not ready after the base helper completed."

  SSO_USERNAME=$(pct exec "$CTID" -- bash -c \
    'source /etc/ai-dev-claude.env; printf "%s" "$DEV_USER"' 2>/dev/null) || true
  [[ -n "$SSO_USERNAME" ]] || fail "Could not read DEV_USER from LXC $CTID."
}

write_overlay_env() {
  local target=$1
  {
    printf 'SSO_DOMAIN=%q\n' "$SSO_DOMAIN"
    printf 'SSO_USERNAME=%q\n' "$SSO_USERNAME"
    printf 'SSO_PASSWORD=%q\n' "$SSO_PASSWORD"
    printf 'SESSION_SECRET=%q\n' "$SESSION_SECRET"
    printf 'STORAGE_ENCRYPTION_KEY=%q\n' "$STORAGE_ENCRYPTION_KEY"
    printf 'RESET_JWT_SECRET=%q\n' "$RESET_JWT_SECRET"
    printf 'AUTHELIA_KEY_FINGERPRINT=%q\n' "$AUTHELIA_KEY_FINGERPRINT"
  } >"$target"
  chmod 0600 "$target"
}

write_overlay_script() {
  cat >"$1" <<'OVERLAY'
#!/usr/bin/env bash
set -Eeuo pipefail
source /root/no_docker_proxy.env
source /etc/ai-dev-claude.env

export DEBIAN_FRONTEND=noninteractive
export LANG=C.UTF-8
export LC_ALL=C.UTF-8

DEV_HOME="/home/$DEV_USER"
AUTH_HOST="auth.$SSO_DOMAIN"
HOME_HOST="home.$SSO_DOMAIN"
CODE_HOST="code.$SSO_DOMAIN"
FILES_HOST="files.$SSO_DOMAIN"
TERM_HOST="term.$SSO_DOMAIN"
AUTHELIA_CONFIG="/etc/authelia/configuration.yml"
AUTHELIA_USERS="/etc/authelia/users_database.yml"

stage() { printf '\n==== [%s] %s ====\n' "$(date +%T)" "$1"; }

stage "1/7: Install Caddy and Authelia without Docker"
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl gnupg debian-keyring debian-archive-keyring apt-transport-https openssl

install -d -m 0755 /usr/share/keyrings
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  -o /etc/apt/sources.list.d/caddy-stable.list
chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list

curl -fsSL 'https://www.authelia.com/keys/authelia-security.gpg' \
  -o /usr/share/keyrings/authelia-security.gpg
actual_fingerprint=$(gpg --no-default-keyring \
  --keyring /usr/share/keyrings/authelia-security.gpg \
  --with-colons --fingerprint 2>/dev/null \
  | awk -F: '$1=="fpr"{print toupper($10); exit}')
if [[ "$actual_fingerprint" != "$AUTHELIA_KEY_FINGERPRINT" ]]; then
  echo "ERROR: Authelia signing-key fingerprint mismatch: ${actual_fingerprint:-none}" >&2
  exit 1
fi
printf 'deb [arch=%s signed-by=/usr/share/keyrings/authelia-security.gpg] https://apt.authelia.com stable main\n' \
  "$(dpkg --print-architecture)" >/etc/apt/sources.list.d/authelia.list

apt-get update
apt-get install -y --no-install-recommends caddy authelia
apt-get clean

stage "2/7: Configure Authelia single sign-on"
id authelia >/dev/null 2>&1 || { echo "ERROR: Authelia package did not create the authelia service account." >&2; exit 1; }
install -d -m 0750 -o root -g authelia /etc/authelia
install -d -m 0750 -o authelia -g authelia /var/lib/authelia

hash_output=$(authelia crypto hash generate argon2 --password "$SSO_PASSWORD")
password_hash=$(sed -n 's/^Digest:[[:space:]]*//p' <<<"$hash_output" | head -n1)
[[ "$password_hash" == \$argon2id\$* ]] || { echo "ERROR: Authelia did not return an Argon2id password hash." >&2; exit 1; }

cat >"$AUTHELIA_USERS" <<EOF
users:
  $SSO_USERNAME:
    disabled: false
    displayname: '$SSO_USERNAME'
    password: '$password_hash'
    email: '$SSO_USERNAME@$SSO_DOMAIN'
    groups:
      - 'admins'
EOF
chown root:authelia "$AUTHELIA_USERS"
chmod 0640 "$AUTHELIA_USERS"

cat >"$AUTHELIA_CONFIG" <<EOF
server:
  address: 'tcp://127.0.0.1:9091/'
  endpoints:
    authz:
      forward-auth:
        implementation: 'ForwardAuth'

log:
  level: 'info'

theme: 'dark'

authentication_backend:
  file:
    path: '$AUTHELIA_USERS'
    watch: true
    password:
      algorithm: 'argon2'
      argon2:
        variant: 'argon2id'
        iterations: 3
        memory: 65536
        parallelism: 4
        key_length: 32
        salt_length: 16

access_control:
  default_policy: 'deny'
  rules:
    - domain:
        - '$HOME_HOST'
        - '$CODE_HOST'
        - '$FILES_HOST'
        - '$TERM_HOST'
      policy: 'one_factor'

session:
  secret: '$SESSION_SECRET'
  same_site: 'lax'
  inactivity: '1h'
  expiration: '8h'
  remember_me: '30d'
  cookies:
    - domain: '$SSO_DOMAIN'
      authelia_url: 'https://$AUTH_HOST'
      default_redirection_url: 'https://$HOME_HOST'

storage:
  encryption_key: '$STORAGE_ENCRYPTION_KEY'
  local:
    path: '/var/lib/authelia/db.sqlite3'

identity_validation:
  reset_password:
    jwt_secret: '$RESET_JWT_SECRET'

notifier:
  disable_startup_check: true
  filesystem:
    filename: '/var/lib/authelia/notification.txt'
EOF
chown root:authelia "$AUTHELIA_CONFIG"
chmod 0640 "$AUTHELIA_CONFIG"
authelia config validate --config "$AUTHELIA_CONFIG"
systemctl enable authelia.service
systemctl restart authelia.service

for _ in $(seq 1 30); do
  systemctl is-active --quiet authelia.service && \
    curl -fsS --max-time 3 http://127.0.0.1:9091/ >/dev/null 2>&1 && break
  sleep 1
done
systemctl is-active --quiet authelia.service || {
  systemctl status authelia.service --no-pager >&2 || true
  journalctl -u authelia.service -n 100 --no-pager >&2 || true
  exit 1
}

stage "3/7: Convert browser services to localhost-only / proxy authentication"
# code-server: Caddy/Authelia is the only authentication boundary.
code_config="$DEV_HOME/.config/code-server/config.yaml"
sed -i -E \
  -e "s#^bind-addr:.*#bind-addr: 127.0.0.1:$CODE_SERVER_PORT#" \
  -e 's#^auth:.*#auth: none#' \
  -e '/^password:/d' \
  "$code_config"
chown "$DEV_USER:$DEV_USER" "$code_config"
chmod 0600 "$code_config"
systemctl restart "code-server@$DEV_USER.service"

# FileBrowser Quantum: trust only the identity header inserted by Caddy after
# Authelia authorizes the request. The backend itself listens on localhost.
fb_config="$DEV_HOME/.config/filebrowser/config.yaml"
fb_version=$(/usr/local/bin/filebrowser version 2>&1 || /usr/local/bin/filebrowser --version 2>&1 || true)
fb_major=$(sed -nE 's/.*[^0-9]([0-9]+)\.[0-9]+\.[0-9]+.*/\1/p' <<<"$fb_version" | head -n1)
[[ "$fb_major" =~ ^[0-9]+$ ]] || fb_major=1
if ((fb_major >= 2)); then
  cat >"$fb_config" <<EOF
http:
  port: $FILE_MANAGER_PORT
  listen: '127.0.0.1'
  baseURL: '/'
  trustedHeaders:
    - 'X-Forwarded-For'
    - 'X-Real-IP'
server:
  database:
    path: '$DEV_HOME/.local/share/filebrowser/filebrowser.sqlite'
  cacheDir: '$DEV_HOME/.cache/filebrowser'
  sources:
    - path: '/srv/workspace'
      name: 'Workspace'
      config:
        defaultEnabled: true
auth:
  adminUsername: admin
  methods:
    proxy:
      enabled: true
      header: 'Remote-User'
      adminGroup: 'admins'
    password:
      enabled: false
EOF
else
  cat >"$fb_config" <<EOF
http:
  trustedHeaders:
    - 'X-Forwarded-For'
    - 'X-Real-IP'
server:
  port: $FILE_MANAGER_PORT
  listen: '127.0.0.1'
  database: '$DEV_HOME/.local/share/filebrowser/database.db'
  cacheDir: '$DEV_HOME/.cache/filebrowser'
  sources:
    - path: '/srv/workspace'
      name: 'Workspace'
      config:
        defaultEnabled: true
auth:
  adminUsername: admin
  methods:
    proxy:
      enabled: true
      header: 'Remote-User'
      adminGroup: 'admins'
    password:
      enabled: false
EOF
fi
chown "$DEV_USER:$DEV_USER" "$fb_config"
chmod 0600 "$fb_config"
systemctl restart filebrowser-quantum.service

# ttyd: run directly as the development user and require the authenticated
# Remote-User header. There is no second HTTP Basic or Linux login prompt.
cat >/etc/systemd/system/ttyd.service <<EOF
[Unit]
Description=ttyd web terminal behind Caddy + Authelia
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$DEV_USER
Environment=HOME=$DEV_HOME
WorkingDirectory=/srv/workspace
ExecStart=/usr/local/bin/ttyd --interface 127.0.0.1 --port $WEB_TERMINAL_PORT --writable --auth-header Remote-User /bin/bash -l
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Dashboard is also localhost-only; Caddy is the only LAN-facing entrypoint.
cat >/etc/systemd/system/ai-dev-dashboard.service <<EOF
[Unit]
Description=AI Dev Claude static dashboard behind Caddy + Authelia
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/bin/python3 -m http.server $DASHBOARD_PORT --bind 127.0.0.1 --directory /opt/dashboard
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl restart ttyd.service ai-dev-dashboard.service

stage "4/7: Generate SSO-aware dashboard"
cat >/etc/ai-dev-proxy.env <<EOF
SSO_DOMAIN=$SSO_DOMAIN
SSO_USERNAME=$SSO_USERNAME
AUTH_HOST=$AUTH_HOST
HOME_HOST=$HOME_HOST
CODE_HOST=$CODE_HOST
FILES_HOST=$FILES_HOST
TERM_HOST=$TERM_HOST
EOF
chmod 0644 /etc/ai-dev-proxy.env

cat >/root/ai-dev-proxy-credentials <<EOF
SSO_USERNAME=$SSO_USERNAME
SSO_PASSWORD=$SSO_PASSWORD
EOF
chmod 0600 /root/ai-dev-proxy-credentials

cat >/usr/local/sbin/dashboard-refresh <<'REFRESH'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-dev-proxy.env
cat >/opt/dashboard/index.html <<HTML
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>AI Dev Claude</title>
<style>
:root { color-scheme: dark; }
body { margin:0; font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif; background:#14161a; color:#e6e8eb; padding:2.5rem 1.5rem; }
main { max-width:720px; margin:0 auto; }
h1 { font-size:1.5rem; margin:0 0 .25rem; }
p.sub { color:#9aa1ab; margin:0 0 2rem; }
ul { list-style:none; padding:0; margin:0; display:grid; gap:.75rem; }
a.card { display:block; padding:1rem 1.25rem; border-radius:.6rem; background:#1e2127; border:1px solid #2a2e36; text-decoration:none; color:inherit; }
a.card:hover { border-color:#5b8def; }
.name { font-weight:600; font-size:1.05rem; }
.desc { color:#9aa1ab; font-size:.88rem; margin-top:.2rem; }
footer { margin-top:2rem; color:#777f8a; font-size:.8rem; }
</style>
</head>
<body>
<main>
<h1>AI Dev Claude</h1>
<p class="sub">One Authelia login protects every browser service.</p>
<ul>
<li><a class="card" href="https://$CODE_HOST"><div class="name">Web IDE</div><div class="desc">code-server · no second password</div></a></li>
<li><a class="card" href="https://$FILES_HOST"><div class="name">File Manager</div><div class="desc">FileBrowser Quantum · proxy SSO</div></a></li>
<li><a class="card" href="https://$TERM_HOST"><div class="name">Web Terminal</div><div class="desc">ttyd · direct dev shell after SSO</div></a></li>
<li><a class="card" href="https://$AUTH_HOST"><div class="name">Account / SSO</div><div class="desc">Authelia authentication portal</div></a></li>
</ul>
<footer>no_docker_proxy · Caddy + Authelia · localhost-only backends</footer>
</main>
</body>
</html>
HTML
chmod 0644 /opt/dashboard/index.html
printf 'Dashboard links refreshed for %s\n' "$SSO_DOMAIN"
REFRESH
chmod 0750 /usr/local/sbin/dashboard-refresh
/usr/local/sbin/dashboard-refresh

stage "5/7: Configure Caddy HTTPS reverse proxy"
cat >/etc/caddy/Caddyfile <<EOF
(authenticated) {
    forward_auth 127.0.0.1:9091 {
        uri /api/authz/forward-auth
        copy_headers Remote-User Remote-Groups Remote-Email Remote-Name
    }
}

$AUTH_HOST {
    tls internal
    reverse_proxy 127.0.0.1:9091
}

$HOME_HOST {
    tls internal
    import authenticated
    reverse_proxy 127.0.0.1:$DASHBOARD_PORT
}

$CODE_HOST {
    tls internal
    import authenticated
    reverse_proxy 127.0.0.1:$CODE_SERVER_PORT
}

$FILES_HOST {
    tls internal
    import authenticated
    reverse_proxy 127.0.0.1:$FILE_MANAGER_PORT
}

$TERM_HOST {
    tls internal
    import authenticated
    reverse_proxy 127.0.0.1:$WEB_TERMINAL_PORT
}
EOF
caddy validate --config /etc/caddy/Caddyfile
systemctl enable caddy.service
systemctl restart caddy.service

stage "6/7: Verify localhost isolation and SSO proxy"
for _ in $(seq 1 30); do
  cs=$(systemctl is-active "code-server@$DEV_USER.service" 2>/dev/null || true)
  fb=$(systemctl is-active filebrowser-quantum.service 2>/dev/null || true)
  tt=$(systemctl is-active ttyd.service 2>/dev/null || true)
  db=$(systemctl is-active ai-dev-dashboard.service 2>/dev/null || true)
  au=$(systemctl is-active authelia.service 2>/dev/null || true)
  ca=$(systemctl is-active caddy.service 2>/dev/null || true)
  [[ "$cs" == active && "$fb" == active && "$tt" == active && "$db" == active && "$au" == active && "$ca" == active ]] && break
  sleep 2
done
printf 'Services: code-server=%s filebrowser=%s ttyd=%s dashboard=%s authelia=%s caddy=%s\n' "$cs" "$fb" "$tt" "$db" "$au" "$ca"
[[ "$cs" == active && "$fb" == active && "$tt" == active && "$db" == active && "$au" == active && "$ca" == active ]]

curl -fsS --max-time 5 "http://127.0.0.1:$CODE_SERVER_PORT/healthz" >/dev/null
curl -fsS --max-time 5 -H "Remote-User: $SSO_USERNAME" "http://127.0.0.1:$FILE_MANAGER_PORT/" >/dev/null
curl -fsS --max-time 5 -H "Remote-User: $SSO_USERNAME" "http://127.0.0.1:$WEB_TERMINAL_PORT/" >/dev/null
curl -fsS --max-time 5 "http://127.0.0.1:$DASHBOARD_PORT/" >/dev/null
curl -kfsS --max-time 8 --resolve "$AUTH_HOST:443:127.0.0.1" "https://$AUTH_HOST/" >/dev/null

for port in "$CODE_SERVER_PORT" "$FILE_MANAGER_PORT" "$WEB_TERMINAL_PORT" "$DASHBOARD_PORT" 9091; do
  if ss -ltn | awk '{print $4}' | grep -Eq "(^|:)0\.0\.0\.0:${port}$|^\[::\]:${port}$"; then
    echo "ERROR: backend port $port is still listening on all interfaces." >&2
    ss -ltnp >&2 || true
    exit 1
  fi
done

stage "7/7: Export Caddy local CA certificate"
for _ in $(seq 1 20); do
  [[ -s /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]] && break
  sleep 1
done
[[ -s /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt ]] || {
  echo "ERROR: Caddy local CA root certificate was not generated." >&2
  exit 1
}
install -m 0644 /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt /root/caddy-local-root.crt

echo
echo "Proxy/SSO overlay completed successfully."
OVERLAY
}

run_proxy_overlay() {
  local env_file overlay_file
  env_file=$(mktemp)
  overlay_file=$(mktemp)
  write_overlay_env "$env_file"
  write_overlay_script "$overlay_file"

  pct push "$CTID" "$env_file" /root/no_docker_proxy.env --perms 0600
  pct push "$CTID" "$overlay_file" /root/no_docker_proxy-overlay.sh --perms 0700
  rm -f "$env_file" "$overlay_file"

  log "Applying Caddy + Authelia proxy/SSO overlay inside LXC $CTID..."
  set +e
  pct exec "$CTID" -- bash /root/no_docker_proxy-overlay.sh 2>&1 | tee -a "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e
  if ((rc != 0)); then
    fail "Proxy/SSO overlay failed inside LXC $CTID (exit $rc). The container was left intact for diagnosis."
  fi
  pct exec "$CTID" -- rm -f /root/no_docker_proxy.env /root/no_docker_proxy-overlay.sh
}

reboot_and_verify() {
  log "Rebooting LXC $CTID to verify the complete proxy stack from a clean start..."
  pct reboot "$CTID" >>"$LOG_FILE" 2>&1
  wait_for_ct_ready || fail "LXC $CTID did not return after reboot."

  local result
  result=$(pct exec "$CTID" -- bash -c '
    set -Eeuo pipefail
    source /etc/ai-dev-claude.env
    source /etc/ai-dev-proxy.env
    for i in $(seq 1 30); do
      cs=$(systemctl is-active "code-server@$DEV_USER.service" 2>/dev/null || true)
      fb=$(systemctl is-active filebrowser-quantum.service 2>/dev/null || true)
      tt=$(systemctl is-active ttyd.service 2>/dev/null || true)
      db=$(systemctl is-active ai-dev-dashboard.service 2>/dev/null || true)
      au=$(systemctl is-active authelia.service 2>/dev/null || true)
      ca=$(systemctl is-active caddy.service 2>/dev/null || true)
      [[ "$cs" == active && "$fb" == active && "$tt" == active && "$db" == active && "$au" == active && "$ca" == active ]] && break
      sleep 2
    done
    printf "code-server=%s filebrowser=%s ttyd=%s dashboard=%s authelia=%s caddy=%s" "$cs" "$fb" "$tt" "$db" "$au" "$ca"
    [[ "$cs" == active && "$fb" == active && "$tt" == active && "$db" == active && "$au" == active && "$ca" == active ]]
  ' 2>&1) || fail "One or more proxy services did not recover after reboot: $result"
  log "Post-reboot verification: $result"
}

export_ca_to_host() {
  local target="$STATE_DIR/caddy-local-root-${CTID}.crt"
  rm -f "$target"
  pct pull "$CTID" /root/caddy-local-root.crt "$target" >/dev/null 2>&1 || return 1
  chmod 0644 "$target"
  printf '%s' "$target"
}

final_summary() {
  local ip ca_path=""
  ip=$(get_ct_ipv4)
  ca_path=$(export_ca_to_host || true)

  cat <<EOF

LXC $CTID proxy/SSO variant is ready. Docker was not installed by this variant.

One web login:
  Username:       $SSO_USERNAME
  Password:       $SSO_PASSWORD

Browser URLs:
  Dashboard:      https://home.$SSO_DOMAIN
  Web IDE:        https://code.$SSO_DOMAIN
  File Manager:   https://files.$SSO_DOMAIN
  Web Terminal:   https://term.$SSO_DOMAIN
  SSO Portal:     https://auth.$SSO_DOMAIN

LXC IPv4:         ${ip:-unknown}

Required once on your LAN/client devices:
  1. Point auth.$SSO_DOMAIN, home.$SSO_DOMAIN, code.$SSO_DOMAIN,
     files.$SSO_DOMAIN and term.$SSO_DOMAIN to ${ip:-the LXC IP} in local DNS
     (or each client's hosts file).
  2. Trust the Caddy local CA root certificate.
     Proxmox-host copy: ${ca_path:-not copied; guest path is /root/caddy-local-root.crt}

After that, sign in to Authelia once. Dashboard links reuse the same SSO
session; code-server has no second password, FileBrowser uses proxy identity,
and ttyd opens directly as '$DEV_USER'.

Persistent root-only credentials/state:
  $STATE_DIR/no_docker_proxy_${CTID}.env

Log:
  $LOG_FILE
EOF
}

main() {
  [[ "$(id -u)" -eq 0 ]] || fail "Run as root on the Proxmox host."
  command -v pct >/dev/null 2>&1 || fail "pct not found; run on a Proxmox VE host."
  command -v pvesh >/dev/null 2>&1 || fail "pvesh not found; run on a Proxmox VE host."
  command -v openssl >/dev/null 2>&1 || fail "openssl is required on the Proxmox host."

  install -d -m 0700 "$STATE_DIR" "$LOG_DIR"
  LOG_FILE="$LOG_DIR/no_docker_proxy-$(date +%Y%m%d-%H%M%S).log"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"

  [[ -n "$CTID" ]] || CTID=$(next_ctid)
  [[ "$CTID" =~ ^[0-9]+$ ]] || fail "Invalid CTID '$CTID'."

  # If this CT already has proxy state, load the domain/secrets before asking.
  local state_file="$STATE_DIR/no_docker_proxy_${CTID}.env"
  local requested_domain="$SSO_DOMAIN"
  if [[ -s "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
    if $SSO_DOMAIN_EXPLICIT; then SSO_DOMAIN="$requested_domain"; fi
  fi

  if [[ -z "$SSO_DOMAIN" ]]; then
    if $ASSUME_YES; then
      fail "--yes requires --domain for a new proxy/SSO setup."
    fi
    prompt_domain
  fi
  valid_domain "$SSO_DOMAIN" || fail "Invalid SSO domain '$SSO_DOMAIN'."

  run_base_helper
  load_or_create_proxy_state
  run_proxy_overlay
  reboot_and_verify
  final_summary
}

main "$@"
