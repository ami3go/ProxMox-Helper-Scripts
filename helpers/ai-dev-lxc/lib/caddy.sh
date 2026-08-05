#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$LIB_DIR/common.sh"
source "$LIB_DIR/state.sh"

caddy_install_package() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg debian-keyring debian-archive-keyring apt-transport-https
  local key_tmp list_tmp
  key_tmp=$(mktemp)
  list_tmp=$(mktemp)
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' -o "$key_tmp"
  gpg --batch --yes --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg "$key_tmp"
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' -o "$list_tmp"
  install -m 0644 "$list_tmp" /etc/apt/sources.list.d/caddy-stable.list
  rm -f "$key_tmp" "$list_tmp"
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y --no-install-recommends caddy
}

caddy_site_block() {
  local host=$1 port=$2 scheme_prefix='' tls_line=''
  if [[ "$GATEWAY_HTTPS_MODE" == http ]]; then
    scheme_prefix='http://'
  else
    tls_line='    tls internal'
  fi
  cat <<CADDY
${scheme_prefix}${host} {
${tls_line}
    reverse_proxy 127.0.0.1:${port}
}

CADDY
}

caddy_render_config() {
  if [[ "$GATEWAY_HTTPS_MODE" == http ]]; then
    cat <<'CADDY'
{
    auto_https off
}

CADDY
  fi
  is_true "$ENABLE_HOMEPAGE" && caddy_site_block "$(fqdn_dashboard)" "$HOMEPAGE_PORT" || true
  is_true "$CODE_SERVER_ENABLED" && caddy_site_block "$(fqdn_code)" "$CODE_SERVER_PORT" || true
  is_true "$FILE_MANAGER_ENABLED" && caddy_site_block "$(fqdn_files)" "$FILE_MANAGER_PORT" || true
  is_true "$TERMIX_ENABLED" && caddy_site_block "$(fqdn_termix)" "$TERMIX_PORT" || true
  return 0
}

caddy_backup_config() {
  local dest=''
  install -d -m 0700 /etc/caddy/backups
  if [[ -f /etc/caddy/Caddyfile ]]; then
    dest="/etc/caddy/backups/Caddyfile-$(timestamp)"
    cp -a /etc/caddy/Caddyfile "$dest"
  fi
  printf '%s' "$dest"
}

caddy_verify_local_route() {
  local host=$1 code scheme flags=()
  scheme=$(gateway_scheme)
  [[ "$scheme" == https ]] && flags=(-k)
  code=$(curl "${flags[@]}" -sS -o /dev/null -w '%{http_code}' -H "Host: $host" --connect-timeout 4 --max-time 10 "${scheme}://127.0.0.1/" 2>/dev/null || true)
  http_status_ok "$code"
}

caddy_verify() {
  systemctl is-active --quiet caddy.service || return 1
  caddy validate --config /etc/caddy/Caddyfile >/dev/null || return 1
  ss -H -lnt 2>/dev/null | awk '$4 ~ /:80$/ {found=1} END {exit !found}' || return 1
  if [[ "$GATEWAY_HTTPS_MODE" == internal ]]; then
    ss -H -lnt 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END {exit !found}' || return 1
  fi
  if is_true "$ENABLE_HOMEPAGE"; then caddy_verify_local_route "$(fqdn_dashboard)" || return 1; fi
  if is_true "$CODE_SERVER_ENABLED"; then caddy_verify_local_route "$(fqdn_code)" || return 1; fi
  if is_true "$FILE_MANAGER_ENABLED"; then caddy_verify_local_route "$(fqdn_files)" || return 1; fi
  if is_true "$TERMIX_ENABLED"; then caddy_verify_local_route "$(fqdn_termix)" || return 1; fi
}

