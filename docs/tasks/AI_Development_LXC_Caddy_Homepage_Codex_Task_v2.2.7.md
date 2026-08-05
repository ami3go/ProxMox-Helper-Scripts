# Task: Add Caddy Reverse Proxy, Homepage Dashboard and Codex CLI to AI Development LXC Helper

## Target release

```text
Current version: v2.2.6
Target version:  v2.2.7
Helper:          helpers/ai-dev-lxc/
```

## 1. Objective

Extend the AI Development LXC installer with three optional components:

1. **Caddy** as the central reverse proxy.
2. **Homepage by gethomepage** as the default web start page.
3. **OpenAI Codex CLI** as the terminal-based coding agent for local repositories.

Codex CLI must support ChatGPT-account authentication so a ChatGPT Plus subscriber can use the allowance included with the subscription without configuring an OpenAI API key. Usage remains subject to the limits of the active ChatGPT plan; purchasing additional credits is optional and must never be required by the installer.

The final environment must provide one memorable dashboard URL and friendly hostnames for all enabled services, rather than requiring the user to remember individual TCP ports.

Recommended result:

```text
http://ai-dev.home.arpa
```

Dashboard service links:

```text
http://code.ai-dev.home.arpa
http://files.ai-dev.home.arpa
http://termix.ai-dev.home.arpa
```

Existing backend services must remain independently manageable and must not be removed. Codex CLI is a terminal application and must not expose an HTTP service or additional LAN port.

---

## 2. Existing services

The helper currently supports:

| Service | Existing port | Purpose |
|---|---:|---|
| code-server | 8080 | Browser-based development environment |
| FileBrowser Quantum | 8081 | Web file manager |
| Termix | 8082 | Browser-based SSH terminal manager |

The new components will use:

| Service | Internal port | LAN-facing port |
|---|---:|---:|
| Homepage | 3000 | Through Caddy |
| Caddy HTTP | N/A | 80 |
| Caddy HTTPS | N/A | 443, optional |
| Codex CLI | N/A | No listening port |

---

## 3. Required architecture

```text
Browser
   │
   ├── ai-dev.home.arpa
   ├── code.ai-dev.home.arpa
   ├── files.ai-dev.home.arpa
   └── termix.ai-dev.home.arpa
          │
          ▼
Caddy
   ├── 127.0.0.1:3000 → Homepage
   ├── 127.0.0.1:8080 → code-server
   ├── 127.0.0.1:8081 → FileBrowser Quantum
   └── 127.0.0.1:8082 → Termix
```

Caddy must be the only service required to listen directly on LAN ports 80 and 443 when gateway mode is fully enabled.

Backend applications should be switched to localhost bindings where practical. Codex CLI must run as the non-root development user and operate directly on repositories available to that user.

---

## 4. Repository organization

Keep all helper-specific files inside the AI Development LXC helper package:

```text
helpers/
└── ai-dev-lxc/
    ├── manifest.env
    ├── install.sh
    ├── README.md
    │
    ├── assets/
    │   └── homepage-preview.png
    │
    ├── files/
    │   ├── caddy/
    │   │   └── README.md
    │   │
    │   ├── homepage/
    │   │   ├── services.yaml
    │   │   ├── settings.yaml
    │   │   ├── widgets.yaml
    │   │   ├── bookmarks.yaml
    │   │   └── docker.yaml
    │   │
    │   └── codex/
    │       └── AGENTS.md.example
    │
    ├── lib/
    │   ├── caddy.sh
    │   ├── homepage.sh
    │   └── codex.sh
    │
    ├── templates/
    │   ├── Caddyfile.tpl
    │   ├── homepage-compose.yaml.tpl
    │   ├── homepage-services.yaml.tpl
    │   ├── homepage-settings.yaml.tpl
    │   └── codex-config.toml.tpl
    │
    └── tests/
        ├── smoke.sh
        ├── caddy-config-test.sh
        ├── homepage-config-test.sh
        └── codex-cli-test.sh
```

Do not place generated runtime configuration directly in the repository root.

---

## 5. TUI changes

Add a new configuration section:

```text
Web Services Gateway
```

### 5.1 Enable Homepage

Prompt:

```text
Install Homepage dashboard?
```

Options:

```text
Yes
No
```

Default for new installations:

```text
Yes
```

