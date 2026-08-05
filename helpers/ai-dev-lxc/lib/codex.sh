#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
set -Eeuo pipefail

LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=common.sh
source "$LIB_DIR/common.sh"
# shellcheck source=state.sh
source "$LIB_DIR/state.sh"

codex_user_home() {
  getent passwd "$CODEX_LINUX_USER" | cut -d: -f6
}

codex_user_group() {
  id -gn "$CODEX_LINUX_USER"
}

codex_run() {
  local home
  home=$(codex_user_home)
  runuser -u "$CODEX_LINUX_USER" -- env HOME="$home" USER="$CODEX_LINUX_USER" LOGNAME="$CODEX_LINUX_USER" PATH="$home/.local/bin:$home/bin:/usr/local/bin:/usr/bin:/bin" "$@"
}

codex_discover_binary() {
  local home candidate
  home=$(codex_user_home)
  for candidate in \
    "$CODEX_INSTALLED_PATH" \
    "$home/.local/bin/codex" \
    "$home/bin/codex" \
    "$home/.codex/bin/codex" \
    /usr/local/bin/codex \
    /usr/bin/codex; do
    [[ -n "$candidate" && -x "$candidate" ]] && { printf '%s' "$candidate"; return 0; }
  done
  codex_run bash -lc 'command -v codex' 2>/dev/null | head -n1
}

codex_validate_user() {
  id "$CODEX_LINUX_USER" >/dev/null 2>&1 || die "Codex user does not exist: $CODEX_LINUX_USER"
  [[ "$CODEX_LINUX_USER" != root ]] || die "Codex must run as a non-root development user"
  local home
  home=$(codex_user_home)
  [[ -n "$home" && -d "$home" ]] || die "Codex user home is missing: $home"
  codex_run test -w "$home" || die "Codex user home is not writable by $CODEX_LINUX_USER: $home"
  install -d -o "$CODEX_LINUX_USER" -g "$(codex_user_group)" -m 0755 "$CODEX_WORKSPACE_ROOT"
  codex_run test -w "$CODEX_WORKSPACE_ROOT" || die "Codex user cannot write to $CODEX_WORKSPACE_ROOT"
  CODEX_HOME="$home/.codex"
}

codex_install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl git gnupg gnome-keyring libsecret-1-0 dbus-user-session bubblewrap
}

codex_write_config() {
  local home config tmp backup_dir
  home=$(codex_user_home)
  CODEX_HOME="$home/.codex"
  install -d -o "$CODEX_LINUX_USER" -g "$(codex_user_group)" -m 0700 "$CODEX_HOME"
  config="$CODEX_HOME/config.toml"
  tmp=$(mktemp)
  if [[ -f "$config" ]]; then
    backup_dir="$CODEX_HOME/backups"
    install -d -o "$CODEX_LINUX_USER" -g "$(codex_user_group)" -m 0700 "$backup_dir"
    cp -a "$config" "$backup_dir/config.toml-$(timestamp)"
    chmod 0600 "$backup_dir"/config.toml-* 2>/dev/null || true
    awk '
      /^# BEGIN AI-DEV-LXC MANAGED AUTH$/ {managed=1; next}
      /^# END AI-DEV-LXC MANAGED AUTH$/ {managed=0; next}
      managed {next}
      /^[[:space:]]*(cli_auth_credentials_store|forced_login_method)[[:space:]]*=/ {next}
      {print}
    ' "$config" >"$tmp"
    printf '\n' >>"$tmp"
  else
    printf '# Codex configuration managed in part by AI Development LXC helper v%s\n' "$AI_DEV_VERSION" >"$tmp"
  fi
  printf '# BEGIN AI-DEV-LXC MANAGED AUTH\n' >>"$tmp"
  printf 'cli_auth_credentials_store = "%s"\n' "$CODEX_CREDENTIAL_STORE" >>"$tmp"
  if [[ "$CODEX_AUTH_MODE" == chatgpt ]]; then
    printf 'forced_login_method = "chatgpt"\n' >>"$tmp"
  else
    printf 'forced_login_method = "api"\n' >>"$tmp"
  fi
  printf '# END AI-DEV-LXC MANAGED AUTH\n' >>"$tmp"
  install -o "$CODEX_LINUX_USER" -g "$(codex_user_group)" -m 0600 "$tmp" "$config"
  rm -f "$tmp"
  chmod 0700 "$CODEX_HOME"
  [[ ! -e "$CODEX_HOME/auth.json" ]] || chmod 0600 "$CODEX_HOME/auth.json"
}

