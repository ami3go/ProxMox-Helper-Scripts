# Proxmox Helper Scripts v2.2.7

This release contains the AI Development LXC v2.2.7 gateway and Codex implementation. It is packaged as a modular helper and as standalone launcher scripts.

## Entry points

```bash
sudo ./ai-dev-lxc.sh
sudo ./ai-dev-lxc-v2.2.7.sh
sudo ./proxmox-ai-dev-lxc.sh
```

All launchers execute `helpers/ai-dev-lxc/install.sh`.

## Validation

```bash
./scripts/validate.sh
```

## Build release archives

```bash
./scripts/package-release.sh
```

See [`helpers/ai-dev-lxc/README.md`](helpers/ai-dev-lxc/README.md) for deployment, DNS, migration, security, and management-command details.
