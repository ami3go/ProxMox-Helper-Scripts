# ai-dev-claude — implementation plan

## Goal

A single Proxmox-host script, `ai-dev-claude.sh`, that:

1. Creates a new LXC sized appropriately for Claude Code + a browser dev stack.
2. Installs, inside that container: code-server (web IDE), FileBrowser Quantum
   (web file manager), Termix (web SSH terminal), a Homepage dashboard that
   links to all of the above, GitHub CLI, and Claude Code.
3. Runs fully interactively step-by-step by default, with a `--yes` flag for
   unattended/automatic installation.
4. Reboots the container once everything is installed, then runs a second,
   in-guest finalize/setup pass that rewrites the dashboard with the
   container's real post-reboot IP and re-verifies every service.
5. Offers an option to point Claude Code at an OmniRoute endpoint instead of
   Anthropic directly.

## Why adapt `helpers/ai-dev-lxc/install.sh` instead of starting from zero

That script already implements, and this repo's own history has already
shot-tested, most of what's needed: Proxmox host detection, CTID allocation
(`pvesh get /cluster/nextid`), template/storage/bridge auto-detection,
`pct create`, a whiptail TUI framework (`msg_info`/`ask_yes_no`/`input_box`/
`menu_box`/`show_error_details`/staged `log`), code-server install +
systemd unit + health verification, FileBrowser Quantum install + config +
verification, Termix via Docker Compose + verification, and a Claude Code
apt-repo installer with AVX/arch checks and GPG fingerprint verification.

`ai-dev-claude.sh` reuses those exact, working code blocks rather than
re-deriving them, and drops what it doesn't need (multi-agent selection,
Robot Framework/RobotCode, GNOME keyring/pass, code-server extensions,
static-IP/VLAN advanced networking, adopt/console/log-viewer menu items).
It adds what the existing wizard doesn't have: a dashboard, a fully
unattended mode, a post-reboot finalize pass, and OmniRoute wiring.

## Container spec

Same defaults as the proven `ai-dev-lxc` wizard, since they were sized for
the same software combination (code-server + FileBrowser + Termix) minus
Robot Framework, plus one more small Docker container (Homepage, ~150 MB):

| Setting | Default |
|---|---|
| Cores | 4 |
| Memory | 8192 MiB |
| Swap | 2048 MiB |
| Disk | 40 GiB |
| Network | DHCP on the first detected `vmbr*` bridge |
| Template | latest available `debian-13-standard` (falls back to `debian-12`) |
| Type | unprivileged, `nesting=1,keyctl=1` (Termix and Homepage need Docker) |

Advanced/interactive mode lets you change hostname, dev username, cores,
memory, swap, disk, and ports before creating the container. `--yes` skips
all prompts and uses the table above plus auto-generated passwords.

## In-container install stages (verbose, staged, matching the existing `stage N "..."` log pattern)

