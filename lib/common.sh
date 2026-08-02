#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

if [[ -n ${PROXMOX_HELPERS_COMMON_LOADED:-} ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly PROXMOX_HELPERS_COMMON_LOADED=1

ph_log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

ph_warn() {
  printf 'WARNING: %s\n' "$*" >&2
}

ph_die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

ph_require_command() {
  command -v "$1" >/dev/null 2>&1 || ph_die "Required command not found: $1"
}

ph_require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || ph_die 'Run this command as root on the Proxmox VE host.'
}

ph_repo_root() {
  local source=${BASH_SOURCE[0]}
  cd -- "$(dirname -- "$source")/.." && pwd
}

ph_is_proxmox_host() {
  command -v pveversion >/dev/null 2>&1 && command -v pct >/dev/null 2>&1
}

ph_confirm() {
  local prompt=${1:-Continue?}
  local default=${2:-no}
  local answer suffix
  if [[ $default == yes ]]; then
    suffix='[Y/n]'
  else
    suffix='[y/N]'
  fi
  read -r -p "$prompt $suffix " answer
  answer=${answer:-$([[ $default == yes ]] && printf Y || printf N)}
  [[ $answer =~ ^[Yy]$ ]]
}
