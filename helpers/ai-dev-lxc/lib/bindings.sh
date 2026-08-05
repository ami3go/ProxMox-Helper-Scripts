#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$LIB_DIR/common.sh"
source "$LIB_DIR/state.sh"
source "$LIB_DIR/caddy.sh"

BINDING_BACKUP_DIR=''
CODE_SERVER_CONFIG=''
FILEBROWSER_CONFIG=''
TERMIX_COMPOSE='/opt/termix/compose.yaml'

bindings_find_paths() {
  local home
  home=$(getent passwd "$DEV_USER" | cut -d: -f6)
  CODE_SERVER_CONFIG="$home/.config/code-server/config.yaml"
  FILEBROWSER_CONFIG="$home/.config/filebrowser/config.yaml"
  if service_exists filebrowser-quantum.service; then
    local exec_line config_arg
    exec_line=$(systemctl cat filebrowser-quantum.service 2>/dev/null | sed -n 's/^ExecStart=//p' | tail -n1)
    config_arg=$(sed -nE 's/.*(^|[[:space:]])-c[[:space:]]+([^[:space:]]+).*/\2/p' <<<"$exec_line")
    [[ -n "$config_arg" ]] && FILEBROWSER_CONFIG=${config_arg//\$DEV_HOME/$home}
  fi
}

bindings_backup() {
  bindings_find_paths
  BINDING_BACKUP_DIR="$AI_DEV_BACKUP_ROOT/bindings-$(timestamp)"
  install -d -m 0700 "$BINDING_BACKUP_DIR"
  local path label
  for path in "$CODE_SERVER_CONFIG" "$FILEBROWSER_CONFIG" "$TERMIX_COMPOSE"; do
    [[ -e "$path" ]] || continue
    label=$(printf '%s' "$path" | sed 's|^/||; s|/|__|g')
    cp -a "$path" "$BINDING_BACKUP_DIR/$label"
    printf '%s\t%s\n' "$path" "$label" >> "$BINDING_BACKUP_DIR/manifest.tsv"
  done
  chmod 0600 "$BINDING_BACKUP_DIR/manifest.tsv" 2>/dev/null || true
  info "Backend binding backup created: $BINDING_BACKUP_DIR"
}

bindings_restore() {
  [[ -n "$BINDING_BACKUP_DIR" && -r "$BINDING_BACKUP_DIR/manifest.tsv" ]] || return 0
  local path label
  while IFS=$'\t' read -r path label; do
    [[ -e "$BINDING_BACKUP_DIR/$label" ]] || continue
    install -d -m 0755 "$(dirname "$path")"
    cp -a "$BINDING_BACKUP_DIR/$label" "$path"
  done < "$BINDING_BACKUP_DIR/manifest.tsv"
  systemctl daemon-reload || true
  restart_if_exists code-server@"$DEV_USER".service || restart_if_exists code-server.service || true
  restart_if_exists filebrowser-quantum.service || true
  if [[ -f "$TERMIX_COMPOSE" ]]; then
    if docker compose version >/dev/null 2>&1; then docker compose -f "$TERMIX_COMPOSE" up -d --remove-orphans || true
    elif command_exists docker-compose; then docker-compose -f "$TERMIX_COMPOSE" up -d --remove-orphans || true
    fi
  fi
  warn "Original backend bindings restored from $BINDING_BACKUP_DIR"
}

patch_code_server_config() {
  local config=$1 port=$2
  if grep -qE '^bind-addr:' "$config"; then
    sed -i -E "s|^bind-addr:.*|bind-addr: 127.0.0.1:${port}|" "$config"
  else
    printf '\nbind-addr: 127.0.0.1:%s\n' "$port" >> "$config"
  fi
}

patch_filebrowser_config() {
  local config=$1
  FILEBROWSER_CONFIG="$config" python3 - <<'PYFB'
import os
from pathlib import Path
import yaml
path = Path(os.environ["FILEBROWSER_CONFIG"])
data = yaml.safe_load(path.read_text()) or {}
if not isinstance(data, dict):
    raise SystemExit("FileBrowser config root must be a YAML mapping")
if isinstance(data.get("http"), dict):
    data["http"]["listen"] = "127.0.0.1"
else:
    server = data.setdefault("server", {})
    if not isinstance(server, dict):
        raise SystemExit("FileBrowser server section must be a mapping")
    server["listen"] = "127.0.0.1"
path.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True))
PYFB
}

patch_termix_compose() {
  local compose=$1 port=$2
  TERMIX_PORT="$port" TERMIX_COMPOSE="$compose" python3 - <<'PYTERM'
import os, re
from pathlib import Path
path = Path(os.environ["TERMIX_COMPOSE"])
port = os.environ["TERMIX_PORT"]
text = path.read_text()
patterns = [
    rf'(?m)^(\s*-\s*["\']?){re.escape(port)}:8080(["\']?\s*)$',
    rf'(?m)^(\s*-\s*["\']?)0\.0\.0\.0:{re.escape(port)}:8080(["\']?\s*)$',
]
replacement = rf'\g<1>127.0.0.1:{port}:8080\g<2>'
for pattern in patterns:
    new, count = re.subn(pattern, replacement, text)
    if count:
        text = new
        break
else:
    if f"127.0.0.1:{port}:8080" not in text:
        raise SystemExit("Termix 8080 port mapping was not found; refusing an unsafe rewrite")
path.write_text(text)
PYTERM
}

