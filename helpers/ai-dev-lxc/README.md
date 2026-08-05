# AI Development LXC helper v2.2.7

This helper extends the v2.2.6 AI Development LXC service layout with:

- **OpenAI Codex CLI** installed for the non-root development user.
- **Homepage v1.13.2** as a Docker-based start page bound only to `127.0.0.1:3000`.
- **Caddy** as the native systemd reverse proxy for Homepage, code-server, FileBrowser Quantum, and Termix.
- Friendly `home.arpa` hostnames, DNS instructions, management commands, validation, backups, and automatic binding rollback.

The helper preserves existing project files, application authentication, FileBrowser data, and the Termix `termix-data` volume.

## Run from the Proxmox host

```bash
sudo ./helpers/ai-dev-lxc/install.sh
```

Or select the container without the menu:

```bash
sudo ./helpers/ai-dev-lxc/install.sh --ctid 123
```

The target must already be an AI Development LXC created by the v2.2.x base helper. The script starts the LXC when necessary, detects existing services, transfers its modular payload, runs provisioning inside the guest, updates the existing managed state, and validates the routes from the Proxmox node.

## Run inside the LXC

```bash
sudo ./install.sh --guest
```

For unattended repair using `/etc/ai-development-gateway.env`:

```bash
sudo ./install.sh --guest --non-interactive
```

## Default URLs

```text
http://ai-dev.home.arpa
http://code.ai-dev.home.arpa
http://files.ai-dev.home.arpa
http://termix.ai-dev.home.arpa
```

The dashboard defaults to `ai-dev.home.arpa`. Each service prefix is editable. The generated DNS records are available with:

```bash
gateway-dns-records
```

> The preferred wildcard record `*.ai-dev.home.arpa` covers the default service names. The dashboard itself still needs the explicit `ai-dev.home.arpa` record.

## Management commands

| Command | Purpose |
|---|---|
| `gateway-status --check` | Validate Caddy, backends, proxy routes, and DNS resolution |
| `sudo gateway-restart` | Format, validate, and restart Caddy |
| `sudo gateway-config` | Edit `/etc/caddy/Caddyfile` |
| `gateway-logs` | Show recent Caddy and Homepage logs |
| `gateway-dns-records` | Print records for the current LXC IP |
| `homepage-status` | Check container, listener, HTTP endpoint, and image |
| `sudo homepage-backup` | Create a timestamped `.tar.zst` backup |
| `sudo homepage-update` | Pull, recreate, verify, and roll back on failure |
| `codex-status --check` | Check binary, configuration, login type, and permissions |
| `codex-login` | Start headless ChatGPT device-code login |
| `codex-logout` | Remove the active Codex credentials |
| `sudo codex-update` | Re-run the official installer without archiving credentials |

## Codex authentication

The default is ChatGPT account authentication:

```bash
codex-login
```

This runs `codex login --device-auth` as the configured development user. No OpenAI API key is required. API-key mode is an explicit advanced option and is separately billed. The helper never stores an API key in its state.

`~/.codex/auth.json` is treated as a password-equivalent secret. It is excluded from helper backups, diagnostics, tests, and release packages. Credential storage defaults to `auto`, allowing an available OS keyring and otherwise using the protected file cache.

## Local DNS examples

### Router local DNS

Create one A/host record per line printed by `gateway-dns-records`, all pointing to the LXC IPv4 address.

### AdGuard Home

Open **Filters → DNS rewrites**, create the dashboard and service records, then flush the client DNS cache.

### Pi-hole

Open **Local DNS → DNS Records** and add each hostname with the LXC IPv4 address.

### Windows hosts file

Edit as Administrator:

```text
C:\Windows\System32\drivers\etc\hosts
```

Example:

```text
192.168.31.233 ai-dev.home.arpa code.ai-dev.home.arpa files.ai-dev.home.arpa termix.ai-dev.home.arpa
```

Then run:

```powershell
ipconfig /flushdns
```

### Linux hosts file

Add the same line to `/etc/hosts`, then restart the local resolver or browser if it caches DNS.

## HTTP and internal HTTPS

- **HTTP mode** is intended for a trusted private LAN and disables Caddy automatic HTTPS explicitly.
- **Internal HTTPS mode** adds `tls internal` to every generated site. Client devices must trust Caddy's local root certificate.

Caddy is installed natively from the official Debian repository and runs under the packaged `caddy.service` account. Homepage remains inside Docker.

Homepage’s built-in resource widget reports the Homepage container CPU/memory context. The helper mounts `/srv/workspace` read-only so its disk usage is visible; use a separate host metrics provider such as Glances when full LXC host metrics are required.

## Backend restriction and rollback

When enabled, restriction occurs only after all proxy routes pass:

1. Back up code-server, FileBrowser, and Termix configuration.
2. Change code-server to `127.0.0.1:8080`.
3. Set FileBrowser Quantum `http.listen` (v2) or `server.listen` (v1) to `127.0.0.1`.
4. Change the Termix publish rule to `127.0.0.1:8082:8080`.
5. Restart and recheck every backend and public route.
6. Probe the code-server and Termix routes with HTTP Upgrade headers.
7. Restore the original files automatically if any stage fails.

Caddy and Homepage also back up their own configurations before replacement or update.

## Adding another service

1. Add state fields for the enable flag, hostname, and backend port.
2. Add a conditional tile in `homepage_render_services()`.
3. Add a conditional `caddy_site_block` in `caddy_render_config()`.
4. Extend `gateway-status`, DNS record generation, and host verification.
5. Add HTTP/HTTPS and disabled-service cases to the tests.

## Security

- Homepage is bound to loopback and is not an authentication layer.
- Docker socket discovery is off by default and requires an explicit warning/selection.
- Existing authentication remains enabled for code-server, FileBrowser, and Termix.
- The helper does not configure router port forwarding or public internet exposure.
- Use a VPN or authenticated edge proxy before remote access.
- Enable MFA on the ChatGPT account used for Codex.
