# AI Development LXC

Creates a new unprivileged Debian LXC on Proxmox VE or post-configures an LXC that was created manually.

## Included

- Direct DHCP/LAN access for SSH and code-server
- Password-protected code-server browser IDE
- Python virtual environments
- Robot Framework and RobotCode
- Git and GitHub CLI
- Claude Code from Anthropic's signed stable APT repository
- Optional Codex CLI, Gemini CLI, GitHub Copilot CLI, Aider, and OpenCode in the full installer
- Proxmox web-console repair using `cmode=shell`
- Verbose console output and persistent host/LXC logs
- Idempotent update and repair workflows

## Create and provision a new LXC

From the repository launcher:

```bash
./bin/proxmox-helper-scripts run ai-dev-lxc
```

Or run the installer directly:

```bash
./helpers/ai-dev-lxc/install.sh
```

The new-container installer uses DHCP, listens on the LXC LAN address, and configures the Proxmox console to open a direct root shell.

## Post-configure an existing LXC

Create a Debian LXC using the Proxmox web interface, then run:

```bash
./bin/proxmox-helper-scripts post-install ai-dev-lxc
```

Direct execution is also supported:

```bash
cd helpers/ai-dev-lxc
chmod +x post-install.sh
./post-install.sh
```

The post-install TUI lets you select an existing CTID and configure:

- Primary `net0` for DHCP
- Direct LAN SSH access
- Development user and SSH authentication
- code-server port and password
- Python and Robot Framework environment
- GitHub CLI and optional Git identity
- Claude Code installation
- Proxmox web-console shell mode

It preserves existing files under `/srv/workspace` and is safe to rerun for repair.

## Proxmox web-console fix

The helper runs:

```bash
pct set CTID --cmode shell
```

Proxmox documents `cmode=shell` as opening a shell directly inside the container without relying on a login prompt on a TTY. This fixes minimal Debian containers where the default Proxmox Console action opens a blank or unusable terminal.

## Direct LAN access

The helper assumes the internal network is trusted. It does not require an SSH tunnel.

After installation, use the DHCP address shown in the completion dialog:

```bash
ssh dev@LXC_IP
```

Open code-server at:

```text
http://LXC_IP:8080
```

The configured port can be changed in the TUI. code-server still uses password authentication, but the connection is plain HTTP. Do not forward the port directly to the public internet.

## First-login setup

After connecting through SSH or the code-server terminal, run:

```bash
ai-dev-first-login
```

The interactive menu can:

- Authenticate GitHub CLI
- Start Claude Code's browser login
- Run `claude doctor`
- Show environment and service status
- Open the Robot Framework example project

## Logs

### Full installer

Host log:

```text
/var/log/claude-dev-lxc/run-YYYYMMDD-HHMMSS.log
```

LXC provisioning log:

```text
/var/log/claude-dev-provision.log
```

AI-agent installation logs:

```text
/var/log/ai-agent-<agent>-install.log
```

### Post-install utility

Host log:

```text
/var/log/ai-dev-lxc-post-install/run-YYYYMMDD-HHMMSS.log
```

LXC provisioning log:

```text
/var/log/ai-dev-post-install.log
```

Every major action and command output is streamed to both the current console and the appropriate log file. Global `set -x` tracing is not used because it could reveal passwords, SSH keys, or provider tokens.

## Claude Code installation

On Debian, both workflows install Claude Code from Anthropic's signed `stable` APT repository and verify the signing-key fingerprint:

```text
31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE
```

On x86-64, the scripts verify that AVX is exposed to the LXC before installing Claude Code.

Authentication is completed later as the normal development user:

```bash
claude
```

## Helper package layout

All helper-specific files are contained under `helpers/ai-dev-lxc/`:

```text
helpers/ai-dev-lxc/
├── manifest.env
├── install.sh
├── post-install.sh
├── README.md
├── assets/
├── files/
├── lib/
├── templates/
└── tests/
```

Tagged releases include the complete helper bundle, the standalone new-container installer, and the standalone post-install utility.
