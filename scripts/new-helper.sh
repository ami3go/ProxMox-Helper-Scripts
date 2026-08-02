#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEMPLATE_DIR="$ROOT_DIR/templates/helper"
OUTPUT_ROOT=${HELPER_OUTPUT_ROOT:-"$ROOT_DIR/helpers"}
ID=""
NAME=""
CATEGORY=""
DESCRIPTION=""

usage() {
  cat <<'USAGE'
Create a new self-contained Proxmox helper package.

Usage:
  ./scripts/new-helper.sh --id ID --name NAME --category CATEGORY --description TEXT

Options:
  --id ID                Lowercase helper slug, for example backup-server
  --name NAME            Human-readable helper name
  --category CATEGORY    Search/catalog category, for example storage
  --description TEXT     One-line description
  --help                 Show this help

The helper is created at helpers/<id>/. Category is metadata and does not add
another directory level. Each helper receives folders for assets, files,
helper-local libraries, configuration templates, and tests.
USAGE
}

while (($#)); do
  case $1 in
    --id) ID=${2:-}; shift 2 ;;
    --name) NAME=${2:-}; shift 2 ;;
    --category) CATEGORY=${2:-}; shift 2 ;;
    --description) DESCRIPTION=${2:-}; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -t 0 ]]; then
  [[ -n $ID ]] || read -r -p 'Helper ID: ' ID
  [[ -n $NAME ]] || read -r -p 'Helper name: ' NAME
  [[ -n $CATEGORY ]] || read -r -p 'Category: ' CATEGORY
  [[ -n $DESCRIPTION ]] || read -r -p 'One-line description: ' DESCRIPTION
fi

[[ $ID =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || { printf 'Invalid helper ID: %s\n' "$ID" >&2; exit 1; }
[[ $CATEGORY =~ ^[a-z0-9]+([._-][a-z0-9]+)*$ ]] || { printf 'Invalid category: %s\n' "$CATEGORY" >&2; exit 1; }
[[ -n $NAME ]] || { printf 'Helper name is required.\n' >&2; exit 1; }
[[ -n $DESCRIPTION ]] || { printf 'Description is required.\n' >&2; exit 1; }
python3 - "$NAME" "$DESCRIPTION" <<'PY_VALIDATE'
import sys
for label, value in zip(("name", "description"), sys.argv[1:]):
    if any(token in value for token in ('\n', '\r', '"', '$', '`', ';', '&', '|')):
        raise SystemExit(f"Invalid {label}: quotes, shell metacharacters, and newlines are not allowed")
PY_VALIDATE

DEST="$OUTPUT_ROOT/$ID"
[[ ! -e $DEST ]] || { printf 'Destination already exists: %s\n' "$DEST" >&2; exit 1; }
mkdir -p "$DEST"/{assets,files,lib,templates,tests}

render() {
  local source=$1 destination=$2
  python3 - "$source" "$destination" "$ID" "$NAME" "$CATEGORY" "$DESCRIPTION" <<'PY_RENDER'
from pathlib import Path
import sys
src, dst, helper_id, name, category, description = sys.argv[1:]
text = Path(src).read_text(encoding="utf-8")
for key, value in {
    "__HELPER_ID__": helper_id,
    "__HELPER_NAME__": name,
    "__HELPER_CATEGORY__": category,
    "__HELPER_DESCRIPTION__": description,
}.items():
    text = text.replace(key, value)
Path(dst).write_text(text, encoding="utf-8")
PY_RENDER
}

render "$TEMPLATE_DIR/manifest.env.tpl" "$DEST/manifest.env"
render "$TEMPLATE_DIR/install.sh.tpl" "$DEST/install.sh"
render "$TEMPLATE_DIR/README.md.tpl" "$DEST/README.md"
render "$TEMPLATE_DIR/tests/smoke.sh.tpl" "$DEST/tests/smoke.sh"
for section in assets files lib templates; do
  render "$TEMPLATE_DIR/$section/README.md.tpl" "$DEST/$section/README.md"
done
chmod +x "$DEST/install.sh" "$DEST/tests/smoke.sh"

printf 'Created helper package: %s\n' "$DEST"
printf 'Next steps:\n'
printf '  1. Implement %s/install.sh\n' "$DEST"
printf '  2. Put helper-specific payloads in files/, modules in lib/, and configs in templates/.\n'
printf '  3. Complete requirements, changes, and rollback in %s/README.md\n' "$DEST"
printf '  4. Add tests under %s/tests/\n' "$DEST"
printf '  5. Run ./scripts/validate.sh\n'
