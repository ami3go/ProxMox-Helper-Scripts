# Adding a helper

Create a complete helper package:

```bash
./scripts/new-helper.sh \
  --id backup-server \
  --name "Backup Server LXC" \
  --category storage \
  --description "Create a headless backup server container."
```

The helper is created directly under `helpers/backup-server/`:

```text
helpers/backup-server/
├── manifest.env
├── install.sh
├── README.md
├── assets/
├── files/
├── lib/
├── templates/
└── tests/
```

Use the package directories as follows:

- `assets/`: screenshots, diagrams, icons, and documentation media
- `files/`: static payloads copied to a host, container, or VM
- `lib/`: shell modules used only by this helper
- `templates/`: configuration templates rendered during installation
- `tests/`: non-destructive helper validation and smoke tests

Resolve all helper-local paths from the location of `install.sh`, not from `$PWD`.

Implement the installer, document changes and rollback in its README, and add tests under `tests/`. Then run:

```bash
./scripts/generate-catalog.py
./scripts/validate.sh
./scripts/package-release.sh
```

The helper automatically appears in the launcher, generated catalog, GitHub Pages site, full repository release, and its own ZIP/TAR.GZ helper bundle.

Set `HELPER_STANDALONE="true"` only when `install.sh` contains everything required to run by itself. Helpers that use `files/`, `lib/`, or `templates/` should normally leave standalone mode disabled and distribute the complete bundle.

A pull request must include deterministic defaults, explicit confirmation before destructive actions, error handling, logging, update behavior, security notes, and a tested rollback path.
