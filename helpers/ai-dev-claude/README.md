# ai-dev-claude

A Proxmox VE wizard that creates a new LXC sized for Claude Code development
and provisions it end to end: a web IDE, web file manager, web terminal,
dashboard, GitHub CLI, and Claude Code. See [`PLAN.md`](PLAN.md) for the full
design and rationale.

Three entrypoints are available:

| | `ai-dev-claude.sh` | `ai-dev-claude-no-docker.sh` | `no_docker_proxy_ai-dev-claude.sh` |
|---|---|---|---|
| Docker | Yes | No | No |
| Web terminal | Termix | ttyd | ttyd behind SSO |
| Dashboard | Homepage | Static HTML | Static HTML behind SSO |
| Reverse proxy | No | No | Caddy |
| Web authentication | Per service | Per service | Authelia SSO |
| Backend exposure | LAN ports | LAN ports | localhost only |
| LXC features needed | `nesting=1,keyctl=1` | none | none |

The proxy variant is an overlay on the regular no-Docker helper. It first runs
`ai-dev-claude-no-docker.sh`, including its container-storage selector and all
provisioning/recovery logic, then converts the web services to localhost-only
backends behind Caddy + Authelia. Keeping it as an overlay avoids maintaining a
second copy of the base provisioning code.

## Run it

Docker variant:

```bash
sudo ./ai-dev-claude.sh
```

Docker-free variant:

```bash
sudo ./ai-dev-claude-no-docker.sh
```

Docker-free proxy/SSO variant:

```bash
sudo ./no_docker_proxy_ai-dev-claude.sh --domain dev.example.net
```

Interactive creation asks which active Proxmox `rootdir` storage should hold
the new LXC root disk, then confirms defaults or lets you customize hostname,
dev username, CPU/RAM/swap/disk, and service ports. Re-provisioning an existing
CT keeps its current storage.

Fully automatic base variants:

```bash
sudo ./ai-dev-claude.sh --yes
sudo ./ai-dev-claude-no-docker.sh --yes
```

The proxy/SSO variant needs a DNS domain on its first unattended run:

```bash
sudo ./no_docker_proxy_ai-dev-claude.sh --ctid 121 --domain dev.example.net --yes
```

For an existing proxy CT, its domain and SSO secrets are persisted under
`/etc/ai-dev-claude/no_docker_proxy_<CTID>.env`, so a later re-run can reuse the
same identity/session configuration.

## What you get

### `ai-dev-claude.sh`

| Service | Default port | Notes |
|---|---:|---|
| Dashboard (Homepage) | 3000 | Links to every service below, by IP |
| Web IDE (code-server) | 8080 | Password auth |
| File manager (FileBrowser Quantum) | 8081 | `admin` / generated password, root at `/srv/workspace` |
| Termix (web SSH terminal) | 8082 | Complete its first-run admin setup on first visit |

Plus GitHub CLI (`gh`) and Claude Code (`claude`).

### `ai-dev-claude-no-docker.sh`

Same sizing and defaults, no Docker and no `nesting=1,keyctl=1` LXC features.

| Service | Default port | Notes |
|---|---:|---|
| Dashboard (static page) | 3000 | Links to every service below, by IP |
| Web IDE (code-server) | 8080 | Password auth |
| File manager (FileBrowser Quantum) | 8081 | `admin` / generated password, root at `/srv/workspace` |
| Web terminal (ttyd) | 8082 | HTTP Basic Auth plus Linux login |

Same GitHub CLI/Claude Code and `claude-dev-status`/`claude-dev-menu`/
`claude-omniroute-connect`/`claude-omniroute-disconnect` commands, plus
`sudo dashboard-refresh`.

### `no_docker_proxy_ai-dev-claude.sh`

This variant keeps the same Docker-free application stack but adds **Caddy +
Authelia** and changes browser services to a single-sign-on model.

Given:

```text
dev.example.net
```

it creates these browser endpoints:

| URL | Service |
|---|---|
| `https://auth.dev.example.net` | Authelia login portal |
| `https://home.dev.example.net` | Dashboard |
| `https://code.dev.example.net` | code-server |
| `https://files.dev.example.net` | FileBrowser Quantum |
| `https://term.dev.example.net` | ttyd terminal |

After signing in to Authelia once, clicking dashboard links reuses the same SSO
session. The normal browser workflow therefore has no separate code-server,
FileBrowser, or ttyd password prompts.

The proxy variant deliberately changes the backend exposure model:

- code-server binds to `127.0.0.1` and uses `auth: none` because Caddy/Authelia
  is its authentication boundary.
