# ai-dev-claude

A Proxmox VE wizard that creates a new LXC sized for Claude Code
development and provisions it end to end: a web IDE, a web file manager, a
web terminal, a link dashboard, GitHub CLI, and Claude Code. See
[`PLAN.md`](PLAN.md) for the full design and rationale.

Two scripts, same everything else — pick one:

| | `ai-dev-claude.sh` | `ai-dev-claude-no-docker.sh` |
|---|---|---|
| Web terminal | Termix (Docker) | ttyd (static binary, systemd) |
| Dashboard | Homepage (Docker) | Static HTML + `python3 -m http.server` |
| LXC features needed | `nesting=1,keyctl=1` | none |

Everything else (code-server, FileBrowser Quantum, GitHub CLI, Claude Code,
the reboot+finalize flow, the OmniRoute-connect menu) is identical. The
Docker-free variant exists because Docker-in-nested-LXC has been a real
source of pain — see the "Docker-free variant" section of `PLAN.md`.

## Run it

```bash
sudo ./ai-dev-claude.sh
```

Interactive by default: for every new container, first asks which active
Proxmox `rootdir` storage should hold the LXC root disk, then confirms defaults
or lets you customize hostname, dev username, CPU/RAM/swap/disk, and every
service port before creating anything. Re-provisioning an existing CT keeps
its current storage. Every install step streams its real output live to the terminal
(and to a log under `/var/log/ai-dev-claude/`) — nothing is hidden behind a
progress bar.

Fully automatic, no prompts:

```bash
sudo ./ai-dev-claude.sh --yes
```

Re-provision (or create) a specific container ID instead of auto-allocating
one:

```bash
sudo ./ai-dev-claude.sh --ctid 121
```

Every flag, and the no-Docker variant, works the same way:

```bash
sudo ./ai-dev-claude-no-docker.sh
sudo ./ai-dev-claude-no-docker.sh --yes
sudo ./ai-dev-claude-no-docker.sh --ctid 121
```

## What you get

### `ai-dev-claude.sh`

| Service | Default port | Notes |
|---|---:|---|
| Dashboard (Homepage) | 3000 | Links to every service below, by IP |
| Web IDE (code-server) | 8080 | Password auth |
| File manager (FileBrowser Quantum) | 8081 | `admin` / generated password, root at `/srv/workspace` |
| Termix (web SSH terminal) | 8082 | Complete its first-run admin setup on first visit |

Plus GitHub CLI (`gh`) and Claude Code (`claude`), and these commands
installed inside the container:

| Command | Purpose |
|---|---|
| `claude-dev-status` | One-shot status: every service's state and URL |
| `claude-dev-menu` | Interactive menu: GitHub login, Claude login, OmniRoute connect/disconnect, dashboard refresh |
| `sudo homepage-refresh` | Regenerate the dashboard's links for the container's current IP |
| `sudo claude-omniroute-connect` | Point Claude Code at an OmniRoute endpoint |
| `sudo claude-omniroute-disconnect` | Undo the above |

Container sizing defaults to 4 cores / 8192 MiB RAM / 2048 MiB swap / 40 GiB
disk, DHCP networking — the same proportions already validated by this
repo's `ai-dev-lxc` helper for the same code-server + FileBrowser + Termix
combination, plus headroom for Homepage.

### `ai-dev-claude-no-docker.sh`

Same sizing and defaults, no Docker anywhere and no `nesting=1,keyctl=1`
LXC features needed.

| Service | Default port | Notes |
|---|---:|---|
| Dashboard (static page) | 3000 | Links to every service below, by IP |
| Web IDE (code-server) | 8080 | Password auth |
| File manager (FileBrowser Quantum) | 8081 | `admin` / generated password, root at `/srv/workspace` |
| Web terminal (ttyd) | 8082 | HTTP Basic Auth to load the page, then a real Linux login prompt inside it — two credentials, both printed at the end |