Default for existing managed containers:

```text
Preserve current state
```

### 5.2 Enable Caddy

Prompt:

```text
Install Caddy reverse proxy?
```

Options:

```text
Yes
No
```

Default:

```text
Yes when Homepage is selected
```

If Homepage is enabled and Caddy is disabled, display a warning that Homepage will remain accessible by IP and port.

### 5.3 Domain suffix

Prompt:

```text
Local domain suffix
```

Default:

```text
home.arpa
```

Generated hostnames:

```text
ai-dev.home.arpa
code.ai-dev.home.arpa
files.ai-dev.home.arpa
termix.ai-dev.home.arpa
```

The hostname prefix should be derived from the service name and remain editable.

### 5.4 Gateway hostname

Prompt:

```text
Dashboard hostname
```

Default:

```text
ai-dev
```

Result:

```text
ai-dev.home.arpa
```

### 5.5 HTTPS mode

Provide:

```text
HTTP only
HTTPS with Caddy internal CA
```

Default:

```text
HTTP only
```

For internal HTTPS, warn that the Caddy root certificate must be installed on client devices.

### 5.6 Backend exposure

Prompt:

```text
Restrict backend service ports to localhost after enabling Caddy?
```

Default:

```text
Yes
```

Explain that direct access to ports 8080, 8081 and 8082 will stop when this option is enabled.

### 5.7 Dashboard system widgets

Prompt:

```text
Enable Homepage CPU, memory and disk widgets?
```

Default:

```text
Yes
```

### 5.8 Docker discovery

Prompt:

```text
Allow Homepage to discover Docker containers automatically?
```

Default:

```text
No
```

Do not mount `/var/run/docker.sock` unless explicitly selected.

Display a security warning before enabling Docker socket access.

### 5.9 Enable Codex CLI

Prompt:

```text
Install OpenAI Codex CLI?
```

Options:

```text
Yes
No
```

Default for new AI development containers:

```text
Yes
```

Default for existing managed containers:

```text
Preserve current state
```

### 5.10 Codex execution user

Prompt:

```text
Linux user that will run Codex CLI
```

Default:

```text
dev
```

The selected user must exist, have a writable home directory and own the development workspace. Codex must not be configured to run routinely as `root`.

### 5.11 Codex authentication mode

Provide:

```text
ChatGPT account — included plan usage, no API key
OpenAI API key — separately billed, advanced option
Not authenticated yet
```

Default:

```text
ChatGPT account — included plan usage, no API key
```

For the default mode, generate managed Codex configuration with:

```toml
forced_login_method = "chatgpt"
```

The installer must not request, store or export an OpenAI API key unless the user explicitly chooses the separately billed advanced mode. Clearly explain that ChatGPT-plan usage is limited by the active plan and that optional extra credits may be offered after included usage is consumed.

### 5.12 Headless authentication

Prompt after successful installation:

```text
Start Codex device-code login now?
```

Defaults:

```text
Interactive installation: Yes
Unattended installation: No
```

Run the login as the selected development user:

```bash
sudo -u dev -H codex login --device-auth
```

Never ask the user to paste a ChatGPT password, browser cookie, OAuth token or `auth.json` contents into the installer. If device-code login is unavailable, leave Codex installed but unauthenticated and print the supported manual login commands. Authentication failure must not fail the rest of LXC provisioning.

### 5.13 Credential storage

Prompt:

```text
Codex credential storage
```

Provide:

```text
Automatic — use system keyring when available
System keyring only
Protected file fallback
```

Default:

```text
Automatic — use system keyring when available
```

Install the headless keyring support packages:

```text
gnome-keyring
libsecret-1-0
dbus-user-session
```

Generate one of the following in the selected user's `~/.codex/config.toml`:

```toml
cli_auth_credentials_store = "auto"
```

or, when explicitly selected:

```toml
cli_auth_credentials_store = "keyring"
```

When file storage is used, enforce `0700` on `~/.codex` and `0600` on `~/.codex/auth.json`. The authentication cache must never be included in helper backups, release archives, diagnostic bundles or Git commits.

---

## 6. Caddy installation

Install Caddy natively through its official Debian package repository.

Do not deploy Caddy inside Docker.

Required packages:

```text
caddy
ca-certificates
curl
gnupg
debian-keyring
debian-archive-keyring
apt-transport-https
```

