#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LAUNCHER="$ROOT_DIR/bin/proxmox-helper-scripts"

[[ $($LAUNCHER version) == 2.2.0 ]]
$LAUNCHER validate >/dev/null
$LAUNCHER categories | grep -Fq 'development'
$LAUNCHER list | grep -Fq 'ai-dev-lxc'
$LAUNCHER list development | grep -Fq 'ai-dev-lxc'
$LAUNCHER search robot | grep -Fq 'ai-dev-lxc'
$LAUNCHER info ai-dev-lxc | grep -Fq 'helpers/ai-dev-lxc/install.sh'
printf 'Launcher test passed.\n'
