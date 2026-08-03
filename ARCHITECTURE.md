# Repository Architecture

This repository is a catalog and execution framework for independent Proxmox helper packages. Each helper owns one directory containing its installer and every supporting file it needs. Common discovery, validation, documentation, release, and scaffolding remain centralized.

## Directory layout

```text
.
├── bin/
│   └── proxmox-helper-scripts       Central catalog launcher
├── helpers/
│   └── <helper-id>/
│       ├── manifest.env             Static registry metadata
│       ├── install.sh               Primary helper entrypoint
│       ├── post-install.sh          Optional existing-environment entrypoint
│       ├── README.md                Helper documentation
│       ├── assets/                  Screenshots, diagrams, icons
│       ├── files/                   Static payload files
│       ├── lib/                     Helper-specific shell modules
│       ├── templates/               Configuration templates
│       └── tests/                   Helper-specific tests
├── lib/
│   ├── common.sh                    Logging, errors, root and command checks
│   ├── registry.sh                  Manifest discovery and helper execution
│   └── tui.sh                       whiptail and terminal UI primitives
├── templates/helper/                Complete new-helper package skeleton
├── scripts/
│   ├── new-helper.sh                Scaffold a helper package
│   ├── validate-manifests.py        Safely validate static metadata and layout
│   ├── generate-catalog.py          Build HELPERS.md and Pages JSON
│   ├── export-helpers.sh            Build complete helper bundles
│   ├── build-site.sh                Build GitHub Pages and downloads
│   ├── validate.sh                  Repository validation
│   └── package-release.sh           Repository and helper release assets
├── tests/                            Framework-level tests
├── docs/                             GitHub Pages source
└── .github/                          CI, Pages, releases, and templates
```

## Why categories are not directories

`HELPER_CATEGORY` remains part of each manifest and is used by the TUI, CLI filtering, search, and generated catalog. It does not create another filesystem level. This keeps every helper at a stable and predictable path:

```text
helpers/<helper-id>/
```

Moving a helper between catalog categories therefore requires only a manifest change and does not break repository paths, links, tests, or helper-local file references.

## Helper package boundaries

1. A helper is independently owned under `helpers/<helper-id>/`.
2. All helper-specific payloads, modules, templates, assets, documentation, and tests remain in that folder.
3. Shared libraries provide generic primitives only. Product-specific provisioning stays inside the helper package.
4. `manifest.env` contains literal metadata only. CI rejects expressions, shell statements, and unsupported fields.
5. The launcher discovers helper packages dynamically. Adding one valid folder automatically adds it to the catalog.
6. Every helper is exported as a complete ZIP and TAR.GZ bundle, so additional files are never lost.
7. A helper may declare `HELPER_POST_INSTALL` for a second executable that configures an existing environment.
8. A helper may additionally publish a standalone `.sh` file only when `HELPER_STANDALONE="true"` and the primary entrypoint is genuinely self-contained.
9. Generated files (`HELPERS.md` and `docs/data/helpers.json`) are derived from manifests and checked by CI.

## Resolving helper-local files

An installer must resolve paths relative to itself rather than the current working directory:

```bash
HELPER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_TEMPLATE="$HELPER_DIR/templates/service.conf.tpl"
PAYLOAD_FILE="$HELPER_DIR/files/default-config.json"
# shellcheck source=lib/functions.sh
source "$HELPER_DIR/lib/functions.sh"
```

This works when a helper is launched from the central TUI, executed directly, extracted as a bundle, or called from another directory.

## Release model

Tagged releases contain:

- full repository ZIP and TAR.GZ archives
- a complete ZIP and TAR.GZ bundle for every helper folder
- optional standalone primary entrypoints for self-contained helpers
- optional standalone post-install entrypoints when declared in the manifest
- generated helper catalog JSON
- SHA-256 checksums

The complete helper bundle is the canonical release form when an installer depends on files beside `install.sh`.

## Compatibility

`proxmox-ai-dev-lxc.sh` remains a repository-level compatibility launcher. Tagged releases also publish the self-contained AI Development LXC installer, its post-install utility, and a complete `ai-dev-lxc` helper bundle.