Required service:

```text
caddy.service
```

Generated configuration path:

```text
/etc/caddy/Caddyfile
```

Create a backup before overwriting an existing configuration:

```text
/etc/caddy/backups/Caddyfile-YYYYMMDD-HHMMSS
```

Validate before restart:

```bash
caddy validate --config /etc/caddy/Caddyfile
```

Format generated configuration:

```bash
caddy fmt --overwrite /etc/caddy/Caddyfile
```

Restart only after successful validation:

```bash
systemctl restart caddy
```

---

## 7. Generated Caddy configuration

Generate routes only for enabled services.

Example HTTP configuration:

```caddyfile
ai-dev.home.arpa {
    reverse_proxy 127.0.0.1:3000
}

code.ai-dev.home.arpa {
    reverse_proxy 127.0.0.1:8080
}

files.ai-dev.home.arpa {
    reverse_proxy 127.0.0.1:8081
}

termix.ai-dev.home.arpa {
    reverse_proxy 127.0.0.1:8082
}
```

For HTTP-only private LAN mode, explicitly disable automatic HTTPS where required:

```caddyfile
{
    auto_https off
}
```

For internal HTTPS mode:

```caddyfile
ai-dev.home.arpa {
    tls internal
    reverse_proxy 127.0.0.1:3000
}
```

Apply the same mode consistently to all configured services.

Caddy must support WebSocket traffic required by code-server and Termix without additional manual configuration.

---

## 8. Homepage deployment

Deploy Homepage through Docker Compose.

Use a pinned image version rather than `latest`.

Example:

```yaml
services:
  homepage:
    image: ghcr.io/gethomepage/homepage:<validated-version>
    container_name: homepage
    restart: unless-stopped
    ports:
      - "127.0.0.1:3000:3000"
    volumes:
      - /opt/homepage/config:/app/config
      - /etc/localtime:/etc/localtime:ro
    environment:
      HOMEPAGE_ALLOWED_HOSTS: ai-dev.home.arpa
```

Runtime paths:

```text
Compose file:  /opt/homepage/compose.yaml
Configuration: /opt/homepage/config/
Backup path:   /var/backups/homepage/
```

Set restrictive permissions on configuration files containing API keys or credentials.

Do not place service passwords directly in `services.yaml`.

---

## 9. Homepage configuration

### 9.1 Dashboard title

```text
AI Development Environment
```

### 9.2 Service groups

Generate service entries according to enabled components.

Example:

```yaml
- Development:
    - VS Code Web:
        icon: vscode.png
        href: http://code.ai-dev.home.arpa
        description: Browser development environment
        ping: http://127.0.0.1:8080/healthz

    - GitHub:
        icon: github.png
        href: https://github.com
        description: Repositories, pull requests and Actions

- Files:
    - FileBrowser Quantum:
        icon: filebrowser.png
        href: http://files.ai-dev.home.arpa
        description: Workspace file manager
        ping: http://127.0.0.1:8081/health

- Terminals:
    - Termix:
        icon: terminal.png
        href: http://termix.ai-dev.home.arpa
        description: SSH terminal and host manager

- Infrastructure:
    - Proxmox:
        icon: proxmox.png
        href: https://PROXMOX_HOST:8006
        description: Proxmox management
```

Ask for the Proxmox management URL during advanced installation, or leave it disabled when not supplied.

### 9.3 System widgets

Configure:

```yaml
- resources:
    cpu: true
    memory: true
    disk: /
```

Also display:

- LXC hostname
- Container IP
- Current date and time
- Disk usage for `/srv/workspace`

Do not enable external weather, search or tracking widgets by default.

---

## 10. Local DNS guidance

The installer cannot assume control over the user’s router or DNS server.

After installation, display the required records:

```text
192.168.31.233 ai-dev.home.arpa
192.168.31.233 code.ai-dev.home.arpa
192.168.31.233 files.ai-dev.home.arpa
192.168.31.233 termix.ai-dev.home.arpa
```

Also show the preferred wildcard record:

```text
*.ai-dev.home.arpa → 192.168.31.233
```

Provide instructions for:

- Router local DNS
- AdGuard Home DNS rewrite
- Pi-hole local DNS
- Windows hosts file
- Linux `/etc/hosts`

Create a generated file inside the LXC:

