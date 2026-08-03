# Helper packages

Each immediate subdirectory of `helpers/` is one complete helper package:

```text
helpers/<helper-id>/
├── manifest.env
├── install.sh
├── post-install.sh        # optional
├── README.md
├── assets/
├── files/
├── lib/
├── templates/
└── tests/
```

Do not create category directories. Categories are declared through `HELPER_CATEGORY` in `manifest.env` and are used only for catalog grouping and search.

Keep every file required by a helper inside its package folder. Use repository-level `lib/` only for generic code shared by multiple helpers.

When a helper supports configuring an existing environment, declare `HELPER_POST_INSTALL` in its manifest and keep that executable beside `install.sh`.