caddy_write_dns_records() {
  local ip
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  {
    echo '# AI Development LXC local DNS records'
    echo '# Add these to the router, AdGuard Home, Pi-hole, or client hosts file.'
    printf '%s %s\n' "${ip:-LXC_IP}" "$(fqdn_dashboard)"
    is_true "$CODE_SERVER_ENABLED" && printf '%s %s\n' "${ip:-LXC_IP}" "$(fqdn_code)"
    is_true "$FILE_MANAGER_ENABLED" && printf '%s %s\n' "${ip:-LXC_IP}" "$(fqdn_files)"
    is_true "$TERMIX_ENABLED" && printf '%s %s\n' "${ip:-LXC_IP}" "$(fqdn_termix)"
    echo
    printf 'Preferred wildcard: *.%s.%s -> %s\n' "$DASHBOARD_HOSTNAME" "$GATEWAY_DOMAIN" "${ip:-LXC_IP}"
    echo
    echo 'Windows hosts file: C:\Windows\System32\drivers\etc\hosts'
    echo 'Linux hosts file:   /etc/hosts'
    echo 'AdGuard Home:        Filters > DNS rewrites'
    echo 'Pi-hole:             Local DNS > DNS Records'
  } | atomic_write /root/ai-dev-dns-records.txt 0644
}

caddy_install_commands() {
  cat > /usr/local/bin/gateway-dns-records <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-development-gateway.env
ip=$(hostname -I 2>/dev/null | awk '{print $1}')
printf '%s %s.%s\n' "${ip:-LXC_IP}" "$DASHBOARD_HOSTNAME" "$GATEWAY_DOMAIN"
[[ ${CODE_SERVER_ENABLED:-false} == true ]] && printf '%s %s.%s.%s\n' "${ip:-LXC_IP}" "$CODE_HOSTNAME" "$DASHBOARD_HOSTNAME" "$GATEWAY_DOMAIN"
[[ ${FILE_MANAGER_ENABLED:-false} == true ]] && printf '%s %s.%s.%s\n' "${ip:-LXC_IP}" "$FILES_HOSTNAME" "$DASHBOARD_HOSTNAME" "$GATEWAY_DOMAIN"
[[ ${TERMIX_ENABLED:-false} == true ]] && printf '%s %s.%s.%s\n' "${ip:-LXC_IP}" "$TERMIX_HOSTNAME" "$DASHBOARD_HOSTNAME" "$GATEWAY_DOMAIN"
printf '\n*.%s.%s -> %s\n' "$DASHBOARD_HOSTNAME" "$GATEWAY_DOMAIN" "${ip:-LXC_IP}"
SCRIPT

  cat > /usr/local/bin/gateway-restart <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
caddy fmt --overwrite /etc/caddy/Caddyfile
caddy validate --config /etc/caddy/Caddyfile
systemctl restart caddy.service
systemctl is-active --quiet caddy.service
echo 'Caddy restarted successfully.'
SCRIPT

  cat > /usr/local/bin/gateway-config <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
editor=${VISUAL:-${EDITOR:-}}
if [[ -z "$editor" ]]; then
  if command -v nano >/dev/null 2>&1; then editor=nano; else editor=vi; fi
fi
exec "$editor" /etc/caddy/Caddyfile
SCRIPT

  cat > /usr/local/bin/gateway-logs <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
journalctl -u caddy.service -n 120 --no-pager || true
echo '--- Homepage ---'
docker logs --tail 120 homepage 2>&1 || true
SCRIPT

  cat > /usr/local/bin/gateway-status <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
check=0
[[ ${1:-} == --check ]] && check=1
source /etc/ai-development-gateway.env
failed=0
scheme=http; curl_flags=()
[[ ${GATEWAY_HTTPS_MODE:-http} == internal ]] && { scheme=https; curl_flags=(-k); }
ip=$(hostname -I 2>/dev/null | awk '{print $1}')
printf 'Caddy service:       %s\n' "$(systemctl is-active caddy.service 2>/dev/null || true)"
printf 'Dashboard:           %s://%s.%s\n' "$scheme" "$DASHBOARD_HOSTNAME" "$GATEWAY_DOMAIN"
printf 'LXC IP:              %s\n' "${ip:-unavailable}"
if ! caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
  echo 'Caddy config:         INVALID'; failed=1
else
  echo 'Caddy config:         valid'
fi
systemctl is-active --quiet caddy.service || failed=1
check_route() {
  local name=$1 host=$2 port=$3
  local backend public dns
  backend=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 7 "http://127.0.0.1:${port}/" 2>/dev/null || true)
  public=$(curl "${curl_flags[@]}" -sS -o /dev/null -w '%{http_code}' -H "Host: ${host}" --max-time 7 "${scheme}://127.0.0.1/" 2>/dev/null || true)
  dns=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}')
  printf '%-20s backend=%-3s proxy=%-3s dns=%s\n' "$name" "${backend:-000}" "${public:-000}" "${dns:-not-configured}"
  [[ "$backend" =~ ^(2|3)[0-9][0-9]$ || "$backend" == 401 || "$backend" == 403 ]] || failed=1
  [[ "$public" =~ ^(2|3)[0-9][0-9]$ || "$public" == 401 || "$public" == 403 ]] || failed=1
}
[[ ${ENABLE_HOMEPAGE:-false} == true ]] && check_route Homepage "${DASHBOARD_HOSTNAME}.${GATEWAY_DOMAIN}" "$HOMEPAGE_PORT"
[[ ${CODE_SERVER_ENABLED:-false} == true ]] && check_route code-server "${CODE_HOSTNAME}.${DASHBOARD_HOSTNAME}.${GATEWAY_DOMAIN}" "$CODE_SERVER_PORT"
[[ ${FILE_MANAGER_ENABLED:-false} == true ]] && check_route FileBrowser "${FILES_HOSTNAME}.${DASHBOARD_HOSTNAME}.${GATEWAY_DOMAIN}" "$FILE_MANAGER_PORT"
[[ ${TERMIX_ENABLED:-false} == true ]] && check_route Termix "${TERMIX_HOSTNAME}.${DASHBOARD_HOSTNAME}.${GATEWAY_DOMAIN}" "$TERMIX_PORT"
if ((failed)); then
  echo 'Result:              FAIL'
  ((check)) && exit 1