```text
/root/ai-dev-dns-records.txt
```

Create a management command:

```bash
gateway-dns-records
```

It should print all required DNS records using the current LXC IP and configured domain.

---

## 11. Existing-service binding changes

When the user enables backend restriction:

### code-server

Change:

```yaml
bind-addr: 0.0.0.0:8080
```

to:

```yaml
bind-addr: 127.0.0.1:8080
```

Preserve its authentication configuration.

### FileBrowser Quantum

Bind to:

```text
127.0.0.1:8081
```

Preserve existing database, users and passwords.

### Termix

Change Docker port mapping from:

```yaml
- "8082:8080"
```

to:

```yaml
- "127.0.0.1:8082:8080"
```

Preserve the `termix-data` volume.

### Homepage

Always bind to:

```text
127.0.0.1:3000
```

Restart services only after validating their updated configurations.

If Caddy validation or startup fails, automatically restore previous service bindings.

---

## 12. Migration and repair behavior

Update/repair must support:

- Existing containers without Caddy or Homepage
- Existing Caddy installations
- Existing Homepage installations
- Containers using direct LAN ports
- Containers using SSH-tunnel-only code-server
- Containers with only some optional web services installed

The repair process must:

1. Detect installed services.
2. Load existing managed state.
3. Ask whether to enable or disable Homepage.
4. Ask whether to enable or disable Caddy.
5. Preserve existing user data.
6. Back up configuration before modifying it.
7. Validate all generated configuration.
8. Roll back failed changes.
9. Re-run HTTP and network verification.

Do not remove Caddy, Homepage or related user data merely because the component is deselected during a repair run.

Instead, ask separately:

```text
Disable service
Uninstall service and keep data
Uninstall service and remove data
```

The destructive option must require explicit confirmation.

---

## 13. Management commands

Add the following commands inside the LXC.

### Gateway status

```bash
gateway-status
```

Display:

- Caddy service status
- Ports 80 and 443
- Caddy configuration validity
- Dashboard hostname
- Domain suffix
- LXC IP
- Each configured route
- Backend service state
- HTTP response from each public route
- DNS resolution result

Support:

```bash
gateway-status --check
```

Return nonzero if any required check fails.

### Gateway restart

```bash
sudo gateway-restart
```

Validate Caddy configuration before restarting.

### Gateway configuration

```bash
sudo gateway-config
```

Open the generated configuration in the configured terminal editor.

### Gateway logs

```bash
gateway-logs
```

Show recent Caddy and Homepage logs.

### Homepage status

```bash
homepage-status
```

Verify:

- Docker container state
- Port 3000 listener
- Local HTTP response
- Configuration directory
- Current image version

### Homepage update

```bash
sudo homepage-update
```

Required sequence:

1. Back up Homepage configuration.
2. Pull the configured image.
3. Recreate the container.
4. Verify the local HTTP endpoint.
5. Verify the Caddy public route.
6. Restore the previous image when verification fails.

### Homepage backup

```bash
sudo homepage-backup
```

Create:

```text
/var/backups/homepage/homepage-YYYYMMDD-HHMMSS.tar.zst
```

Include:

```text
/opt/homepage/compose.yaml
/opt/homepage/config/
```

### Codex status

```bash
codex-status
```

Display:

- Installed Codex CLI version
- Executable path
- Configured Linux user
- Authentication method from `codex login status`
- Credential-store mode without displaying secrets
- Codex home directory permissions
- Git availability
- Development workspace path and write access

Support:

```bash
codex-status --check
```

Return nonzero when the binary, configuration, permissions or required development tools are invalid. An unauthenticated state may be reported as a warning immediately after unattended installation.

### Codex login

```bash
codex-login
```

Run as the configured development user and start:

```bash
codex login --device-auth
```

After login, run:

```bash
codex login status
```

The command must refuse to run as `root` unless it immediately drops privileges to the configured development user.

### Codex update

```bash
sudo codex-update
```

Required sequence:

1. Record the current Codex version and executable path.
2. Run the current official Linux installer as the configured development user.
3. Verify `codex --version`.
4. Verify `codex login status` without printing credentials.
5. Preserve `~/.codex/config.toml`, authentication state and repository data.
6. Report the previous and new versions.

An update failure must leave the previous working executable available when technically possible.

### Codex logout

```bash
codex-logout
```

