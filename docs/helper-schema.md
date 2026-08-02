# Helper manifest schema

Every helper contains:

```text
helpers/<helper-id>/manifest.env
```

The filesystem directory is identified only by `HELPER_ID`. `HELPER_CATEGORY` is catalog metadata and does not add another directory level.

## Required fields

- `HELPER_ID`: unique lowercase slug matching the helper directory name
- `HELPER_NAME`: human-readable name
- `HELPER_CATEGORY`: searchable category label such as `storage` or `development`
- `HELPER_VERSION`: semantic version
- `HELPER_DESCRIPTION`: one-line catalog description
- `HELPER_ENTRYPOINT`: executable file relative to the helper directory
- `HELPER_TARGET`: expected execution target, normally `proxmox-host`

## Optional fields

- `HELPER_TAGS`: comma-separated search tags
- `HELPER_MAINTAINER`: maintainer label
- `HELPER_DOCS`: helper documentation path
- `HELPER_STANDALONE`: `true` only when the entrypoint can run without other package files

Every helper package must also contain the standard directories `assets/`, `files/`, `lib/`, `templates/`, and `tests/`. They may contain only a README until needed.

Manifest values must be literal strings. Command substitution, variable expansion, arithmetic, command separators, and arbitrary shell statements are rejected.

Every helper is packaged as a complete ZIP and TAR.GZ bundle. Standalone scripts are additional assets, not a replacement for helper bundles.
