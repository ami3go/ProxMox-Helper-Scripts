# Proxmox Helper Scripts v2.2.7

This release contains the AI Development LXC v2.2.7 helper: an interactive Proxmox VE wizard that creates and provisions a headless LXC for AI-assisted development. It is packaged as a modular helper and as standalone launcher scripts.

## Entry points

```bash
sudo ./ai-dev-lxc.sh
sudo ./ai-dev-lxc-v2.2.7.sh
sudo ./proxmox-ai-dev-lxc.sh
```

All launchers execute `helpers/ai-dev-lxc/install.sh`, which creates and provisions a new LXC. To extend or repair an LXC it already created — adding Codex CLI, Homepage, and Caddy — run `helpers/ai-dev-lxc/extend-existing-lxc.sh` directly.

## Validation

```bash
./scripts/validate.sh
```

## Build release archives

```bash
./scripts/package-release.sh
```

See [`helpers/ai-dev-lxc/README.md`](helpers/ai-dev-lxc/README.md) for deployment, DNS, migration, security, and management-command details.

## AI Dev OmniRoute TUI

A terminal UI to install and manage OmniRoute, Codex CLI, Claude Code, OpenCode, and the GitHub CLI, plus a project launcher and diagnostics. Run from a Proxmox host to create a new LXC and install into it, or run `--guest` inside a container/VM you already have:

```bash
sudo ./helpers/ai-dev-omniroute-tui/install.sh          # creates a new LXC on a Proxmox host
./helpers/ai-dev-omniroute-tui/install.sh --guest        # installs locally inside an existing container/VM
ai-dev-tui
```

See [`helpers/ai-dev-omniroute-tui/README.md`](helpers/ai-dev-omniroute-tui/README.md) for the full workflow, security choices, and compatibility notes.

## AI Dev Claude

Creates and provisions a new LXC sized for Claude Code development: a web IDE (code-server), a web file manager (FileBrowser Quantum), Termix, a Homepage dashboard linking all three, GitHub CLI, and Claude Code. Verbose, step-by-step by default; `--yes` for a fully unattended run.

```bash
sudo ./helpers/ai-dev-claude/ai-dev-claude.sh
sudo ./helpers/ai-dev-claude/ai-dev-claude.sh --yes
```

See [`helpers/ai-dev-claude/README.md`](helpers/ai-dev-claude/README.md) for what gets installed and what's still manual, and [`helpers/ai-dev-claude/PLAN.md`](helpers/ai-dev-claude/PLAN.md) for the design.