Run `codex logout` as the configured development user and verify that the cached session is cleared. Do not delete repositories or `AGENTS.md` files.

---

## 14. Post-install verification

Provisioning must not report success until all selected checks pass.

### Caddy checks

```bash
systemctl is-active caddy
caddy validate --config /etc/caddy/Caddyfile
ss -lntp | grep ':80'
```

For HTTPS mode:

```bash
ss -lntp | grep ':443'
```

### Homepage checks

```bash
docker compose -f /opt/homepage/compose.yaml ps
curl -fsS http://127.0.0.1:3000
```

### Codex CLI checks

```bash
sudo -u dev -H codex --version
sudo -u dev -H codex login status
command -v git
test -w /srv/workspace
```

For unattended installations, an unauthenticated `codex login status` result is a warning rather than a provisioning failure. Binary installation, executable ownership, managed configuration syntax and workspace write access remain mandatory checks.

### Reverse-proxy checks

Use explicit host headers so validation works even before DNS is configured:

```bash
curl -fsS \
  -H 'Host: ai-dev.home.arpa' \
  http://127.0.0.1/
```

Verify each enabled route:

```bash
curl -fsS -H 'Host: code.ai-dev.home.arpa' http://127.0.0.1/
curl -fsS -H 'Host: files.ai-dev.home.arpa' http://127.0.0.1/
curl -fsS -H 'Host: termix.ai-dev.home.arpa' http://127.0.0.1/
```

### Proxmox-host check

From the Proxmox node:

```bash
curl -fsS \
  -H 'Host: ai-dev.home.arpa' \
  http://LXC_IP/
```

Repeat for every configured hostname.

Distinguish these failure types:

```text
Backend service failure
Caddy configuration failure
Caddy service failure
LXC firewall failure
Proxmox firewall failure
DNS not configured
Client DNS cache problem
```

DNS failure should be reported as a warning when host-header tests pass.

---

## 15. Post-install summary

Display:

```text
AI Development Web Gateway

Dashboard:
  http://ai-dev.home.arpa

Services:
  VS Code Web:
    http://code.ai-dev.home.arpa

  File Manager:
    http://files.ai-dev.home.arpa

  Termix:
    http://termix.ai-dev.home.arpa

Required DNS:
  *.ai-dev.home.arpa → 192.168.31.233

Gateway status:
  gateway-status

DNS records:
  gateway-dns-records

Homepage status:
  homepage-status

Caddy logs:
  gateway-logs

Codex CLI:
  codex

Codex login:
  codex-login

Codex status:
  codex-status

Codex update:
  sudo codex-update
```

When DNS is not yet configured, also display the temporary IP-and-port addresses.

---

## 16. Security requirements

- Homepage must not be exposed directly on port 3000.
- Do not expose the Docker socket by default.
- Preserve authentication on code-server, FileBrowser and Termix.
- Caddy must run using its packaged unprivileged service account.
- Homepage configuration containing secrets must use restrictive permissions.
- Do not store GitHub, Proxmox or service credentials in the repository.
- Do not automatically expose ports 80 or 443 through the internet router.
- Warn that Homepage does not provide its own authentication.
- Recommend VPN or an authenticated Caddy layer for access outside the trusted LAN.
- Do not disable application authentication merely because Caddy is installed.
- Default Codex authentication must use ChatGPT sign-in, not an API key.
- API-key authentication must be clearly marked as separately billed and remain disabled unless explicitly selected.
- Run Codex as the non-root development user.
- Treat `~/.codex/auth.json` as a secret; never print, archive, upload or commit it.
- Prefer `cli_auth_credentials_store = "auto"` or `"keyring"` where a functioning credential store is available.
- Do not expose Codex CLI as a public web shell or unauthenticated network service.
- Recommend MFA on the ChatGPT account used for Codex.

---

## 17. Rollback requirements

Before modifying:

```text
/etc/caddy/Caddyfile
/home/dev/.config/code-server/config.yaml
FileBrowser configuration
/opt/termix/compose.yaml
/opt/homepage/
```

create timestamped backups.

On failure:

1. Restore previous application bindings.
2. Restore the previous Caddyfile.
3. Restore the previous Homepage Compose configuration.
4. Restart affected services.
5. Verify their original direct-port access.
6. Leave diagnostic logs intact.
7. Report the exact failed stage.