codex_install_binary() {
  local binary version home
  home=$(codex_user_home)
  binary=$(codex_discover_binary || true)
  if [[ -x "$binary" ]]; then
    info "Codex already installed at $binary; preserving the current binary during repair"
  else
    info "Installing Codex CLI through the official standalone installer for $CODEX_LINUX_USER"
    codex_run bash -lc 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
    binary=$(codex_discover_binary || true)
    [[ -n "$binary" && -x "$binary" ]] || die "Codex installer completed but no executable was found"
  fi
  version=$(codex_run "$binary" --version 2>/dev/null | head -n1 || true)
  [[ -n "$version" ]] || die "Codex binary did not return a version"
  CODEX_INSTALLED_PATH="$binary"
  CODEX_INSTALLED_VERSION="$version"
  CODEX_INSTALL_TIMESTAMP="$(date -Iseconds)"
  CODEX_INSTALL_METHOD="official-standalone"
  install -d -m 0755 /etc/ai-development
  cat > /etc/ai-development/codex.env <<ENV
CODEX_LINUX_USER=$(shell_quote "$CODEX_LINUX_USER")
CODEX_AUTH_MODE=$(shell_quote "$CODEX_AUTH_MODE")
CODEX_CREDENTIAL_STORE=$(shell_quote "$CODEX_CREDENTIAL_STORE")
CODEX_HOME=$(shell_quote "$CODEX_HOME")
CODEX_INSTALLED_PATH=$(shell_quote "$CODEX_INSTALLED_PATH")
CODEX_INSTALLED_VERSION=$(shell_quote "$CODEX_INSTALLED_VERSION")
CODEX_WORKSPACE_ROOT=$(shell_quote "$CODEX_WORKSPACE_ROOT")
ENV
  chmod 0644 /etc/ai-development/codex.env
}

codex_install_commands() {
  cat > /usr/local/bin/codex-login <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-development/codex.env
home=$(getent passwd "$CODEX_LINUX_USER" | cut -d: -f6)
if [[ "$CODEX_AUTH_MODE" == chatgpt ]]; then
  echo "Starting device-code login for ChatGPT subscription access."
  echo "Included usage is plan-limited; no API key is required."
  exec runuser -u "$CODEX_LINUX_USER" -- env HOME="$home" PATH="$(dirname "$CODEX_INSTALLED_PATH"):$home/.local/bin:/usr/local/bin:/usr/bin:/bin" "$CODEX_INSTALLED_PATH" login --device-auth
fi
cat >&2 <<'MSG'
API-key mode is configured and is billed separately through the OpenAI Platform.
Set OPENAI_API_KEY only for this command, for example:
  printenv OPENAI_API_KEY | codex login --with-api-key
MSG
exit 2
SCRIPT

  cat > /usr/local/bin/codex-logout <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/ai-development/codex.env
home=$(getent passwd "$CODEX_LINUX_USER" | cut -d: -f6)
exec runuser -u "$CODEX_LINUX_USER" -- env HOME="$home" PATH="$(dirname "$CODEX_INSTALLED_PATH"):$home/.local/bin:/usr/local/bin:/usr/bin:/bin" "$CODEX_INSTALLED_PATH" logout
SCRIPT

  cat > /usr/local/bin/codex-status <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
check=0
[[ ${1:-} == --check ]] && check=1
source /etc/ai-development/codex.env
home=$(getent passwd "$CODEX_LINUX_USER" | cut -d: -f6)
failed=0
printf 'Configured user:       %s\n' "$CODEX_LINUX_USER"
printf 'Executable:            %s\n' "$CODEX_INSTALLED_PATH"
printf 'Configured auth mode:  %s\n' "$CODEX_AUTH_MODE"
printf 'Credential store:      %s\n' "$CODEX_CREDENTIAL_STORE"
printf 'Workspace:             %s\n' "$CODEX_WORKSPACE_ROOT"
if [[ ! -x "$CODEX_INSTALLED_PATH" ]]; then
  echo 'Binary:                MISSING'
  failed=1
else
  version=$(runuser -u "$CODEX_LINUX_USER" -- env HOME="$home" "$CODEX_INSTALLED_PATH" --version 2>/dev/null | head -n1 || true)
  printf 'Version:               %s\n' "${version:-unavailable}"
  [[ -n "$version" ]] || failed=1
fi
for path in "$home/.codex" "$home/.codex/config.toml"; do
  [[ -e "$path" ]] || { printf 'Missing:               %s\n' "$path"; failed=1; continue; }
  mode=$(stat -c '%a' "$path")
  printf 'Permissions %-10s %s\n' "$mode" "$path"
done
if [[ -e "$home/.codex/auth.json" ]]; then
  mode=$(stat -c '%a' "$home/.codex/auth.json")
  [[ "$mode" == 600 ]] || failed=1
  printf 'File auth cache:       present, mode %s (contents hidden)\n' "$mode"
else
  echo 'File auth cache:       absent (may be unauthenticated or stored in keyring)'
fi
login_output=$(runuser -u "$CODEX_LINUX_USER" -- env HOME="$home" "$CODEX_INSTALLED_PATH" login status 2>&1 || true)
case "${login_output,,}" in
  *not*logged*in*|*not*authenticated*|*signed*out*) active=not-authenticated ;;
  *api*key*) active=api ;;
  *chatgpt*|*logged*in*) active=chatgpt ;;
  *) active=not-authenticated ;;
