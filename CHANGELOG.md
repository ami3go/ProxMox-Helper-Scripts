# Changelog

## 2.2.2 — 2026-08-04

### Added

- Verify that the code-server systemd service is active after provisioning.
- Verify that the configured TCP port listens on the expected LAN or loopback address.
- Verify code-server through its unauthenticated `/healthz` endpoint.
- In LAN mode, verify HTTP reachability from the Proxmox host to the LXC address and port.
- Add a dedicated TUI action to verify an existing managed container's Web IDE.
- Add `web-ide-status` with service, listener, health, URL, journal, and exit-status diagnostics.
- Install GNOME Keyring, libsecret tools, D-Bus user sessions, PAM keyring integration, Python keyring, `pass`, `pinentry-curses`, and `keyutils`.
- Add `keyring-status` and `keyring-session` for headless credential-store diagnostics and sessions.

### Changed

- Make direct password-protected LAN access the default for new deployments; SSH-tunnel mode remains selectable.
- Treat an inaccessible Web IDE as an incomplete deployment instead of displaying a successful completion message.
- Include network, route, listener, systemd, journal, and Proxmox firewall evidence when LAN verification fails.

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