Provisioning must never leave code-server, FileBrowser or Termix inaccessible because a new Caddy configuration failed.

---

## 18. State-file additions

Persist:

```text
ENABLE_CADDY
ENABLE_HOMEPAGE
GATEWAY_DOMAIN
DASHBOARD_HOSTNAME
CODE_HOSTNAME
FILES_HOSTNAME
TERMIX_HOSTNAME
GATEWAY_HTTPS_MODE
RESTRICT_BACKEND_PORTS
HOMEPAGE_PORT
HOMEPAGE_IMAGE
HOMEPAGE_DOCKER_DISCOVERY
PROXMOX_WEB_URL
ENABLE_CODEX_CLI
CODEX_LINUX_USER
CODEX_AUTH_MODE
CODEX_CREDENTIAL_STORE
CODEX_HOME
CODEX_INSTALL_METHOD
CODEX_INSTALLED_VERSION
CODEX_WORKSPACE_ROOT
```

Migration defaults for older state files:

```text
ENABLE_CADDY=false
ENABLE_HOMEPAGE=false
GATEWAY_DOMAIN=home.arpa
DASHBOARD_HOSTNAME=ai-dev
CODE_HOSTNAME=code
FILES_HOSTNAME=files
TERMIX_HOSTNAME=termix
GATEWAY_HTTPS_MODE=http
RESTRICT_BACKEND_PORTS=false
HOMEPAGE_PORT=3000
HOMEPAGE_DOCKER_DISCOVERY=false
ENABLE_CODEX_CLI=false
CODEX_LINUX_USER=dev
CODEX_AUTH_MODE=chatgpt
CODEX_CREDENTIAL_STORE=auto
CODEX_HOME=/home/dev/.codex
CODEX_INSTALL_METHOD=official-standalone
CODEX_WORKSPACE_ROOT=/srv/workspace
```

---

## 19. Tests

Add automated tests for:

### Shell syntax

```bash
bash -n helpers/ai-dev-lxc/install.sh
bash -n helpers/ai-dev-lxc/lib/caddy.sh
bash -n helpers/ai-dev-lxc/lib/homepage.sh
bash -n helpers/ai-dev-lxc/lib/codex.sh
```

### Caddy configuration

```bash
caddy validate --adapter caddyfile --config generated-Caddyfile
```

Test combinations:

- Homepage only
- Caddy plus Homepage
- code-server only
- code-server plus FileBrowser
- all services enabled
- HTTP mode
- Internal HTTPS mode
- Custom domain suffix
- Custom hostname values

### Homepage YAML

Parse:

```text
services.yaml
settings.yaml
widgets.yaml
docker.yaml
compose.yaml
```

Reject invalid YAML and duplicate service names.

### Codex CLI installation and configuration

Test:

- Installation through the official standalone Linux installer
- Re-running installation is idempotent
- `codex --version` succeeds as the configured user
- ChatGPT authentication is enforced by default
- API-key mode is not enabled without explicit selection
- `codex login --device-auth` is invoked as the configured non-root user
- Unattended install leaves a clear manual-login instruction
- `codex login status` output is parsed without exposing secrets
- `cli_auth_credentials_store` accepts only `auto`, `keyring` or `file`
- `~/.codex` permissions are restrictive
- `auth.json` is excluded from backups and packages
- `codex-status --check` detects a missing binary or unsafe permissions
- `codex-update` preserves configuration and authentication state

Use mocks for authentication flows in automated tests; never use a real ChatGPT account, OAuth token or API key in CI.

### State migration

Test migration from:

```text
v2.2.3
v2.2.4
v2.2.5
v2.2.6
```

### Binding changes

Verify that enabling backend restriction changes only the intended bind addresses.

### Rollback

Inject simulated failures for:

- Invalid Caddyfile
- Caddy start failure
- Homepage container failure
- Unreachable backend
- Proxied route failure

Confirm original service access is restored.

### Release packaging

Verify that all Homepage, Caddy and Codex CLI templates, files and tests are included in:

```text
ai-dev-lxc-bundle-v2.2.7.zip
ai-dev-lxc-bundle-v2.2.7.tar.gz
```

---

## 20. Documentation updates

Update:

