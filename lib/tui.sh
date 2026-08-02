#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

if [[ -n ${PROXMOX_HELPERS_TUI_LOADED:-} ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly PROXMOX_HELPERS_TUI_LOADED=1

ph_tui_available() {
  command -v whiptail >/dev/null 2>&1 && [[ -t 0 && -t 1 ]]
}

ph_tui_message() {
  local title=$1 message=$2
  if ph_tui_available; then
    whiptail --title "$title" --msgbox "$message" 22 84
  else
    printf '\n%s\n%s\n\n' "$title" "$message"
  fi
}

ph_tui_menu() {
  local title=$1 prompt=$2
  shift 2
  if ph_tui_available; then
    whiptail --title "$title" --menu "$prompt" 24 92 14 "$@" 3>&1 1>&2 2>&3
    return
  fi

  local -a args=("$@")
  local index=1 i choice
  printf '\n%s\n%s\n' "$title" "$prompt" >&2
  for ((i=0; i<${#args[@]}; i+=2)); do
    printf '  %d) %-22s %s\n' "$index" "${args[i]}" "${args[i+1]}" >&2
    ((index++))
  done
  read -r -p 'Selection: ' choice
  [[ $choice =~ ^[0-9]+$ ]] || return 1
  ((choice >= 1 && choice < index)) || return 1
  printf '%s\n' "${args[(choice-1)*2]}"
}
