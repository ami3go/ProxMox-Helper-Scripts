#!/usr/bin/env bash
set -Eeuo pipefail

APP_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ai-dev-tui"
TARGET_DIR="${HOME}/.local/bin"
TARGET="${TARGET_DIR}/ai-dev-tui"

sudo_cmd() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    echo "sudo is required to install OS packages." >&2
    exit 1
  fi
}

echo "Installing AI Dev OmniRoute TUI..."

if command -v apt-get >/dev/null 2>&1; then
  sudo_cmd apt-get update
  sudo_cmd apt-get install -y dialog curl git jq ca-certificates
fi

mkdir -p "$TARGET_DIR"
install -m 0755 "$APP_SRC" "$TARGET"

case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *)
    cat >>"$HOME/.profile" <<'EOF'

# User-local binaries
if [ -d "$HOME/.local/bin" ]; then
  PATH="$HOME/.local/bin:$PATH"
fi
EOF
    ;;
esac

echo
echo "Installed: $TARGET"
echo "Run:"
echo "  $TARGET"
echo
echo "Or open a new login shell and run:"
echo "  ai-dev-tui"
