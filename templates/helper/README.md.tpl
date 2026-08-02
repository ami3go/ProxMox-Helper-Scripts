# __HELPER_NAME__

__HELPER_DESCRIPTION__

## Run

```bash
./bin/proxmox-helper-scripts run __HELPER_ID__
```

Direct repository execution:

```bash
./helpers/__HELPER_ID__/install.sh
```

## Package contents

- `install.sh`: main entrypoint
- `assets/`: documentation media
- `files/`: static payload files
- `lib/`: helper-specific shell modules
- `templates/`: configuration templates
- `tests/`: helper tests

## Requirements

- Proxmox VE host
- root access

## What it changes

Document every host, container, VM, network, storage, package, service, user, port, and file change before publishing the helper.

## Rollback

Document a tested rollback or removal path.
