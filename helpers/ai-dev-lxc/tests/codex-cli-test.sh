#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$ROOT/lib/common.sh"
source "$ROOT/lib/state.sh"
source "$ROOT/lib/codex.sh"
TEST_TMP=$(mktemp -d); trap 'rm -rf "$TEST_TMP"' EXIT
state_defaults
CODEX_LINUX_USER=nobody
CODEX_AUTH_MODE=chatgpt
CODEX_CREDENTIAL_STORE=auto
codex_user_home() { printf '%s' "$TEST_TMP/home"; }
mkdir -p "$TEST_TMP/home/.codex"
cat > "$TEST_TMP/home/.codex/config.toml" <<'TOML'
model = "preserve-me"
forced_login_method = "api"
# BEGIN AI-DEV-LXC MANAGED AUTH
cli_auth_credentials_store = "file"
forced_login_method = "api"
# END AI-DEV-LXC MANAGED AUTH
TOML
codex_write_config
codex_write_config
grep -q 'forced_login_method = "chatgpt"' "$TEST_TMP/home/.codex/config.toml"
grep -q 'cli_auth_credentials_store = "auto"' "$TEST_TMP/home/.codex/config.toml"
grep -q 'model = "preserve-me"' "$TEST_TMP/home/.codex/config.toml"
[[ $(grep -c '^forced_login_method =' "$TEST_TMP/home/.codex/config.toml") -eq 1 ]]
[[ $(grep -c '^# BEGIN AI-DEV-LXC MANAGED AUTH$' "$TEST_TMP/home/.codex/config.toml") -eq 1 ]]
[[ -d "$TEST_TMP/home/.codex/backups" ]]
[[ $(stat -c '%a' "$TEST_TMP/home/.codex") == 700 ]]
[[ $(stat -c '%a' "$TEST_TMP/home/.codex/config.toml") == 600 ]]
grep -q 'https://chatgpt.com/codex/install.sh' "$ROOT/lib/codex.sh"
grep -q 'login --device-auth' "$ROOT/lib/codex.sh"
! grep -R --exclude='codex-cli-test.sh' -E 'sk-[A-Za-z0-9_-]{10,}|OPENAI_API_KEY=' "$ROOT" >/dev/null
for value in auto keyring file; do CODEX_CREDENTIAL_STORE=$value; validate_state; done
CODEX_CREDENTIAL_STORE=invalid
if (validate_state >/dev/null 2>&1); then echo 'invalid credential store accepted' >&2; exit 1; fi
echo 'PASS: Codex CLI configuration and security rules'
