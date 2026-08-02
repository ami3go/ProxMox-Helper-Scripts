# Contributing

Contributions may add helper packages, improve shared infrastructure, strengthen tests, or clarify documentation.

## Add a helper

Start with the scaffold:

```bash
./scripts/new-helper.sh \
  --id my-helper \
  --name "My Helper" \
  --category utilities \
  --description "Describe the result in one sentence."
```

This creates one self-contained folder at `helpers/my-helper/`. Categories are metadata only, so changing a category never moves the helper directory.

A helper pull request must include:

- a complete static `manifest.env`
- an executable entrypoint with `set -Eeuo pipefail`
- target validation and dependency checks
- deterministic, conservative defaults
- confirmation before destructive operations
- meaningful error handling and logging
- update, repair, or safe rerun behavior
- documentation of prerequisites, changes, ports, files, credentials, and rollback
- helper-specific tests that do not modify a real Proxmox system during CI
- all helper-specific payloads, modules, templates, and assets inside the helper folder

Use the standard directories:

```text
helpers/<HELPER_ID>/
├── assets/
├── files/
├── lib/
├── templates/
└── tests/
```

Do not put product-specific provisioning logic into the repository-level `lib/`. Shared libraries should remain generic and useful to multiple helpers.

Resolve helper-local paths from `${BASH_SOURCE[0]}` rather than the caller's working directory.

## Validate changes

```bash
./scripts/generate-catalog.py
./scripts/validate.sh
./scripts/package-release.sh
```

Install ShellCheck locally where possible. CI always runs ShellCheck.

## Metadata rules

Manifest values must be literal. Do not use variable expansion, command substitution, shell functions, conditionals, includes, or command separators in `manifest.env`.

The helper ID must match its directory:

```text
helpers/<HELPER_ID>/manifest.env
```

The category is declared only in `HELPER_CATEGORY`.

Set `HELPER_STANDALONE="true"` only for a genuinely self-contained entrypoint. Every helper is already distributed as a complete folder bundle.

## Commit and pull request guidance

Keep commits focused. Explain operational risk, test coverage, migration impact, added package files, and rollback behavior in the pull request. Never include passwords, tokens, private keys, production addresses, or captured user data.
