#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/bindings.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/code.yaml" <<'YAML'
bind-addr: 0.0.0.0:8080
auth: password
password: keep-me
cert: false
YAML
patch_code_server_config "$tmp/code.yaml" 8080
grep -q '^bind-addr: 127.0.0.1:8080$' "$tmp/code.yaml"
grep -q '^password: keep-me$' "$tmp/code.yaml"
cat > "$tmp/fb-v1.yaml" <<'YAML'
server:
  port: 8081
  database: database.db
auth:
  adminUsername: admin
YAML
patch_filebrowser_config "$tmp/fb-v1.yaml"
python3 - "$tmp/fb-v1.yaml" <<'PY'
import sys,yaml
x=yaml.safe_load(open(sys.argv[1])); assert x['server']['listen']=='127.0.0.1'; assert x['auth']['adminUsername']=='admin'
PY
cat > "$tmp/fb-v2.yaml" <<'YAML'
http:
  port: 8081
server:
  database:
    path: filebrowser.sqlite
YAML
patch_filebrowser_config "$tmp/fb-v2.yaml"
python3 - "$tmp/fb-v2.yaml" <<'PY'
import sys,yaml
x=yaml.safe_load(open(sys.argv[1])); assert x['http']['listen']=='127.0.0.1'; assert x['server']['database']['path']=='filebrowser.sqlite'
PY
cat > "$tmp/termix.yaml" <<'YAML'
services:
  termix:
    image: ghcr.io/lukegus/termix:latest
    ports:
      - "8082:8080"
    volumes:
      - termix-data:/app/data
volumes:
  termix-data:
    name: termix-data
YAML
patch_termix_compose "$tmp/termix.yaml" 8082
grep -q '127.0.0.1:8082:8080' "$tmp/termix.yaml"
grep -q 'termix-data:/app/data' "$tmp/termix.yaml"
echo 'PASS: backend binding changes preserve credentials/data references'
