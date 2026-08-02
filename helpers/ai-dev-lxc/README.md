# AI Development LXC

Creates an unprivileged Debian LXC on a Proxmox VE node and provisions a headless AI-assisted development workstation.

## Included

- code-server browser IDE
- Python virtual environments
- Robot Framework and RobotCode
- Git and GitHub CLI
- Claude Code, Codex CLI, Gemini CLI, GitHub Copilot CLI, Aider, and OpenCode selection
- SSH tunnel or password-protected LAN access
- update and repair workflow

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