```text
README.md
CHANGELOG.md
HELPERS.md
ARCHITECTURE.md
helpers/ai-dev-lxc/README.md
docs/adding-a-helper.md
docs/helper-schema.md
```

Document:

- Caddy and Homepage architecture
- Required DNS records
- HTTP versus internal HTTPS
- Backend-port restriction
- Dashboard configuration
- Update and backup commands
- Troubleshooting
- Rollback behavior
- Existing-container migration
- Security implications
- How to add another service tile and Caddy route
- Codex CLI installation and upgrades
- ChatGPT account versus API-key authentication
- Headless device-code login
- Included ChatGPT-plan usage versus optional extra credits
- Credential storage and recovery
- Safe use of Codex permissions, Git checkpoints and `AGENTS.md`

Include examples for:

```text
Router DNS
AdGuard Home
Pi-hole
Windows hosts file
Linux hosts file
```

---

## 21. Acceptance criteria

The task is complete only when:

1. The TUI can independently enable or disable Caddy and Homepage.
2. Homepage opens as the default start page through Caddy.
3. Each enabled service has a friendly hostname.
4. Homepage contains tiles for every enabled service.
5. Generated dashboard configuration excludes disabled services.
6. Caddy configuration passes validation before activation.
7. code-server and Termix work correctly through the reverse proxy.
8. WebSocket terminal sessions remain functional.
9. Existing service credentials and data are preserved.
10. Backend ports can be restricted to localhost.
11. Internal and Proxmox-host HTTP checks pass.
12. DNS requirements are clearly displayed.
13. Existing v2.2.6 containers can be repaired without recreation.
14. Failed gateway installation automatically restores previous access.
15. Homepage configuration is backed up before updates.
16. The complete helper bundle contains all templates and supporting files.
17. Repository validation and release packaging pass.
18. The release version is updated consistently to v2.2.7.
19. Codex CLI is installed for the selected non-root development user.
20. A ChatGPT Plus user can authenticate with `codex login --device-auth` without configuring an API key.
21. ChatGPT authentication is the default and API-key billing cannot be enabled accidentally.
22. The installer explains that included Codex usage is plan-limited and that additional credits are optional.
23. Codex credentials are stored through the configured keyring mode or protected file fallback.
24. `codex-status`, `codex-login`, `codex-update` and `codex-logout` work as documented.
25. Codex authentication files are absent from release packages, backups and diagnostics.
26. The helper remains successful when Codex is installed but login is intentionally deferred.

---

## 22. Recommended implementation phases

### Phase 1 — Configuration and TUI

- Add state variables.
- Add TUI prompts.
- Add migration logic.
- Add validation for hostnames, domains and ports.
- Add Codex enablement, user, authentication-mode and credential-store prompts.
- Ensure repair mode preserves an existing Codex installation and login state.

### Phase 2 — Codex CLI

- Install required keyring and terminal packages.
- Install Codex through the official standalone Linux installer.
- Generate managed Codex configuration for ChatGPT sign-in.
- Add headless device-code login guidance.
- Add status, login, logout and update commands.
- Verify non-root repository access and credential permissions.

### Phase 3 — Homepage

- Add Docker Compose deployment.
- Add generated YAML configuration.
- Add service tiles and system widgets.
- Add status, backup and update commands.
- Validate local access.

### Phase 4 — Caddy

- Add official repository installation.
- Generate routes dynamically.
- Validate and activate Caddy.
- Add gateway management commands.

### Phase 5 — Backend integration

- Restrict selected services to localhost.
- Verify code-server WebSockets.
- Verify Termix terminals.
- Verify FileBrowser operation.
- Add rollback support.

### Phase 6 — Network verification

- Verify routes from inside the LXC.
- Verify routes from the Proxmox host.
- Generate DNS instructions.
- Improve firewall and DNS diagnostics.

### Phase 7 — Documentation and release

- Update project documentation.
- Add tests.
- Build helper and repository packages.
- Validate extracted archives.
- Generate SHA-256 checksums.
- Publish v2.2.7 artifacts.

---

## 23. Implementation-order constraint

Use this implementation order:

1. Codex CLI binary installation and local non-root verification. Authentication may be completed interactively or deferred.
2. Homepage deployment and local verification.
3. Caddy installation and proxy-route verification.
4. Backend binding restriction only after all proxy routes pass.
5. Rollback simulation before release packaging.

