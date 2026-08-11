# Helper catalog

| Helper | Version | Entry point | Purpose |
|---|---:|---|---|
| AI Development LXC | 2.2.7 | `helpers/ai-dev-lxc/install.sh` | Create and provision a new headless AI development LXC (agents, code-server, FileBrowser, Termix). See `extend-existing-lxc.sh` in the same helper to add Codex CLI, Caddy, and Homepage to an LXC it already created |
| AI Dev OmniRoute TUI | 0.1.2 | `helpers/ai-dev-omniroute-tui/install.sh` | Creates a new LXC on a Proxmox host (or installs into an existing container/VM with `--guest`) and sets up a terminal UI to install/manage OmniRoute, Codex CLI, Claude Code, OpenCode, and GitHub CLI, plus a project launcher and diagnostics |
