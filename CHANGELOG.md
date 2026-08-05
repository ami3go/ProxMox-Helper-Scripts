# Changelog

## v2.2.7 — 2026-08-04

### Added

- Native Caddy reverse proxy with generated HTTP or internal-CA HTTPS routes.
- Homepage v1.13.2 deployment on loopback through Docker Compose.
- ChatGPT-authenticated Codex CLI installation for a non-root development user.
- Headless `codex-login`, status, update, and logout management commands.
- Gateway status, restart, config, logs, and DNS-record commands.
- Homepage status, backup, verified update, and image rollback commands.
- State migration from v2.2.3 through v2.2.6.
- Conditional dashboard tiles and Caddy routes for installed services only.
- Backups and automatic rollback for code-server, FileBrowser Quantum, and Termix binding changes.
- Proxmox-host route verification using explicit Host headers.
- Shell, state, YAML, Caddy, binding, rollback, and packaging tests.

### Security

- Homepage binds only to `127.0.0.1:3000`.
- Docker discovery is disabled by default.
- Codex defaults to ChatGPT authentication and never persists API keys in helper state.
- Codex credential files are excluded from archives and logs.
