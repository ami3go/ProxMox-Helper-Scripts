#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/bindings.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
AI_DEV_BACKUP_ROOT="$tmp/backups"
DEV_USER=testuser
CODE_SERVER_CONFIG="$tmp/code.yaml"
FILEBROWSER_CONFIG="$tmp/files.yaml"
TERMIX_COMPOSE="$tmp/no-termix.yaml"
printf 'original-code\n' > "$CODE_SERVER_CONFIG"
printf 'original-files\n' > "$FILEBROWSER_CONFIG"
bindings_find_paths() { :; }
service_exists() { return 1; }
restart_if_exists() { :; }
bindings_backup
printf 'broken-code\n' > "$CODE_SERVER_CONFIG"
printf 'broken-files\n' > "$FILEBROWSER_CONFIG"
bindings_restore
grep -q '^original-code$' "$CODE_SERVER_CONFIG"
grep -q '^original-files$' "$FILEBROWSER_CONFIG"
grep -q 'bindings_restore' "$ROOT/lib/bindings.sh"
echo 'PASS: rollback restores backed-up bindings'
