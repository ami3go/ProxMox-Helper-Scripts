#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

printf 'Checking Bash syntax...\n'
mapfile -t bash_files < <(find bin helpers lib scripts tests -type f \( -name '*.sh' -o -path '*/proxmox-helper-scripts' \) -print | sort)
bash_files+=(proxmox-ai-dev-lxc.sh)
for file in "${bash_files[@]}"; do
  bash -n "$file"
done

printf 'Checking Python syntax...\n'
python3 -m py_compile scripts/validate-manifests.py scripts/generate-catalog.py

printf 'Validating static helper manifests and package layout...\n'
./scripts/validate-manifests.py
./bin/proxmox-helper-scripts validate

repo_version=$(tr -d '[:space:]' < VERSION)
launcher_version=$(sed -n 's/^readonly LAUNCHER_VERSION="\([^"]*\)"/\1/p' bin/proxmox-helper-scripts | head -n 1)
[[ -n $launcher_version ]] || fail 'LAUNCHER_VERSION was not found.'
[[ $repo_version == "$launcher_version" ]] || fail "VERSION=$repo_version but LAUNCHER_VERSION=$launcher_version"
printf 'Repository version: %s\n' "$repo_version"

printf 'Checking helper entrypoint versions...\n'
while IFS= read -r manifest; do
  # shellcheck disable=SC1090
  source "$manifest"
  helper_dir=$(dirname -- "$manifest")
  entry="$helper_dir/$HELPER_ENTRYPOINT"
  script_version=$(sed -n 's/^readonly SCRIPT_VERSION="\([^"]*\)"/\1/p' "$entry" | head -n 1)
  if [[ -n $script_version && $script_version != "$HELPER_VERSION" ]]; then
    fail "$entry has SCRIPT_VERSION=$script_version but manifest has HELPER_VERSION=$HELPER_VERSION"
  fi
  [[ -x $entry ]] || fail "Helper entrypoint is not executable: $entry"
done < <(find helpers -mindepth 2 -maxdepth 2 -name manifest.env -type f | sort)

printf 'Checking embedded AI Development LXC provisioner syntax...\n'
tmp=$(mktemp)
catalog_md=""
catalog_json=""
export_dir=""
trap 'rm -f "$tmp" ${catalog_md:+"$catalog_md"} ${catalog_json:+"$catalog_json"}; rm -rf ${export_dir:+"$export_dir"}' EXIT
awk '
  /cat >"\$provision_file" <<'"'"'PROVISION'"'"'/ {capture=1; next}
  capture && /^PROVISION$/ {exit}
  capture {print}
' helpers/ai-dev-lxc/install.sh >"$tmp"
[[ -s $tmp ]] || fail 'Could not extract the embedded provisioner.'
bash -n "$tmp"

printf 'Checking generated catalogs...\n'
catalog_md=$(mktemp)
catalog_json=$(mktemp)
cp HELPERS.md "$catalog_md" 2>/dev/null || true
cp docs/data/helpers.json "$catalog_json" 2>/dev/null || true
./scripts/generate-catalog.py
if [[ -s $catalog_md ]]; then
  cmp -s HELPERS.md "$catalog_md" || fail 'HELPERS.md is stale. Run ./scripts/generate-catalog.py.'
fi
if [[ -s $catalog_json ]]; then
  cmp -s docs/data/helpers.json "$catalog_json" || fail 'docs/data/helpers.json is stale. Run ./scripts/generate-catalog.py.'
fi

printf 'Running repository tests...\n'
for test_file in tests/*.sh; do
  "$test_file"
done
for test_file in helpers/*/tests/*.sh; do
  [[ -e $test_file ]] || continue
  "$test_file"
done

printf 'Checking helper bundle export...\n'
export_dir=$(mktemp -d)
./scripts/export-helpers.sh "$export_dir"
[[ -f $export_dir/ai-dev-lxc-bundle-v2.2.0.zip ]] || fail 'AI helper ZIP bundle was not exported.'
[[ -f $export_dir/ai-dev-lxc-bundle-v2.2.0.tar.gz ]] || fail 'AI helper TAR.GZ bundle was not exported.'
[[ -f $export_dir/ai-dev-lxc.sh ]] || fail 'AI standalone helper was not exported.'
unzip -l "$export_dir/ai-dev-lxc-bundle-v2.2.0.zip" | grep -Fq 'ai-dev-lxc/files/README.md' || fail 'Helper bundle does not contain resource files.'

for file in docs/index.html docs/styles.css docs/app.js docs/404.html docs/.nojekyll docs/data/helpers.json; do
  [[ -f $file ]] || fail "Missing Pages file: $file"
done

for token in 'actions/checkout@v6' 'actions/configure-pages@v5' 'actions/upload-pages-artifact@v4' 'actions/deploy-pages@v4'; do
  grep -Fq "$token" .github/workflows/pages.yml || fail "Pages workflow is missing $token"
done

grep -Fq 'data/helpers.json' docs/app.js || fail 'Pages JavaScript does not load the helper catalog.'
grep -Fq 'helper-catalog' docs/index.html || fail 'Pages site does not contain the helper catalog mount point.'

if command -v shellcheck >/dev/null 2>&1; then
  printf 'Running ShellCheck...\n'
  shellcheck "${bash_files[@]}"
else
  printf 'WARNING: shellcheck is not installed; static lint was skipped.\n' >&2
fi

printf 'Validation passed.\n'