esac
printf 'Detected login:        %s\n' "$active"
if [[ "$CODEX_AUTH_MODE" == chatgpt && "$active" == api ]]; then
  echo 'ERROR: API-key authentication is active while ChatGPT login is enforced.'
  echo 'Run codex-logout and then codex-login.'
  failed=1
fi
if [[ "$active" == not-authenticated ]]; then
  echo 'Login is deferred. Run codex-login when ready.'
fi
if ((failed)); then
  echo 'Result:                FAIL'
  ((check)) && exit 1
else
  echo 'Result:                PASS'
fi
SCRIPT

  cat > /usr/local/bin/codex-update <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo 'Run with sudo/root.' >&2; exit 1; }
source /etc/ai-development/codex.env
home=$(getent passwd "$CODEX_LINUX_USER" | cut -d: -f6)
config_checksum=none
[[ -f "$home/.codex/config.toml" ]] && config_checksum=$(sha256sum "$home/.codex/config.toml" | awk '{print $1}')
runuser -u "$CODEX_LINUX_USER" -- env HOME="$home" PATH="$home/.local/bin:/usr/local/bin:/usr/bin:/bin" bash -lc 'curl -fsSL https://chatgpt.com/codex/install.sh | sh'
new_path=''
for candidate in "$CODEX_INSTALLED_PATH" "$home/.local/bin/codex" "$home/bin/codex" "$home/.codex/bin/codex"; do
  [[ -x "$candidate" ]] && { new_path=$candidate; break; }
done
[[ -n "$new_path" ]] || { echo 'Updated Codex executable was not found.' >&2; exit 1; }
new_version=$(runuser -u "$CODEX_LINUX_USER" -- env HOME="$home" "$new_path" --version)
if [[ "$config_checksum" != none ]]; then
  [[ $(sha256sum "$home/.codex/config.toml" | awk '{print $1}') == "$config_checksum" ]] || { echo 'Managed Codex configuration changed unexpectedly.' >&2; exit 1; }
fi
quoted_path=$(printf %q "$new_path")
quoted_version=$(printf %q "$new_version")
for state_file in /etc/ai-development/codex.env /etc/ai-development-gateway.env; do
  [[ -f "$state_file" ]] || continue
  sed -i "s|^CODEX_INSTALLED_PATH=.*|CODEX_INSTALLED_PATH=${quoted_path}|; s|^CODEX_INSTALLED_VERSION=.*|CODEX_INSTALLED_VERSION=${quoted_version}|" "$state_file"
done
echo "Codex updated: $new_version"
SCRIPT

  chmod 0755 /usr/local/bin/codex-login /usr/local/bin/codex-logout /usr/local/bin/codex-status /usr/local/bin/codex-update
}

codex_verify() {
  local binary mode
  binary=$(codex_discover_binary || true)
  [[ -n "$binary" && -x "$binary" ]] || return 1
  codex_run "$binary" --version >/dev/null
  codex_run test -w "$CODEX_WORKSPACE_ROOT"
  [[ -d "$CODEX_HOME" && $(stat -c '%a' "$CODEX_HOME") == 700 ]]
  [[ -f "$CODEX_HOME/config.toml" && $(stat -c '%a' "$CODEX_HOME/config.toml") == 600 ]]
  if [[ -e "$CODEX_HOME/auth.json" ]]; then
    mode=$(stat -c '%a' "$CODEX_HOME/auth.json")
    [[ "$mode" == 600 ]] || return 1
  fi
}

install_codex() {
  is_true "$ENABLE_CODEX_CLI" || { info "Codex CLI is disabled; existing installation is preserved"; return 0; }
  codex_validate_user
  codex_install_packages
  codex_install_binary
  codex_write_config
  codex_install_commands
  codex_verify || die "Codex CLI verification failed"
  info "Codex CLI verified for $CODEX_LINUX_USER; interactive login may be completed later with codex-login"
}
