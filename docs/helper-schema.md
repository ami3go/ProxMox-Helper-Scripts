# Helper manifest schema

`manifest.env` is a shell-compatible, non-secret metadata file.

Required fields:

```text
HELPER_ID
HELPER_NAME
HELPER_VERSION
HELPER_DESCRIPTION
HELPER_ENTRYPOINT
HELPER_TARGET
```

Optional catalog fields include category, tags, maintainer, documentation path, and standalone support. Values must be quoted and must not execute commands.