1. Base packages + dev user + SSH (adapted from the wizard's stage 18/25).
2. code-server — install script, `bind-addr 0.0.0.0:$PORT`, password auth,
   systemd unit, `/healthz` verification (reused near-verbatim).
3. FileBrowser Quantum — GitHub-release binary, v1/v2 schema config,
   config preflight validation, systemd unit, HTTP verification (reused
   near-verbatim).
4. Termix — Docker + Docker Compose, nested-LXC `vfs` storage-driver
   fallback, compose file, container verification (reused near-verbatim).
5. Homepage dashboard — new. Docker Compose, bound directly to
   `0.0.0.0:3000` (no Caddy/hostnames), `services.yaml` generated with
   direct `http://<container-ip>:<port>` links to code-server, FileBrowser,
   and Termix. Written once with a best-effort IP, then rewritten by the
   finalize pass after reboot once the IP is certain.
6. GitHub CLI — `apt-get install gh` (already proven available on the
   Debian 13 template used here), plus an in-container `claude-dev-menu`
   command with a "GitHub login" action (`gh auth login --web` +
   `gh auth setup-git`), mirroring the wizard's `ai-agent-menu` pattern.
7. Claude Code — the wizard's `install_claude_code()` apt-repo installer,
   unmodified (AVX check, GPG fingerprint pin, `claude-code` apt package).
8. `claude-dev-menu` / `claude-dev-status` commands installed system-wide,
   scoped to just this stack (GitHub login, Claude login reminder, OmniRoute
   connect, service status) — a trimmed version of the wizard's
   `ai-agent-menu`/`ai-agent-status`.

## Non-interactive mode

`--yes` (alias `--non-interactive`): skip every `ask_yes_no`/confirmation
whiptail dialog, use the defaults table above, auto-generate passwords, and
proceed straight through creation → provisioning → reboot → finalize with
only progress output (still fully verbose to the log and screen — "no
confirmation" is not "no output").

## Reboot + finalize

After the initial provisioning stage completes:

1. `pct reboot $CTID` (clean restart so every systemd unit, Docker daemon,
   and Docker container comes up fresh rather than relying on first-boot
   ordering).
2. Wait for `pct exec $CTID -- true` to succeed again.
3. Run a finalize pass via `pct exec`: re-detect the container's IPv4
   address (`hostname -I`), regenerate Homepage's `services.yaml` with that
   IP baked into each link, restart the Homepage container, then re-run the
   same verification checks used during provisioning (code-server, File
   Browser, Termix, Homepage) so failures are caught post-reboot too, not
   just once at first install.
4. Print (and show in a whiptail summary) the final dashboard URL and all
   individual service URLs using the confirmed IP.

## Connecting Claude Code to OmniRoute

A menu action, `claude-dev-menu` → "Connect Claude Code to OmniRoute" (run
any time after login; not prompted inline during provisioning, since that
would need an interactive round-trip into the guest for something that may
not be reachable yet), that:

1. Prompts for the OmniRoute base URL (e.g. `http://192.168.1.50:20128`)
   and an API key (blank allowed if the OmniRoute instance doesn't require
   one).
2. Writes `~/.claude/settings.json`'s `env` block with `ANTHROPIC_BASE_URL`
   and `ANTHROPIC_AUTH_TOKEN`, preserving any other existing settings in
   that file (parsed/merged with `jq`, not overwritten wholesale).
3. Is reversible via a "Disconnect from OmniRoute" action that removes just
   those two keys.

This does not install OmniRoute itself inside this container — OmniRoute is
`helpers/ai-dev-omniroute-tui`'s job, run separately (on this container or
elsewhere). This is purely the client-side wiring.

## Files

```
helpers/ai-dev-claude/
├── PLAN.md          this file
├── README.md        usage + manual-follow-up guide
└── ai-dev-claude.sh the script (entrypoint; run as root on a Proxmox host)
```

No `manifest.env` — following the precedent already set by
`helpers/ai-dev-omniroute-tui` (also manifest-less; `scripts/validate.sh`
does not require one, only `HELPERS.md`/root `README.md` need a pointer).

## Manual follow-up (documented in README, also printed at the end of the script)

- **GitHub CLI**: device/browser login isn't automatable; run
  `claude-dev-menu` → GitHub login (or `gh auth login --web` directly)
  inside the container.
- **Claude Code**: first run requires interactive browser or API-key login;
  run `claude` as the dev user and follow its prompt.
- **OmniRoute**: connecting requires an already-running OmniRoute instance
  reachable from this container; the menu action only configures the
  client side.
- **DNS/hostnames**: intentionally out of scope — this dashboard links by
  IP, matching what was asked for. Point a router/hosts-file entry at the
  printed IP yourself if you want a name instead.

## Review pass (after implementation)

`bash -n`, shellcheck if available, and a manual re-read for: quoting bugs
(the exact class of bug already found and fixed once in `ai-dev-lxc`'s
`pct exec ... bash -lc '...'` diagnostic calls), port conflicts between the
four services, idempotency of the finalize pass (safe to re-run), and that
`--yes` mode truly never blocks on a prompt.

## Docker-free variant: `ai-dev-claude-no-docker.sh`

Real-world use turned up a recurring, sometimes hard-to-diagnose class of
failure: Docker inside a nested/unprivileged LXC (needs `nesting=1,keyctl=1`,
sometimes needs the `vfs` storage-driver fallback, and separately — the bug
that motivated this variant in the first place — Debian 13's `docker.io`
package only *Recommends* `docker-cli` rather than depending on it, so a
`--no-install-recommends` install starts a perfectly healthy daemon with no
`docker` command on PATH at all). Two of the six installed pieces were the
only ones that actually needed Docker: Termix (web SSH terminal) and Homepage
(dashboard). This variant drops Docker entirely by swapping those two:

- **Termix → [ttyd](https://github.com/tsl0922/ttyd)**: a single static Go
  binary (arch-specific asset, e.g. `ttyd.x86_64`, downloaded via GitHub's
  release API with a checksum comparison against the release's
  `SHA256SUMS`), run as a systemd service wrapping `login` in the browser
  terminal. It runs as root (required for `login` to switch users) with
  `--writable` (ttyd defaults to read-only) and HTTP Basic Auth (`-c`) as a
  first authentication layer in front of the real Linux login prompt.
  Termix itself was ruled out for a from-source non-Docker install: it's a
  Node.js ≥22 app needing native module compilation (`better-sqlite3`,
  `serialport`) with no documented bare-metal install path, only
  Docker/desktop-app distribution.
- **Homepage → static HTML + `python3 -m http.server`**: since the actual
  requirement is just "collect the links in one place," a generated static
  page (inline CSS, no external assets/fonts) removes the Next.js runtime
  entirely. Served by Python's standard-library HTTP server (already
  installed as a stage-1 base package, so no new dependency) running as
  `nobody` under systemd. `dashboard-refresh` rewrites the page directly —
  no restart needed, since static files are read fresh per request.

Everything else — code-server, FileBrowser Quantum, GitHub CLI, Claude
Code, the whiptail TUI framework, host-side container creation, the
reboot+finalize flow, and the OmniRoute-connect menu action — is identical
in structure to `ai-dev-claude.sh`, adapted only for the renamed
ports/services (`TERMIX_PORT`→`WEB_TERMINAL_PORT`,
`HOMEPAGE_PORT`→`DASHBOARD_PORT`) and one genuine simplification: the LXC
no longer needs `--features nesting=1,keyctl=1` at all, since nothing in
this variant runs inside a container-in-a-container.
