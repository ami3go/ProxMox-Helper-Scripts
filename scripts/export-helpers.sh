#!/usr/bin/env bash
# Export complete helper folders and optional standalone entrypoints.
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
DEST=${1:-}
[[ -n $DEST ]] || { printf 'Usage: %s DESTINATION\n' "$0" >&2; exit 2; }
mkdir -p "$DEST"
DEST=$(cd -- "$DEST" && pwd)

cd "$ROOT_DIR"
./scripts/validate-manifests.py >/dev/null

while IFS= read -r manifest; do
  # shellcheck disable=SC1090
  source "$manifest"
  helper_dir=$(dirname -- "$manifest")
  stage=$(mktemp -d)
  trap 'rm -rf "${stage:-}"' EXIT
  mkdir -p "$stage/$HELPER_ID"
  cp -a "$helper_dir/." "$stage/$HELPER_ID/"
  (
    cd "$stage"
    tar -czf "$DEST/${HELPER_ID}-bundle-v${HELPER_VERSION}.tar.gz" "$HELPER_ID"
    zip -qr "$DEST/${HELPER_ID}-bundle-v${HELPER_VERSION}.zip" "$HELPER_ID"
  )
  rm -rf "$stage"
  trap - EXIT

  if [[ ${HELPER_STANDALONE:-false} == true ]]; then
    cp "$helper_dir/$HELPER_ENTRYPOINT" "$DEST/${HELPER_ID}.sh"
    cp "$helper_dir/$HELPER_ENTRYPOINT" "$DEST/${HELPER_ID}-v${HELPER_VERSION}.sh"
    if [[ $HELPER_ID == ai-dev-lxc ]]; then
      cp "$helper_dir/$HELPER_ENTRYPOINT" "$DEST/proxmox-ai-dev-lxc.sh"
    fi
  fi

  if [[ -n ${HELPER_POST_INSTALL:-} ]]; then
    cp "$helper_dir/$HELPER_POST_INSTALL" "$DEST/${HELPER_ID}-post-install.sh"
    cp "$helper_dir/$HELPER_POST_INSTALL" "$DEST/${HELPER_ID}-post-install-v${HELPER_VERSION}.sh"
    if [[ $HELPER_ID == ai-dev-lxc ]]; then
      cp "$helper_dir/$HELPER_POST_INSTALL" "$DEST/proxmox-ai-dev-lxc-post-install.sh"
    fi
  fi
done < <(find helpers -mindepth 2 -maxdepth 2 -name manifest.env -type f | sort)
