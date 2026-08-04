# AI Development LXC

Creates an unprivileged Debian LXC on a Proxmox VE node and provisions a headless AI-assisted development workstation.

## Included

- code-server browser IDE
- Python virtual environments
- Robot Framework and RobotCode
- Git and GitHub CLI
- Claude Code, Codex CLI, Gemini CLI, GitHub Copilot CLI, Aider, and OpenCode selection
- direct password-protected LAN access by default, with optional SSH-tunnel mode
- post-install service, socket, `/healthz`, and Proxmox-host reachability verification
- GNOME Keyring, Secret Service/libsecret, Python keyring, `pass`, and curses PIN entry
- `web-ide-status`, `keyring-status`, and `keyring-session` diagnostic helpers
- update, repair, adoption, and standalone web-verification workflows

## Run from the repository

```bash
./bin/proxmox-helper-scripts run ai-dev-lxc
```

Direct execution remains supported:

```bash
./helpers/ai-dev-lxc/install.sh
```

A standalone copy is included in tagged release assets as `ai-dev-lxc.sh` and retained under the legacy name `proxmox-ai-dev-lxc.sh`.

When extracted from a helper bundle, run:

```bash
cd ai-dev-lxc
chmod +x install.sh
./install.sh
```

## Helper package directories

This helper is self-contained under `helpers/ai-dev-lxc/`. Future helper-specific configuration templates, payloads, shell modules, screenshots, and tests should be added to its `templates/`, `files/`, `lib/`, `assets/`, and `tests/` directories rather than to repository-global folders.

Tagged releases include both the standalone installer and complete ZIP/TAR.GZ bundles of this folder.

## Claude Code installation

On Debian, the helper installs Claude Code from Anthropic's signed `stable` APT repository and verifies signing-key fingerprint `31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`. Detailed installation output is stored in `/var/log/ai-agent-claude-install.log`. On x86-64, the helper checks that the Proxmox host exposes the AVX CPU flag before installation.


## Web IDE verification

Provisioning does not report success until code-server passes all checks appropriate to the selected access mode:

1. `code-server@<user>` is active under systemd.
2. The configured TCP port is listening on the expected address.
3. `http://127.0.0.1:<port>/healthz` returns a valid code-server health response.
4. In LAN mode, the Proxmox host can reach `http://<lxc-ip>:<port>/healthz`.

Inside the LXC, run:

```bash
web-ide-status
```

From the helper TUI, select **Verify Web IDE service and HTTP access** to repeat the complete check. A LAN failure records service status, journal output, listeners, routing, container configuration, and Proxmox firewall status in the helper log.

## Credential and keyring support

The helper installs `gnome-keyring`, `libsecret-tools`, `dbus-user-session`, `libpam-gnome-keyring`, `python3-keyring`, `pinentry-curses`, `pass`, and `keyutils`. This does not install a desktop environment.

Useful commands:

```bash
keyring-status
keyring-session
```

`keyring-session` opens a shell with a private D-Bus session and GNOME Keyring daemon. It is useful for terminal applications that expect the Secret Service API. SSH public-key logins cannot automatically unlock a password-protected login keyring because no login password is supplied; use `keyring-session`, `pass`, or agent forwarding according to the application's credential model.
