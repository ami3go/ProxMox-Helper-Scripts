#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$ROOT_DIR"

usage() {
  cat <<'EOF_USAGE'
Usage:
  ./scripts/publish-to-github.sh [OWNER/REPOSITORY|REPOSITORY] [public|private|internal]

Example:
  ./scripts/publish-to-github.sh my-user/proxmox-helper-scripts public
EOF_USAGE
}

[[ ${1:-} != '-h' && ${1:-} != '--help' ]] || { usage; exit 0; }

for command in git gh; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'ERROR: %s is required.\n' "$command" >&2
    exit 1
  }
done

gh auth status >/dev/null 2>&1 || {
  printf 'GitHub CLI is not authenticated. Run: gh auth login\n' >&2
  exit 1
}

REPO_INPUT=${1:-proxmox-helper-scripts}
VISIBILITY=${2:-public}
case $VISIBILITY in
  public|private|internal) ;;
  *) printf 'ERROR: visibility must be public, private, or internal.\n' >&2; exit 1 ;;
esac

if [[ $REPO_INPUT == */* ]]; then
  REPOSITORY=$REPO_INPUT
else
  OWNER=$(gh api user --jq .login)
  REPOSITORY="$OWNER/$REPO_INPUT"
fi

./scripts/generate-catalog.py
./scripts/validate.sh

# Replace documentation placeholders only while they retain the template value.
grep -rlZ 'YOUR_GITHUB_USERNAME/proxmox-helper-scripts' README.md docs 2>/dev/null \
  | xargs -0r sed -i "s#YOUR_GITHUB_USERNAME/proxmox-helper-scripts#$REPOSITORY#g"

if [[ ! -d .git ]]; then
  git init -b main
fi

git checkout -B main
git add .
if ! git diff --cached --quiet; then
  git commit -m 'Initial release of Proxmox Helper Scripts'
fi

if gh repo view "$REPOSITORY" >/dev/null 2>&1; then
  printf 'Repository already exists: %s\n' "$REPOSITORY"
  if ! git remote get-url origin >/dev/null 2>&1; then
    git remote add origin "https://github.com/$REPOSITORY.git"
  fi
  git push -u origin main
else
  visibility_flag="--$VISIBILITY"
  gh repo create "$REPOSITORY" \
    "$visibility_flag" \
    --source=. \
    --remote=origin \
    --push \
    --description 'Extensible manifest-driven Proxmox VE helper scripts with a central TUI launcher'
fi

if gh api "repos/$REPOSITORY/pages" >/dev/null 2>&1; then
  gh api --method PUT "repos/$REPOSITORY/pages" -f build_type=workflow >/dev/null \
    || printf 'WARNING: Could not switch Pages to workflow mode.\n' >&2
else
  gh api --method POST "repos/$REPOSITORY/pages" -f build_type=workflow >/dev/null \
    || printf 'WARNING: Could not enable Pages automatically. Use Settings -> Pages -> GitHub Actions.\n' >&2
fi

PAGES_URL=$(gh api "repos/$REPOSITORY/pages" --jq .html_url 2>/dev/null || true)
if [[ -n $PAGES_URL ]]; then
  gh api --method PATCH "repos/$REPOSITORY" -f homepage="$PAGES_URL" >/dev/null 2>&1 || true
fi

printf '\nPublished successfully.\n'
printf 'Repository: https://github.com/%s\n' "$REPOSITORY"
printf 'Pages:      %s\n' "${PAGES_URL:-Enable or inspect it under Settings -> Pages}"
printf '\nThe Pages workflow starts after the push. Check the Actions tab for deployment status.\n'
