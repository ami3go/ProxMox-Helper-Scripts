# AI Dev OmniRoute TUI

A terminal UI for a headless Debian/Ubuntu/Proxmox-LXC software-development environment.

## Included workflows

- OmniRoute install/update and health checks
- OmniRoute user-level systemd service
- Codex CLI install/update and OmniRoute integration
- Claude Code install/update and OmniRoute integration
- OpenCode install/update and OmniRoute integration
- GitHub CLI install/update
- `gh auth login`, `gh auth status`, `gh auth setup-git`
- Clone repositories, inspect PRs, list GitHub Actions runs, create repositories
- Git, Python 3, isolated Robot Framework virtual environment
- Node.js 24 installer
- Project selector and one-screen coding-agent launcher
- Diagnostics and persistent log

## Install

### From a Proxmox VE host (creates a new LXC)

```bash
sudo ./install.sh
```

With no `--guest` flag, on a host with `pct` and `/etc/pve` present, `install.sh`
creates a new unprivileged Debian LXC (auto-allocated CTID, DHCP networking,
2 cores / 2048 MB RAM / 512 MB swap / 8 GB disk), adds a non-root `dev` user
with passwordless sudo, pushes this helper into the container, and installs
the TUI there for that user — printing console/SSH access instructions when
done.

```bash
sudo ./install.sh --ctid 121        # use/create a specific CTID
sudo ./install.sh --user alice      # different in-container username
sudo ./install.sh --yes             # skip the confirmation prompt
```

### Inside an existing container or VM

```bash
chmod +x install.sh
./install.sh --guest
ai-dev-tui
```

`--guest` is implied automatically when `pct`/`/etc/pve` aren't present, so
running `./install.sh` directly inside a container or VM works the same way.

You can also run the TUI directly without installing it system-wide:

```bash
./ai-dev-tui
```

## Recommended first-run sequence

1. **Install / update tools → Install/update everything**
2. Start OmniRoute once and complete its web onboarding/provider setup.
3. **OmniRoute service / diagnostics → Install/refresh user service**
4. **Configure OmniRoute integrations → Dry-run all three**
5. **Configure OmniRoute integrations → Configure all three**
6. **GitHub CLI → Login to github.com**
7. **GitHub CLI → Configure Git credential helper**
8. **Launch coding agent in a project**

## Runtime architecture

```text
Project repository
      |
      +-- Codex CLI ---------+
      +-- Claude Code -------+----> OmniRoute ----> cloud/local model providers
      +-- OpenCode ----------+
      |
      +-- Git / GitHub CLI -------> GitHub repositories, PRs, Actions
```

## Security choices

- OmniRoute is treated as local-only by default. The TUI does not automatically bind its dashboard/API to the LAN.
- GitHub authentication is delegated to the official `gh auth login` flow.
- The optional OmniRoute API-key helper stores the key in
  `~/.config/ai-dev-tui/secrets.env` with mode `0600`.
  You may skip this and export `OMNIROUTE_API_KEY` yourself instead.
- The TUI never stores a GitHub token itself.
- **OmniRoute health/API test → Open health/API test** passes the API key
  directly to `curl` as an argument rather than interpolating it into a
  shell command string, so a key value can't be crafted to inject shell
  commands.
- User-level OmniRoute service configuration is written under
  `~/.config/systemd/user/omniroute.service`.
- "Enable linger" is optional because it causes the user service to remain active after logout.

## Error handling

Individual install/setup steps (Node.js 24, the Robot Framework virtual
environment, the OmniRoute user service) report failures on-screen and
return you to the menu instead of exiting the whole TUI. If the OmniRoute
user service fails to install — most commonly because no systemd user
session exists in this container — use **OmniRoute service / diagnostics →
Run OmniRoute in foreground** instead.

## GitHub CLI notes

After login:

```bash
gh auth login --hostname github.com --git-protocol https
gh auth setup-git
gh auth status
```

`gh auth setup-git` configures Git to use GitHub CLI as a credential helper.

## OmniRoute integration commands used by the TUI

```bash
omniroute setup-codex
omniroute setup-claude
omniroute setup-opencode

omniroute launch-codex
omniroute launch
```

The TUI also supports `--dry-run` configuration before writing tool config.

## Paths

```text
~/.local/bin/ai-dev-tui
~/.config/ai-dev-tui/config.env
~/.config/ai-dev-tui/secrets.env
~/.local/state/ai-dev-tui/ai-dev-tui.log
~/.config/systemd/user/omniroute.service
~/projects
```

## Compatibility

Designed for:

- Debian/Ubuntu-based headless containers/VMs
- Proxmox LXC with systemd enabled
- SSH, Proxmox console, code-server terminal, web terminal, tmux

If systemd user services are unavailable in the container, use
**OmniRoute service / diagnostics → Run OmniRoute in foreground**, or use a
separate supervisor/container deployment.

## Version

Initial TUI package: `0.1.0`.
