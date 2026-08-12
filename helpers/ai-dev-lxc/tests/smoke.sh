#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# lib/common.sh's log()/ensure_runtime_dirs() default to real system paths
# (/var/log/..., /var/backups/...) that require root. Redirect them to a
# throwaway temp dir so smoke tests run unprivileged, e.g. in CI.
runtime_tmp="$(mktemp -d)"
trap 'rm -rf "$runtime_tmp"' EXIT
export AI_DEV_LOG_DIR="$runtime_tmp/log"
export AI_DEV_BACKUP_ROOT="$runtime_tmp/backups"

# Regression: backup_path must be safe under set -u when its optional label and
# timestamp arguments are omitted. A same-statement local assignment used to
# reference $path before that local value had taken effect.
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
probe="$runtime_tmp/source-file"
printf 'probe\n' >"$probe"
backup=$(backup_path "$probe")
[[ -f "$backup" ]] || { echo "backup_path default-argument regression" >&2; exit 1; }
[[ "$(basename "$backup")" == "source-file" ]] || { echo "backup_path default label is incorrect" >&2; exit 1; }

for file in "$ROOT/install.sh" "$ROOT/extend-existing-lxc.sh" "$ROOT"/lib/*.sh "$ROOT"/tests/*.sh; do bash -n "$file"; done
"$ROOT/tests/state-migration-test.sh"
"$ROOT/tests/codex-cli-test.sh"
"$ROOT/tests/homepage-config-test.sh"
"$ROOT/tests/caddy-config-test.sh"
"$ROOT/tests/binding-change-test.sh"
"$ROOT/tests/rollback-test.sh"
for required in \
  manifest.env install.sh extend-existing-lxc.sh README.md \
  lib/caddy.sh lib/homepage.sh lib/codex.sh lib/bindings.sh lib/state.sh \
  templates/Caddyfile.tpl templates/homepage-compose.yaml.tpl templates/codex-config.toml.tpl \
  files/homepage/services.yaml files/homepage/settings.yaml files/homepage/widgets.yaml files/homepage/bookmarks.yaml files/homepage/docker.yaml; do
  [[ -e "$ROOT/$required" ]] || { echo "Missing required file: $required" >&2; exit 1; }
done
! find "$ROOT" -name auth.json -o -name '*.key' | grep -q .
echo 'PASS: all smoke tests'
