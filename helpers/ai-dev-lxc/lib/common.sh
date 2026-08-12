#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

AI_DEV_VERSION="${AI_DEV_VERSION:-2.2.7}"
AI_DEV_STATE_FILE="${AI_DEV_STATE_FILE:-/etc/ai-development-gateway.env}"
AI_DEV_LOG_DIR="${AI_DEV_LOG_DIR:-/var/log/ai-development-gateway}"
AI_DEV_LOG_FILE="${AI_DEV_LOG_FILE:-$AI_DEV_LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log}"
AI_DEV_BACKUP_ROOT="${AI_DEV_BACKUP_ROOT:-/var/backups/ai-development-gateway}"

ensure_runtime_dirs() {
  install -d -m 0700 "$AI_DEV_LOG_DIR" "$AI_DEV_BACKUP_ROOT"
  touch "$AI_DEV_LOG_FILE"
  chmod 0600 "$AI_DEV_LOG_FILE"
}

log() {
  ensure_runtime_dirs
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$AI_DEV_LOG_FILE" >&2
}

info() { log "INFO: $*"; }
warn() { log "WARNING: $*"; }
die() { log "ERROR: $*"; exit 1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this command as root."
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

is_true() {
  case "${1:-}" in
    1|true|TRUE|yes|YES|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

bool_value() { is_true "${1:-}" && printf true || printf false; }

shell_quote() { printf '%q' "$1"; }

timestamp() { date +%Y%m%d-%H%M%S; }

backup_path() {
  local path label stamp
  path=$1
  label=${2:-$(basename "$path")}
  stamp=${3:-$(timestamp)}
  local dest="$AI_DEV_BACKUP_ROOT/$stamp/$label"
  [[ -e "$path" ]] || return 0
  install -d -m 0700 "$(dirname "$dest")"
  if [[ -d "$path" ]]; then
    cp -a "$path" "$dest"
  else
    cp -a "$path" "$dest"
  fi
  printf '%s' "$dest"
}

atomic_write() {
  local target=$1 mode=${2:-0644}
  local tmp
  install -d -m 0755 "$(dirname "$target")"
  tmp=$(mktemp "${target}.tmp.XXXXXX")
  cat >"$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$target"
}

retry() {
  local attempts=$1 delay=$2
  shift 2
  local i rc=0
  for ((i=1; i<=attempts; i++)); do
    if "$@"; then return 0; fi
    rc=$?
    (( i == attempts )) && break
    sleep "$delay"
  done
  return "$rc"
}

http_status_ok() {
  local code=${1:-000}
  [[ "$code" =~ ^(2|3)[0-9][0-9]$ || "$code" == 401 || "$code" == 403 ]]
}

http_probe() {
  local url=$1 host_header=${2:-} insecure=${3:-false}
  local args=(-sS -o /dev/null -w '%{http_code}' --connect-timeout 4 --max-time 10)
  [[ -n "$host_header" ]] && args+=(-H "Host: $host_header")
  is_true "$insecure" && args+=(-k)
  curl "${args[@]}" "$url" 2>/dev/null || printf 000
}

validate_hostname_label() {
  local value=$1
  [[ ${#value} -le 63 && "$value" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]
}

validate_domain() {
  local domain=$1 label
  [[ ${#domain} -le 253 && "$domain" == *.* ]] || return 1
  IFS=. read -r -a labels <<<"$domain"
  for label in "${labels[@]}"; do validate_hostname_label "$label" || return 1; done
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535))
}

safe_source_env() {
  local file=$1 owner mode key value decoded
  [[ -r "$file" ]] || return 1
  owner=$(stat -c '%u' "$file" 2>/dev/null || printf 1)
  mode=$(stat -c '%a' "$file" 2>/dev/null || printf 666)
  [[ "$owner" == 0 ]] || { warn "Refusing non-root-owned state file: $file"; return 1; }
  local group_digit=${mode: -2:1} other_digit=${mode: -1}
  [[ ! "$group_digit" =~ [2367] && ! "$other_digit" =~ [2367] ]] || {
    warn "Refusing group/world-writable state file: $file"
    return 1
  }
  while IFS='=' read -r key value; do
    [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    value=${value%$'\r'}
    # State files are root-owned and generated with printf %q. Decode that
    # representation without sourcing arbitrary statements or unknown keys.
    decoded=''
    eval "decoded=$value"
    printf -v "$key" '%s' "$decoded"
    export "$key"
  done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$file" || true)
}

write_env_file() {
  local target=$1 mode=${2:-0644}
  shift 2
  local key
  {
    printf '# Managed by AI Development LXC helper v%s\n' "$AI_DEV_VERSION"
    for key in "$@"; do
      printf '%s=%q\n' "$key" "${!key-}"
    done
  } | atomic_write "$target" "$mode"
}

service_exists() { systemctl list-unit-files "$1" >/dev/null 2>&1; }

restart_if_exists() {
  local unit=$1
  service_exists "$unit" && systemctl restart "$unit"
}
