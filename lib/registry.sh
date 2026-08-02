#!/usr/bin/env bash
# SPDX-License-Identifier: MIT

if [[ -n ${PROXMOX_HELPERS_REGISTRY_LOADED:-} ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly PROXMOX_HELPERS_REGISTRY_LOADED=1

PH_REGISTRY_ROOT=${PH_REGISTRY_ROOT:-"$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"}
PH_HELPERS_DIR=${PH_HELPERS_DIR:-"$PH_REGISTRY_ROOT/helpers"}

ph_registry_manifests() {
  [[ -d $PH_HELPERS_DIR ]] || return 0
  find "$PH_HELPERS_DIR" -mindepth 2 -maxdepth 2 -type f -name manifest.env -print | sort
}

ph_manifest_reset() {
  unset HELPER_ID HELPER_NAME HELPER_CATEGORY HELPER_VERSION HELPER_DESCRIPTION
  unset HELPER_ENTRYPOINT HELPER_TARGET HELPER_TAGS HELPER_MAINTAINER
  unset HELPER_DOCS HELPER_STANDALONE
}

ph_manifest_is_static() {
  local manifest=$1 line trimmed
  local assignment_re='^[A-Z_][A-Z0-9_]*="[^"]*"$'
  while IFS= read -r line || [[ -n $line ]]; do
    trimmed=${line#"${line%%[![:space:]]*}"}
    trimmed=${trimmed%"${trimmed##*[![:space:]]}"}
    [[ -z $trimmed || $trimmed == \#* ]] && continue
    [[ $trimmed =~ $assignment_re ]] || return 1
    [[ $trimmed != *'$('* && $trimmed != *'${'* && $trimmed != *'`'* ]] || return 1
    [[ $trimmed != *';'* && $trimmed != *'&&'* && $trimmed != *'||'* ]] || return 1
  done <"$manifest"
}

ph_manifest_load() {
  local manifest=$1
  ph_manifest_reset
  ph_manifest_is_static "$manifest" || {
    printf 'Unsafe or invalid static manifest: %s\n' "$manifest" >&2
    return 1
  }
  # shellcheck disable=SC1090
  source "$manifest"
  PH_MANIFEST_PATH=$manifest
  PH_HELPER_DIR=$(dirname -- "$manifest")
}

ph_manifest_validate_loaded() {
  local required value
  for required in HELPER_ID HELPER_NAME HELPER_CATEGORY HELPER_VERSION HELPER_DESCRIPTION HELPER_ENTRYPOINT HELPER_TARGET; do
    value=${!required:-}
    [[ -n $value ]] || {
      printf 'Manifest %s is missing %s\n' "${PH_MANIFEST_PATH:-unknown}" "$required" >&2
      return 1
    }
  done
  [[ $HELPER_ID =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || return 1
  [[ $HELPER_CATEGORY =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || return 1
  [[ $HELPER_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9._-]+)?$ ]] || return 1
  [[ -f $PH_HELPER_DIR/$HELPER_ENTRYPOINT ]] || return 1
}

ph_registry_find() {
  local wanted=$1 manifest
  while IFS= read -r manifest; do
    ph_manifest_load "$manifest"
    if [[ ${HELPER_ID:-} == "$wanted" ]]; then
      ph_manifest_validate_loaded || return 1
      return 0
    fi
  done < <(ph_registry_manifests)
  return 1
}

ph_registry_list_tsv() {
  local category_filter=${1:-} manifest
  while IFS= read -r manifest; do
    ph_manifest_load "$manifest"
    ph_manifest_validate_loaded || continue
    [[ -z $category_filter || $HELPER_CATEGORY == "$category_filter" ]] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$HELPER_ID" "$HELPER_NAME" "$HELPER_CATEGORY" "$HELPER_VERSION" "$HELPER_DESCRIPTION"
  done < <(ph_registry_manifests)
}

ph_registry_categories() {
  local _id _name category _version _description
  while IFS=$'\t' read -r _id _name category _version _description; do
    printf '%s\n' "$category"
  done < <(ph_registry_list_tsv) | sort -u
}

ph_registry_run() {
  local helper_id=$1
  shift
  ph_registry_find "$helper_id" || {
    printf 'Unknown helper: %s\n' "$helper_id" >&2
    return 1
  }
  local entry="$PH_HELPER_DIR/$HELPER_ENTRYPOINT"
  [[ -x $entry ]] || chmod +x "$entry"
  exec "$entry" "$@"
}