else
  echo 'Result:              PASS'
fi
SCRIPT
  chmod 0755 /usr/local/bin/gateway-dns-records /usr/local/bin/gateway-restart \
    /usr/local/bin/gateway-config /usr/local/bin/gateway-logs /usr/local/bin/gateway-status
}

install_caddy() {
  if ! is_true "$ENABLE_CADDY"; then
    info "Caddy is disabled; existing package and data are preserved"
    is_true "$ENABLE_HOMEPAGE" && warn "Homepage will remain reachable only through 127.0.0.1:${HOMEPAGE_PORT} unless its binding is changed manually"
    return 0
  fi
  caddy_install_package
  local backup generated
  backup=$(caddy_backup_config)
  generated=$(mktemp)
  caddy_render_config > "$generated"
  install -o root -g caddy -m 0644 "$generated" /etc/caddy/Caddyfile
  rm -f "$generated"
  if ! caddy fmt --overwrite /etc/caddy/Caddyfile || ! caddy validate --config /etc/caddy/Caddyfile; then
    [[ -n "$backup" ]] && cp -a "$backup" /etc/caddy/Caddyfile
    die "Generated Caddy configuration failed validation; previous configuration restored"
  fi
  if ! systemctl restart caddy.service; then
    [[ -n "$backup" ]] && cp -a "$backup" /etc/caddy/Caddyfile
    systemctl restart caddy.service || true
    die "Caddy failed to start; previous configuration restored"
  fi
  retry 20 1 caddy_verify || {
    [[ -n "$backup" ]] && cp -a "$backup" /etc/caddy/Caddyfile
    systemctl restart caddy.service || true
    die "Caddy route verification failed; previous configuration restored"
  }
  caddy_write_dns_records
  caddy_install_commands
  info "Caddy routes verified"
}
