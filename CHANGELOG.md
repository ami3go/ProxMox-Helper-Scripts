# Changelog

## 2.3.0 — 2026-08-03

### Added

- Add an interactive `post-install.sh` for Debian LXCs created manually in the Proxmox UI.
- Add central launcher command `post-install ID` and manifest field `HELPER_POST_INSTALL`.
- Add direct DHCP/LAN SSH and password-protected code-server configuration without an SSH tunnel.
- Add an in-container `ai-dev-first-login` menu for GitHub and Claude authentication.
- Add verbose host and LXC post-install logs with explicit step names, timings, and failure context.
- Publish standalone post-install release assets in addition to complete helper bundles.

### Changed

- Make DHCP and direct LAN code-server access the default for the AI Development LXC helper.
- Disable the helper-managed `net0` firewall flag for trusted internal-network access.
- Set new, repaired, and adopted containers to Proxmox `cmode=shell`.

### Fixed

- Fix blank or unusable Proxmox web-console sessions on minimal Debian LXCs by opening a direct root shell instead of relying on an in-container TTY login service.

## 2.2.2 — 2026-08-03

### Added

- Stream every installation and repair stage to both the Proxmox console and the host run log.
- Stream the complete in-container provisioning output simultaneously to the console and `/var/log/claude-dev-provision.log`.
- Add numbered LXC step headers, timestamps, elapsed-time summaries, and explicit current-step failure diagnostics.
- Add visible host stages for template refresh/download, LXC creation/start/readiness, provisioning payload transfer, software provisioning, and deletion protection.
- Preserve secret safety by avoiding global `set -x`; passwords, SSH keys, and API-key values are not echoed as commands.

## 2.2.1 — 2026-08-02

### Fixed

- Install Claude Code on Debian through Anthropic's signed stable APT repository instead of the opaque per-user native installer.
- Verify Anthropic's release-signing key fingerprint before trusting the repository.
- Detect missing AVX support on x86-64 and report the actual Proxmox CPU limitation.
- Preserve the operational code-server/Python environment when an optional AI-agent installation fails.
- Write detailed per-agent logs under `/var/log/ai-agent-<agent>-install.log`.
- Allow Update/repair to complete and report partial agent failures clearly.

All notable changes are documented here.

## 2.2.0 - 2026-08-02

### Changed

- Flattened helper storage to `helpers/<helper-id>/` so every helper has one stable package folder.
- Kept category as manifest metadata instead of a filesystem directory.
- Moved AI Development LXC to `helpers/ai-dev-lxc/`.
- Updated registry discovery, validation, catalogs, launcher tests, Pages, and compatibility paths for the new layout.

### Added

- Standard per-helper `assets/`, `files/`, `lib/`, `templates/`, and `tests/` directories.
- Complete ZIP and TAR.GZ bundle export for every helper, preserving all additional files.
- Shared `export-helpers.sh` and `build-site.sh` scripts for release and Pages generation.
- Validation that each helper contains the standard package directories.
- Scaffolding documentation for resolving helper-local files relative to `install.sh`.

## 2.1.0 - 2026-08-02

### Added

- Generic manifest-driven Proxmox helper repository architecture
- Category and helper directory convention under `helpers/`
- Central `bin/proxmox-helper-scripts` TUI and CLI launcher
- Shared `common.sh`, `tui.sh`, and `registry.sh` libraries
- New-helper scaffold and reusable templates
- Static manifest validation without executing metadata
- Generated Markdown and JSON helper catalogs
- Framework tests for registry discovery, launcher behavior, and scaffolding
- Generic repository release archives plus per-helper standalone assets
- Architecture, helper schema, and helper contribution documentation

### Changed

- Moved the AI Development LXC source to `helpers/development/ai-dev-lxc/`
- Retained `proxmox-ai-dev-lxc.sh` as a compatibility launcher
- Generalized README, Pages, CI, packaging, and publishing for multiple helpers
- Updated AI Development LXC helper version to 2.1.0

## 2.0.0 - 2026-08-02

- Added selectable Claude Code, Codex CLI, Gemini CLI, GitHub Copilot CLI, Aider, and OpenCode installation.
- Added agent status, authentication, update, and provider environment helpers.
- Added GitHub Pages, CI, release packaging, and publishing support.
