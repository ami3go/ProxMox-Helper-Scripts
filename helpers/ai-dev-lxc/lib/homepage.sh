#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$LIB_DIR/common.sh"
source "$LIB_DIR/state.sh"

homepage_compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f /opt/homepage/compose.yaml "$@"
  elif command_exists docker-compose; then
    docker-compose -f /opt/homepage/compose.yaml "$@"
  else
    return 127
  fi
}

homepage_install_docker() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends docker.io docker-compose zstd
  systemctl enable --now docker.service containerd.service
  docker info >/dev/null 2>&1 || die "Docker is unavailable. For nested LXC, enable nesting=1 and keyctl=1 on the Proxmox host."
}

homepage_render_services() {
  local scheme dashboard code files termix
  scheme=$(gateway_scheme)
  dashboard=$(fqdn_dashboard)
  code=$(fqdn_code)
  files=$(fqdn_files)
  termix=$(fqdn_termix)
  {
    echo '- Development:'
    if is_true "$CODE_SERVER_ENABLED"; then
      cat <<YAML
    - VS Code Web:
        icon: vscode.png
        href: ${scheme}://${code}
        description: Browser development environment
YAML
    fi
    cat <<'YAML'
    - GitHub:
        icon: github.png
        href: https://github.com
        description: Repositories, pull requests and Actions
YAML
    if is_true "$FILE_MANAGER_ENABLED"; then
      cat <<YAML
- Files:
    - FileBrowser Quantum:
        icon: filebrowser.png
        href: ${scheme}://${files}
        description: Workspace file manager
YAML
    fi
    if is_true "$TERMIX_ENABLED"; then
      cat <<YAML
- Terminals:
    - Termix:
        icon: terminal.png
        href: ${scheme}://${termix}
        description: SSH terminal and host manager
YAML
    fi
    if [[ -n "$PROXMOX_WEB_URL" ]]; then
      cat <<YAML
- Infrastructure:
    - Proxmox:
        icon: proxmox.png
        href: ${PROXMOX_WEB_URL}
        description: Proxmox management
YAML
    fi
  }
}

homepage_render_widgets() {
  local host ip
  host=$(hostname -s)
  ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  cat <<YAML
- greeting:
    text_size: xl
    text: "${host} · ${ip:-IP unavailable}"
YAML
  if is_true "$HOMEPAGE_SYSTEM_WIDGETS"; then
    cat <<'YAML'
- resources:
    label: Homepage container / workspace
    cpu: true
    memory: true
    uptime: true
    disk:
      - /
      - /srv/workspace
YAML
  fi
  cat <<'YAML'
- datetime:
    text_size: xl
    format:
      dateStyle: long
      timeStyle: short
      hour12: false
YAML
}

homepage_render_compose() {
  local allowed socket_mount=''
  allowed=$(fqdn_dashboard)
  if is_true "$HOMEPAGE_DOCKER_DISCOVERY"; then
    socket_mount='      - /var/run/docker.sock:/var/run/docker.sock:ro'
  fi
  cat <<YAML
services:
  homepage:
    image: ${HOMEPAGE_IMAGE}
    container_name: homepage
    restart: unless-stopped
    ports:
      - "127.0.0.1:${HOMEPAGE_PORT}:3000"
    volumes:
      - /opt/homepage/config:/app/config
      - /etc/localtime:/etc/localtime:ro
      - /srv/workspace:/srv/workspace:ro
${socket_mount}
    environment:
      HOMEPAGE_ALLOWED_HOSTS: "${allowed}"
YAML
}

