# Proxmox Helper Scripts

[![CI](https://github.com/YOUR_GITHUB_USERNAME/proxmox-helper-scripts/actions/workflows/ci.yml/badge.svg)](https://github.com/YOUR_GITHUB_USERNAME/proxmox-helper-scripts/actions/workflows/ci.yml)
[![GitHub Pages](https://github.com/YOUR_GITHUB_USERNAME/proxmox-helper-scripts/actions/workflows/pages.yml/badge.svg)](https://github.com/YOUR_GITHUB_USERNAME/proxmox-helper-scripts/actions/workflows/pages.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

An extensible, manifest-driven repository for interactive Proxmox VE helper scripts.

The repository currently includes the **AI Development LXC** helper, which creates a headless Debian container with code-server, Python, Robot Framework, GitHub tooling, and selectable AI coding agents. The surrounding structure is designed so additional LXC, VM, storage, networking, backup, monitoring, and development helpers can be added without rebuilding the catalog, release, documentation, and validation infrastructure.

## Repository goals

- Keep every helper and all of its supporting files isolated in one top-level package directory.
- Discover helpers automatically from static manifests.
- Provide one central TUI and command-line launcher.
- Share generic shell primitives without coupling helper implementations.
- Generate the catalog and GitHub Pages data from metadata.
- Validate all scripts, manifests, versions, tests, and release assets in CI.
- Publish standalone installer files for helpers that support that mode.
- Make creating a new helper predictable and reviewable.

## Quick start

Clone the repository on a Proxmox VE node:

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/proxmox-helper-scripts.git
cd proxmox-helper-scripts
chmod +x bin/proxmox-helper-scripts
./bin/proxmox-helper-scripts
```

List available helpers without opening the TUI:

```bash
./bin/proxmox-helper-scripts list
```

Run a helper directly by ID:

```bash
./bin/proxmox-helper-scripts run ai-dev-lxc
```

Inspect its metadata first:

```bash
./bin/proxmox-helper-scripts info ai-dev-lxc
```

## Current helper catalog

See [HELPERS.md](HELPERS.md) for the generated catalog.

| ID | Helper | Category | Purpose |
|---|---|---|---|
| `ai-dev-lxc` | AI Development LXC | `development` | Create and maintain a headless multi-agent development container. |

## Directory layout

```text
.
├── bin/
│   └── proxmox-helper-scripts       Central launcher and TUI
├── helpers/
│   └── <helper-id>/
│       ├── manifest.env             Static registry metadata
│       ├── install.sh               Executable helper entrypoint
│       ├── README.md                Helper-specific documentation
│       ├── assets/                  Screenshots, diagrams, and icons
│       ├── files/                   Static payload files
│       ├── lib/                     Helper-specific shell modules
│       ├── templates/               Configuration templates
│       └── tests/                   Helper-specific tests
├── lib/
│   ├── common.sh                    Shared errors, logging, and checks
│   ├── registry.sh                  Discovery and execution
│   └── tui.sh                       whiptail and terminal UI primitives
├── templates/helper/                Scaffold used for new helpers
├── scripts/                         Validation, catalog, packaging, publishing
├── tests/                           Repository framework tests
├── docs/                            GitHub Pages source
└── .github/                         CI, releases, Pages, and contribution forms
```

The full design and boundaries are documented in [ARCHITECTURE.md](ARCHITECTURE.md).

Categories are stored in each helper's manifest rather than represented as directories. This gives every helper a stable path and lets it keep extra files beside its installer without introducing category-dependent nesting.

## Adding another helper

Generate a complete skeleton:

```bash
./scripts/new-helper.sh \
  --id backup-server \
  --name "Backup Server LXC" \
  --category storage \
  --description "Create and maintain a headless backup server container."
```

This creates:

```text
helpers/backup-server/
├── manifest.env
├── install.sh
├── README.md
├── assets/
├── files/
├── lib/
├── templates/
└── tests/smoke.sh
```

Implement the entrypoint, document all changes and rollback behavior, add tests, then run:

```bash
./scripts/generate-catalog.py
./scripts/validate.sh
```

The launcher, generated Markdown catalog, Pages JSON catalog, CI checks, release packager, and per-helper bundle exporter discover the new helper automatically. Category is metadata only; the helper folder remains `helpers/<helper-id>/`.

Detailed instructions are in [docs/adding-a-helper.md](docs/adding-a-helper.md), and the metadata fields are defined in [docs/helper-schema.md](docs/helper-schema.md).

## Manifest example

```bash
HELPER_ID="backup-server"
HELPER_NAME="Backup Server LXC"
HELPER_CATEGORY="storage"
HELPER_VERSION="0.1.0"
HELPER_DESCRIPTION="Create and maintain a headless backup server container."
HELPER_ENTRYPOINT="install.sh"
HELPER_TARGET="proxmox-host"
HELPER_TAGS="storage,backup,lxc"
HELPER_MAINTAINER="Repository maintainers"
HELPER_DOCS="README.md"
HELPER_STANDALONE="true"
```

Manifests are static metadata, not executable configuration. Validation rejects command substitution, variable expansion, arithmetic, command separators, arbitrary statements, duplicate IDs, mismatched helper folder names, missing package directories, missing entrypoints, and invalid semantic versions.

## AI Development LXC

The first included helper provisions:

- an unprivileged Debian LXC through native Proxmox `pct`, `pvesm`, and `pveam` commands
- code-server without a desktop environment
- Python, virtual environments, Robot Framework, and RobotCode
- Git and GitHub CLI
- Claude Code
- OpenAI Codex CLI
- Google Gemini CLI
- GitHub Copilot CLI
- Aider
- OpenCode
- SSH tunnel or password-protected LAN access
- a Robot Framework starter project
- update and repair flows that preserve `/srv/workspace`

Run it from the catalog:

```bash
./bin/proxmox-helper-scripts run ai-dev-lxc
```

Direct repository execution also remains available:

```bash
./helpers/ai-dev-lxc/install.sh
```

The legacy repository command remains as a compatibility wrapper:

```bash
./proxmox-ai-dev-lxc.sh
```

Tagged releases publish the actual standalone helper as both `ai-dev-lxc.sh` and `proxmox-ai-dev-lxc.sh`.

## Development commands

```bash
make catalog       # Regenerate HELPERS.md and docs/data/helpers.json
make validate      # Validate scripts, manifests, versions, tests, and Pages files
make package       # Build repository archives and standalone helper assets
make site          # Build the local GitHub Pages tree in _site/
make new-helper    # Start the interactive helper scaffold
```

Equivalent direct commands:

```bash
./scripts/generate-catalog.py
./scripts/validate.sh
./scripts/package-release.sh
```

## Validation model

The repository validation covers:

- Bash syntax for launchers, libraries, helpers, tests, and maintenance scripts
- Python syntax for metadata and catalog tools
- static manifest safety and schema compliance
- unique helper IDs and directory alignment
- executable and documented helper entrypoints
- helper manifest version alignment with `SCRIPT_VERSION`, where present
- embedded provisioner syntax for the AI Development LXC
- generated catalog freshness
- framework and helper smoke tests
- required GitHub Pages assets and action versions
- ShellCheck when installed

GitHub Actions installs ShellCheck and runs the same validation and packaging process for pushes and pull requests.

## Release contents

A tagged release contains:

```text
proxmox-helper-scripts-vX.Y.Z.zip
proxmox-helper-scripts-vX.Y.Z.tar.gz
helper-catalog.json
<helper-id>-bundle-v<helper-version>.zip
<helper-id>-bundle-v<helper-version>.tar.gz
<helper-id>.sh
<helper-id>-v<helper-version>.sh
proxmox-ai-dev-lxc.sh
SHA256SUMS
```

The repository archives contain the full launcher, shared libraries, all helper sources, documentation, templates, tests, and GitHub automation. Every helper also receives a complete ZIP and TAR.GZ folder bundle. Standalone `.sh` files are additional assets produced only for helpers declaring `HELPER_STANDALONE="true"`.

## GitHub Pages

The site source is under [`docs/`](docs/). Its helper catalog is generated from the same manifests used by the launcher:

```text
docs/data/helpers.json
```

The Pages workflow rebuilds the catalog, publishes the repository documentation, and exposes standalone downloads and checksums.

## Publish a new GitHub repository

Authenticate GitHub CLI and run:

```bash
gh auth login
./scripts/publish-to-github.sh YOUR_GITHUB_USERNAME/proxmox-helper-scripts public
```

The publisher replaces repository placeholders, validates the repository, initializes Git when needed, creates or updates the remote repository, pushes `main`, and enables workflow-based GitHub Pages when permissions allow.

## Security principles

Helpers run with substantial privileges and must be reviewed before use.

Every helper should:

- verify that it is running on its documented target
- use conservative defaults
- request explicit confirmation before destructive actions
- avoid exposing unauthenticated services
- protect credentials and state files
- log important operations without logging secrets
- support predictable re-entry, repair, or update behavior
- document all host and guest changes
- provide a rollback or removal procedure

An LXC shares the Proxmox host kernel. Use a full VM when stronger isolation, untrusted workloads, custom kernels, or extensive device passthrough are required.

Report vulnerabilities privately according to [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