Same GitHub CLI/Claude Code and `claude-dev-status`/`claude-dev-menu`/
`claude-omniroute-connect`/`claude-omniroute-disconnect` commands, plus
`sudo dashboard-refresh` in place of `homepage-refresh`.

## What happens, in order

1. Create the LXC (or reuse `--ctid` if it already exists).
2. Provision everything inside it, streaming live, in 8 verbose stages:
   base packages/user/SSH, code-server, FileBrowser Quantum, the web
   terminal (Termix+Docker, or ttyd), the dashboard (Homepage+Docker, or
   static HTML), GitHub CLI, Claude Code, helper commands.
3. Reboot the container so every service starts fresh rather than relying
   on first-boot ordering.
4. Finalize: re-confirm the container's real IPv4 address, rewrite the
   dashboard's links with it, and re-verify all four services are up.
5. Print a summary with every URL, the dev-user SSH password, and what's
   still manual (see below).

## Still manual after the script finishes

These steps need a human in the loop and can't be scripted unattended —
run `claude-dev-menu` inside the container (`pct enter <CTID>`, then
`su - <dev user>`) for all of them:

- **GitHub CLI login.** `gh auth login --web` opens a device code you
  approve in a browser. Menu option 2 runs this plus `gh auth setup-git`
  for you.
- **Claude Code login.** Run `claude` once as the dev user and follow its
  browser or API-key sign-in prompt. Menu option 3.
- **Connecting Claude Code to OmniRoute** (optional). Requires an
  OmniRoute instance already running and reachable from this container —
  see `helpers/ai-dev-omniroute-tui` in this repo if you don't have one
  yet. Menu option 4 asks for the base URL and API key and writes them into
  `~/.claude/settings.json`'s `env` block (merged with `jq`, not
  overwritten). Option 5 removes them again.
- **DNS/hostnames.** Out of scope by design — the dashboard and every
  service link by the container's IP address directly. If you want a name
  instead, point your router's local DNS or a hosts-file entry at the
  printed IP (see `helpers/ai-dev-lxc/extend-existing-lxc.sh` in this repo
  if you want the fuller Caddy + `home.arpa`-hostname gateway instead).
- **If the container's IP changes later** (e.g. a new DHCP lease), run
  `sudo homepage-refresh` (`sudo dashboard-refresh` on the no-Docker
  variant) to update the dashboard's links — the finalize pass already does
  this once after the initial reboot, but nothing re-runs it automatically
  after that.

## Troubleshooting

- **A stage fails during provisioning:** the container is left intact (not
  deleted) so you can inspect it. The failing command's real output is
  already visible in the stream you just watched; the full log is also
  saved on the Proxmox host under `/var/log/ai-dev-claude/`. Fix the
  underlying issue, then re-run the same script with `--ctid <ID>` to
  re-provision in place — every install step is safe to re-run.
- **Docker doesn't come up for Termix/Homepage** (`ai-dev-claude.sh` only):
  Debian 13's `docker.io` package only *Recommends* `docker-cli` rather
  than depending on it, so the script explicitly installs `docker-cli`
  alongside it — a daemon with no CLI on PATH was the most common cause of
  this failure. It also retries, installs `docker-cli` if still missing,
  and falls back to the `vfs` storage driver (the fix for
  Docker-in-nested-LXC environments) before giving up. If it still fails,
  the printed diagnostics include `systemctl status docker.service`, the
  resolved `docker` CLI path, and the relevant journal entries for this
  run. If Docker keeps being troublesome, use
  `ai-dev-claude-no-docker.sh` instead — it doesn't need Docker at all.
- **ttyd's web terminal won't let you type anything** (`no-docker` only):
  make sure you're using the printed HTTP Basic Auth credentials
  (`$DEV_USER` / the ttyd password) to load the page at all — without them
  the browser will just show a login prompt from the server, not the
  terminal. Once loaded, the terminal itself asks for the Linux
  username/password (the dev-user SSH password) via `login`.
