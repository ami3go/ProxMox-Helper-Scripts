# Helper packages

Each immediate subdirectory of `helpers/` is one complete helper package:

```text
helpers/<helper-id>/
├── manifest.env
├── install.sh
├── README.md
├── assets/
├── files/
├── lib/
├── templates/
└── tests/
```

Do not create category directories. Categories are declared through `HELPER_CATEGORY` in `manifest.env` and are used only for catalog grouping and search.

Keep every file required by a helper inside its package folder. Use repository-level `lib/` only for generic code shared by multiple helpers.