homepage_render_config() {
  install -d -m 0750 /opt/homepage/config /var/backups/homepage
  homepage_render_compose | atomic_write /opt/homepage/compose.yaml 0640
  homepage_render_services | atomic_write /opt/homepage/config/services.yaml 0640
  cat > /opt/homepage/config/settings.yaml <<'YAML'
title: AI Development Environment
headerStyle: clean
statusStyle: dot
useEqualHeights: true
layout:
  Development:
    style: row
    columns: 2
  Files:
    style: row
    columns: 2
  Terminals:
    style: row
    columns: 2
  Infrastructure:
    style: row
    columns: 2
YAML
  homepage_render_widgets > /opt/homepage/config/widgets.yaml
  cat > /opt/homepage/config/bookmarks.yaml <<'YAML'
- Developer Resources:
    - OpenAI Developers:
        - icon: si-openai
          href: https://developers.openai.com/
    - GitHub:
        - icon: si-github
          href: https://github.com/
YAML
  if is_true "$HOMEPAGE_DOCKER_DISCOVERY"; then
    cat > /opt/homepage/config/docker.yaml <<'YAML'
my-docker:
  socket: /var/run/docker.sock
YAML
  else
    printf '{}\n' > /opt/homepage/config/docker.yaml
  fi
  chmod 0640 /opt/homepage/compose.yaml /opt/homepage/config/*.yaml
}

homepage_backup_internal() {
  local archive="/var/backups/homepage/homepage-$(timestamp).tar.zst"
  install -d -m 0700 /var/backups/homepage
  tar --zstd -cf "$archive" -C / opt/homepage/compose.yaml opt/homepage/config
  chmod 0600 "$archive"
  printf '%s' "$archive"
}

homepage_verify() {
  local code state
  state=$(docker inspect -f '{{.State.Status}}' homepage 2>/dev/null || true)
  [[ "$state" == running ]] || return 1
  code=$(http_probe "http://127.0.0.1:${HOMEPAGE_PORT}/")
  http_status_ok "$code"
}

homepage_transaction_begin() {
  local tx="/var/backups/homepage/transaction-$(timestamp)" old_id old_ref
  install -d -m 0700 "$tx"
  if [[ -e /opt/homepage ]]; then
    cp -a /opt/homepage "$tx/opt-homepage"
  fi
  old_id=$(docker inspect -f '{{.Image}}' homepage 2>/dev/null || true)
  old_ref=$(docker inspect -f '{{.Config.Image}}' homepage 2>/dev/null || true)
  if [[ -n "$old_id" ]]; then
    printf '%s\n' "$old_id" >"$tx/previous-image-id"
    [[ -n "$old_ref" ]] && printf '%s\n' "$old_ref" >"$tx/previous-image-ref"
  fi
  printf '%s' "$tx"
}

homepage_transaction_restore() {
  local tx=$1 old_id='' old_ref=''
  warn "Restoring Homepage state from $tx"
  [[ -r "$tx/previous-image-id" ]] && old_id=$(cat "$tx/previous-image-id")
  [[ -r "$tx/previous-image-ref" ]] && old_ref=$(cat "$tx/previous-image-ref")
  if [[ -n "$old_id" && -n "$old_ref" ]]; then
    docker tag "$old_id" "$old_ref" >/dev/null 2>&1 || warn "Could not restore previous Homepage image tag $old_ref"
  fi
  docker rm -f homepage >/dev/null 2>&1 || true
  rm -rf /opt/homepage
  if [[ -d "$tx/opt-homepage" ]]; then
    cp -a "$tx/opt-homepage" /opt/homepage
    if [[ -f /opt/homepage/compose.yaml ]]; then
      homepage_compose up -d --remove-orphans || warn "Previous Homepage Compose deployment could not be restarted automatically"
    fi
  fi
}

homepage_install_commands() {
  cat > /usr/local/bin/homepage-status <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-development-gateway.env
failed=0
state=$(docker inspect -f '{{.State.Status}}' homepage 2>/dev/null || true)
image=$(docker inspect -f '{{.Config.Image}}' homepage 2>/dev/null || true)
listener=$(ss -H -lnt 2>/dev/null | awk -v p=":${HOMEPAGE_PORT}" '$4 ~ p "$" {print; exit}')
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${HOMEPAGE_PORT}/" 2>/dev/null || true)
[[ "$state" == running ]] || failed=1
[[ -n "$listener" ]] || failed=1
[[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] || failed=1
printf 'Container:       %s\n' "${state:-missing}"
printf 'Image:           %s\n' "${image:-missing}"
printf 'Port:            127.0.0.1:%s\n' "$HOMEPAGE_PORT"
printf 'Listener:        %s\n' "${listener:-missing}"
printf 'HTTP response:   %s\n' "${code:-none}"
printf 'Configuration:   /opt/homepage/config\n'
((failed)) && { echo 'Result:          FAIL'; exit 1; }
echo 'Result:          PASS'
SCRIPT

  cat > /usr/local/bin/homepage-backup <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
archive="/var/backups/homepage/homepage-$(date +%Y%m%d-%H%M%S).tar.zst"
install -d -m 0700 /var/backups/homepage
tar --zstd -cf "$archive" -C / opt/homepage/compose.yaml opt/homepage/config
chmod 0600 "$archive"
echo "$archive"
SCRIPT

  cat > /usr/local/bin/homepage-update <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
source /etc/ai-development-gateway.env
compose=/opt/homepage/compose.yaml
backup=$(homepage-backup)
old_id=$(docker inspect -f '{{.Image}}' homepage 2>/dev/null || true)
old_ref=''
if [[ -n "$old_id" ]]; then
  old_ref=$(docker image inspect -f '{{index .RepoDigests 0}}' "$old_id" 2>/dev/null || true)
  if [[ -z "$old_ref" || "$old_ref" == '<no value>' ]]; then
    old_ref="localhost/ai-dev-homepage-rollback:$(date +%Y%m%d-%H%M%S)"
    docker tag "$old_id" "$old_ref"
  fi
fi
cp -a "$compose" "${compose}.before-update"
compose_cmd=(docker compose -f "$compose")
docker compose version >/dev/null 2>&1 || compose_cmd=(docker-compose -f "$compose")
code=000
if "${compose_cmd[@]}" pull && "${compose_cmd[@]}" up -d --remove-orphans; then
  for _ in $(seq 1 30); do
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${HOMEPAGE_PORT}/" 2>/dev/null || true)
    [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]] && break
    sleep 2
  done
  if [[ "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then
    if [[ ${ENABLE_CADDY:-false} == true ]]; then
      host="${DASHBOARD_HOSTNAME}.${GATEWAY_DOMAIN}"
      scheme=http; flags=()
      [[ ${GATEWAY_HTTPS_MODE:-http} == internal ]] && { scheme=https; flags=(-k); }
      public=$(curl "${flags[@]}" -sS -o /dev/null -w '%{http_code}' -H "Host: $host" --max-time 8 "${scheme}://127.0.0.1/" 2>/dev/null || true)
      [[ "$public" =~ ^(2|3)[0-9][0-9]$ ]] || code=000
    fi
  fi
fi
if [[ ! "$code" =~ ^(2|3)[0-9][0-9]$ ]]; then
  echo 'Homepage update verification failed; restoring the previous image.' >&2
  [[ -n "$old_ref" ]] || { echo "No previous image reference. Backup: $backup" >&2; exit 1; }
  sed -E "s|^[[:space:]]*image:.*|    image: ${old_ref}|" "${compose}.before-update" > "$compose"
  "${compose_cmd[@]}" up -d --remove-orphans
  curl -fsS --max-time 10 "http://127.0.0.1:${HOMEPAGE_PORT}/" >/dev/null
  echo "Rollback complete. Backup: $backup" >&2
  exit 1
fi
rm -f "${compose}.before-update"
echo "Homepage update verified. Backup: $backup"
SCRIPT
  chmod 0755 /usr/local/bin/homepage-status /usr/local/bin/homepage-backup /usr/local/bin/homepage-update
}

install_homepage() {
  if ! is_true "$ENABLE_HOMEPAGE"; then
    info "Homepage is disabled; existing configuration and data are preserved"
    return 0
  fi
  if is_true "$HOMEPAGE_DOCKER_DISCOVERY"; then
    warn "Homepage Docker discovery exposes the Docker socket to the dashboard container"
  fi
  homepage_install_docker
  local tx stage='transaction-start' rc=0
  tx=$(homepage_transaction_begin)
  [[ ! -d /opt/homepage ]] || homepage_backup_internal >/dev/null || true
  if ! homepage_render_config; then stage='configuration-render'; rc=1
  elif ! homepage_compose config >/dev/null; then stage='compose-validation'; rc=1
  elif ! homepage_compose pull; then stage='image-pull'; rc=1
  elif ! homepage_compose up -d --remove-orphans; then stage='container-start'; rc=1
  elif ! retry 30 2 homepage_verify; then stage='local-http-verification'; rc=1
  fi
  if ((rc != 0)); then
    homepage_transaction_restore "$tx"
    die "Homepage failed during $stage; previous deployment was restored"
  fi
  homepage_install_commands
  rm -rf "$tx"
  info "Homepage verified on 127.0.0.1:${HOMEPAGE_PORT}"
}

