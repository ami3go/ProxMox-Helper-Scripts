# Architecture

```text
Client browser
  │
  ├── ai-dev.home.arpa ───────┐
  ├── code.ai-dev.home.arpa ─────────┤
  ├── files.ai-dev.home.arpa ────────┤
  └── termix.ai-dev.home.arpa ───────┤
                              ▼
                      Caddy (native systemd)
                         │ 127.0.0.1
        ┌────────────────┼─────────────────┐
        ▼                ▼                 ▼
 Homepage :3000    code-server :8080   FileBrowser :8081
                                           │
                                           └── Termix :8082 (Docker publish)
```

Codex CLI is separate from the web gateway. It executes locally as the development user and accesses repositories under `/srv/workspace`.

## Control planes

- **Proxmox host:** selects CTID, transfers the helper, persists compatible managed state, and verifies routes from outside the guest.
- **LXC guest:** installs packages, generates runtime configuration, validates services, and manages rollback.
- **Runtime state:** `/etc/ai-development-gateway.env` contains non-secret configuration only.
- **Runtime payload:** `/opt/ai-dev-lxc-helper` contains the versioned helper modules.

## Transaction ordering

1. Install and locally verify Codex CLI; login may be deferred.
2. Deploy and locally verify Homepage.
3. Install Caddy, validate its file, start it, and verify each route.
4. Back up and restrict backend bindings.
5. Verify local listeners, HTTP routes, and Upgrade handling.
6. Restore original backend configuration immediately if verification fails.