Codex installation or authentication must not modify web-service bindings and must not block rollback of Caddy, Homepage, code-server, FileBrowser Quantum or Termix.

This ordering minimizes the risk of making code-server, FileBrowser Quantum, or Termix inaccessible during migration.

---

## 24. Codex CLI implementation requirements

### 24.1 Installation source

Install Codex CLI through the current official standalone Linux installer:

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

Run installation in the context of the configured development user unless the official installer explicitly supports a safe system-wide destination. Do not use an unofficial wrapper, browser-cookie scraper or reverse-engineered ChatGPT endpoint.

Record:

```text
Installed executable path
Installed Codex version
Installation timestamp
Installation method
Configured Linux user
```

The installer must be idempotent. A repair run must detect an existing working Codex installation and preserve it unless the user explicitly requests an update or removal.

### 24.2 ChatGPT Plus authentication

The default supported workflow is:

```bash
codex login --device-auth
```

Run it as:

```bash
sudo -u dev -H codex login --device-auth
```

Requirements:

- Use **Sign in with ChatGPT** for subscription access.
- Do not require an OpenAI Platform account or API billing configuration.
- Do not describe the included allowance as unlimited.
- State that usage limits vary by ChatGPT plan and task complexity.
- State that optional additional credits may be purchased after included usage is consumed.
- Do not purchase credits, enable auto-reload or change account billing settings automatically.
- Verify the active authentication method with `codex login status`.
- If the result indicates API-key authentication while `CODEX_AUTH_MODE=chatgpt`, report an error and instruct the user to run `codex logout` followed by `codex-login`.

### 24.3 API-key advanced mode

API-key authentication is outside the default Plus-subscription workflow because it is billed separately through the OpenAI API account.

Only expose it behind an advanced, explicit choice:

```text
I understand API-key use is billed separately from ChatGPT Plus
```

Never write the key into:

```text
manifest.env
helper state files
shell history
systemd unit files
Homepage configuration
diagnostic logs
release artifacts
```

Prefer environment injection or an external secret store. Do not enable this mode in unattended installation unless the user supplied an explicit secure configuration mechanism.

### 24.4 Managed configuration

Create the selected user's configuration directory:

```text
/home/dev/.codex/
```

Recommended default configuration:

```toml
forced_login_method = "chatgpt"
cli_auth_credentials_store = "auto"
```

Do not overwrite unrelated user settings during repair. Merge only helper-managed keys, create a timestamped backup first and validate the resulting TOML before activation.

Provide an example repository instruction file:

```text
helpers/ai-dev-lxc/files/codex/AGENTS.md.example
```

Recommended contents:

```markdown
# Repository instructions

- Inspect the existing implementation before replacing code.
- Preserve backward compatibility unless the task explicitly changes it.
- Create a Git checkpoint before substantial edits.
- Run the documented build, lint and test commands after changes.
- Do not remove tests merely to obtain a passing build.
- Review `git diff` and report every modified file.
- Do not commit generated artifacts, credentials or local environment files.
```

Do not automatically copy this file into every repository. Provide a management command or documented copy operation so each repository can opt in.

### 24.5 Workspace integration

Default workspace root:

```text
/srv/workspace
```

Verify that the configured development user can:

```bash
cd /srv/workspace
touch .codex-write-test
rm .codex-write-test
git --version
codex --version
```

Do not recursively change ownership of an existing workspace without explicit confirmation. Report ownership or ACL conflicts and provide a targeted correction command.

### 24.6 Removal and repair

During repair, provide:

```text
Keep Codex CLI unchanged
Update Codex CLI
Disable helper integration but keep Codex and credentials
Uninstall Codex CLI and keep user configuration
Uninstall Codex CLI and remove user configuration
```

Removing `~/.codex` is destructive and requires explicit confirmation. Before removal, warn that it may contain login credentials, local session history and user configuration. Do not back up authentication credentials automatically.

### 24.7 Post-install summary

Display:

```text
OpenAI Codex CLI

Run from a repository:
  cd /srv/workspace/PROJECT
  codex

Authenticate with ChatGPT Plus:
  codex-login

Check installation:
  codex-status

Update CLI:
  sudo codex-update

Important:
  ChatGPT sign-in uses the allowance included with the active ChatGPT plan.
  Usage limits apply. An OpenAI API key is not required for this mode.
```

