# Adding a helper

A helper lives under `helpers/<helper-id>/` and includes:

- `manifest.env`
- an executable `install.sh`
- helper-specific `lib/`, `templates/`, `files/`, and `tests/`
- a README describing state, migration, verification, security, and rollback

Generated runtime files must not be committed at the repository root. Secrets and credential caches must be excluded from source and release archives. New helpers must provide shell syntax checks and at least one functional configuration-generation test.