restrict_code_server() {
  is_true "$CODE_SERVER_ENABLED" || return 0
  [[ -f "$CODE_SERVER_CONFIG" ]] || { warn "code-server configuration not found: $CODE_SERVER_CONFIG"; return 1; }
  patch_code_server_config "$CODE_SERVER_CONFIG" "$CODE_SERVER_PORT" || return 1
  if service_exists code-server@"$DEV_USER".service; then systemctl restart code-server@"$DEV_USER".service || return 1
  elif service_exists code-server.service; then systemctl restart code-server.service || return 1
  else warn "code-server systemd service was not found"; return 1; fi
}

restrict_filebrowser() {
  is_true "$FILE_MANAGER_ENABLED" || return 0
  [[ -f "$FILEBROWSER_CONFIG" ]] || { warn "FileBrowser Quantum configuration not found: $FILEBROWSER_CONFIG"; return 1; }
  apt-get install -y --no-install-recommends python3-yaml >/dev/null || return 1
  patch_filebrowser_config "$FILEBROWSER_CONFIG" || return 1
  systemctl restart filebrowser-quantum.service || return 1
}

restrict_termix() {
  is_true "$TERMIX_ENABLED" || return 0
  [[ -f "$TERMIX_COMPOSE" ]] || { warn "Termix Compose file not found: $TERMIX_COMPOSE"; return 1; }
  patch_termix_compose "$TERMIX_COMPOSE" "$TERMIX_PORT" || return 1
  if docker compose version >/dev/null 2>&1; then docker compose -f "$TERMIX_COMPOSE" up -d --remove-orphans || return 1
  elif command_exists docker-compose; then docker-compose -f "$TERMIX_COMPOSE" up -d --remove-orphans || return 1
  else warn "Docker Compose is unavailable"; return 1
  fi
}

listener_is_loopback() {
  local port=$1
  ss -H -lnt 2>/dev/null | awk -v p=":${port}" '
    $4 ~ p "$" {
      if ($4 ~ /^127\.0\.0\.1:/ || $4 ~ /^\[::1\]:/) ok=1; else bad=1
    }
    END {exit !(ok && !bad)}'
}

backend_http_verify() {
  local port=$1 code
  code=$(http_probe "http://127.0.0.1:${port}/")
  http_status_ok "$code"
}

websocket_proxy_probe() {
  local host=$1 scheme flags=() code
  scheme=$(gateway_scheme)
  [[ "$scheme" == https ]] && flags=(-k)
  code=$(curl "${flags[@]}" -sS -o /dev/null -w '%{http_code}' --http1.1 \
    -H "Host: $host" -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
    --max-time 8 "${scheme}://127.0.0.1/" 2>/dev/null || true)
  [[ "$code" != 000 && "$code" != 502 && "$code" != 503 && "$code" != 504 ]]
}

bindings_verify_restricted() {
  if is_true "$CODE_SERVER_ENABLED"; then
    listener_is_loopback "$CODE_SERVER_PORT" && backend_http_verify "$CODE_SERVER_PORT" && caddy_verify_local_route "$(fqdn_code)" && websocket_proxy_probe "$(fqdn_code)" || return 1
  fi
  if is_true "$FILE_MANAGER_ENABLED"; then
    listener_is_loopback "$FILE_MANAGER_PORT" && backend_http_verify "$FILE_MANAGER_PORT" && caddy_verify_local_route "$(fqdn_files)" || return 1
  fi
  if is_true "$TERMIX_ENABLED"; then
    local published
    published=$(docker port termix 8080/tcp 2>/dev/null || true)
    [[ "$published" == 127.0.0.1:"$TERMIX_PORT"* ]] || return 1
    backend_http_verify "$TERMIX_PORT" && caddy_verify_local_route "$(fqdn_termix)" && websocket_proxy_probe "$(fqdn_termix)" || return 1
  fi
}

restrict_backend_bindings() {
  is_true "$RESTRICT_BACKEND_PORTS" || { info "Backend services remain available on their existing direct LAN ports"; return 0; }
  is_true "$ENABLE_CADDY" || die "Backend restriction requires Caddy"
  caddy_verify || die "Proxy routes must pass before backend ports can be restricted"
  bindings_backup
  local rc=0 stage='code-server'
  restrict_code_server || rc=$?
  if ((rc == 0)); then stage='FileBrowser Quantum'; restrict_filebrowser || rc=$?; fi
  if ((rc == 0)); then stage='Termix'; restrict_termix || rc=$?; fi
  if ((rc != 0)); then
    bindings_restore
    die "Backend binding update failed at $stage; original direct-port access was restored"
  fi
  if ! retry 20 1 bindings_verify_restricted; then
    bindings_restore
    retry 15 1 caddy_verify || true
    die "Post-restriction verification failed; original direct-port access was restored"
  fi
  info "Backend services are restricted to localhost and verified through Caddy"
}
