#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VERSION=2.2.7
payload=$(mktemp)
trap 'rm -f "$payload"' EXIT
tar -C "$ROOT/helpers" -czf - ai-dev-lxc | base64 -w 76 >"$payload"
for output in ai-dev-lxc-v$VERSION.sh ai-dev-lxc.sh proxmox-ai-dev-lxc.sh; do
  {
    cat <<'HEADER'
#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Self-contained AI Development LXC helper bundle.
set -Eeuo pipefail

tmp=$(mktemp -d)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT INT TERM
extract_payload() {
  base64 -d <<'__AI_DEV_LXC_PAYLOAD__' | tar -xzf - -C "$tmp"
HEADER
    cat "$payload"
    cat <<'FOOTER'
__AI_DEV_LXC_PAYLOAD__
}
extract_payload
"$tmp/ai-dev-lxc/install.sh" "$@"
FOOTER
  } >"$ROOT/$output"
  chmod 0755 "$ROOT/$output"
done