- FileBrowser Quantum binds to `127.0.0.1`, uses proxy authentication, and
  trusts the `Remote-User` identity inserted by Caddy only after Authelia
  authorizes the request.
- ttyd binds to `127.0.0.1`, requires the authenticated `Remote-User` header,
  and runs as the development user, opening the shell directly after SSO.
- the dashboard binds to `127.0.0.1`.
- Authelia binds to `127.0.0.1:9091`.
- Caddy is the only LAN-facing HTTP(S) service.

The helper uses Caddy's internal CA. At completion it copies the CA root
certificate from the guest to the Proxmox host as:

```text
/etc/ai-dev-claude/caddy-local-root-<CTID>.crt
```

Trust that certificate once on each client device. Also configure local DNS
(or client hosts files) so `auth`, `home`, `code`, `files`, and `term` under the
selected domain resolve to the LXC IP.

The SSO helper requires a normal multi-label DNS domain. Special-use suffixes
such as `.local`, `.localhost`, `.home.arpa`, `.test`, `.invalid`, and
`.example` are rejected because they are not suitable as the shared SSO cookie
domain for this deployment.

The generated SSO password and cryptographic secrets are root-only and persist
on the Proxmox host in:

```text
/etc/ai-dev-claude/no_docker_proxy_<CTID>.env
```

The guest also retains a root-only recovery copy of the SSO username/password
at `/root/ai-dev-proxy-credentials`.

## Common helper commands inside the LXC

| Command | Purpose |
|---|---|
| `claude-dev-status` | One-shot status for services and GitHub/Claude configuration |
| `claude-dev-menu` | GitHub login, Claude login, OmniRoute connect/disconnect, dashboard refresh |
| `sudo dashboard-refresh` | Regenerate the static dashboard |
| `sudo claude-omniroute-connect` | Point Claude Code at an OmniRoute endpoint |
| `sudo claude-omniroute-disconnect` | Remove the OmniRoute override |

Container sizing defaults to 4 cores / 8192 MiB RAM / 2048 MiB swap / 40 GiB
disk with DHCP networking.

## What happens, in order

For the base helpers:

1. Select storage for a new LXC, then create it (or reuse `--ctid`).
2. Provision packages/user/SSH, code-server, FileBrowser Quantum, web terminal,
   dashboard, GitHub CLI, Claude Code, and helper commands.
3. Reboot the container.
4. Re-confirm the IP and verify services.
5. Print URLs and credentials/manual follow-up steps.

For `no_docker_proxy_ai-dev-claude.sh`, the normal no-Docker sequence runs
first, then the overlay:

1. Install Caddy and Authelia directly from their APT repositories.
2. Create the Authelia file user/database/session configuration.
3. Convert all browser backends to localhost-only/SOO-aware operation.
4. Regenerate the dashboard with HTTPS service names.
5. Configure Caddy `forward_auth` for Authelia and `tls internal` endpoints.
6. Verify all services, backend isolation, and the authentication portal.
7. Export the Caddy local root CA, reboot the LXC, and verify the full stack
   returns successfully.

## Still manual after the script finishes

These steps require a human:

- **GitHub CLI login.** Run `claude-dev-menu` and use the GitHub login option.
- **Claude Code login.** Run `claude` once as the development user or use the
  corresponding menu option.
- **OmniRoute connection** is optional and available from `claude-dev-menu`.
- **Proxy variant DNS.** Point all five generated service hostnames at the LXC
  IP using your LAN DNS server or client hosts files.
- **Proxy variant CA trust.** Import the generated Caddy root certificate on
  each browser/client device once.

## Troubleshooting

- **A provisioning stage fails:** the container is left intact for diagnosis.
  Full logs are under `/var/log/ai-dev-claude/` on the Proxmox host. Fix the
  cause and re-run with `--ctid <ID>`.
- **Disk exhaustion / interrupted dpkg:** the no-Docker base helper grows an
  existing undersized rootfs to the requested size, enforces a free-space
  preflight, cleans package caches, and repairs interrupted dpkg state before
  continuing.
- **Docker problems:** use `ai-dev-claude-no-docker.sh` or the proxy/SSO variant;
  neither requires Docker or nested-container features.
- **Proxy site does not resolve:** verify local DNS/hosts records point the
  generated service names at the current LXC IP.
- **Browser reports an untrusted certificate:** import the exported
  `caddy-local-root-<CTID>.crt` into the client device's trusted root store.
- **A backend port is directly reachable from the LAN in the proxy variant:**
  treat that as a configuration failure. The overlay's verification stage is
  designed to reject `0.0.0.0`/`[::]` listeners for the protected backends.
