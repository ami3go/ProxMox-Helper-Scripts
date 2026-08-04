#!/usr/bin/env python3
"""Generate the Markdown and JSON helper catalogs from validated manifests."""
from __future__ import annotations

import json
import shlex
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPERS = ROOT / "helpers"


def read_manifest(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, encoded = line.split("=", 1)
        result[key] = shlex.split(encoded)[0]
    return result


def main() -> None:
    records = []
    for path in sorted(HELPERS.glob("*/manifest.env")):
        values = read_manifest(path)
        rel = path.parent.relative_to(ROOT).as_posix()
        records.append(
            {
                "id": values["HELPER_ID"],
                "name": values["HELPER_NAME"],
                "category": values["HELPER_CATEGORY"],
                "version": values["HELPER_VERSION"],
                "description": values["HELPER_DESCRIPTION"],
                "target": values["HELPER_TARGET"],
                "tags": [x for x in values.get("HELPER_TAGS", "").split(",") if x],
                "path": rel,
                "entrypoint": f"{rel}/{values['HELPER_ENTRYPOINT']}",
                "docs": f"{rel}/{values.get('HELPER_DOCS', 'README.md')}",
                "bundle": f"{values['HELPER_ID']}-bundle-v{values['HELPER_VERSION']}.zip",
                "standalone": values.get("HELPER_STANDALONE", "false").lower() == "true",
            }
        )

    (ROOT / "docs/data").mkdir(parents=True, exist_ok=True)
    (ROOT / "docs/data/helpers.json").write_text(
        json.dumps({"schemaVersion": 2, "helpers": records}, indent=2) + "\n",
        encoding="utf-8",
    )

    lines = [
        "# Helper Catalog",
        "",
        "This file is generated from `helpers/*/manifest.env`. Do not edit it manually.",
        "",
        "| Helper | Category | Version | Target | Description |",
        "|---|---|---:|---|---|",
    ]
    for item in records:
        lines.append(
            f"| [{item['name']}]({item['docs']}) (`{item['id']}`) | "
            f"{item['category']} | {item['version']} | {item['target']} | {item['description']} |"
        )
    lines.extend(["", f"Total helpers: **{len(records)}**", ""])
    (ROOT / "HELPERS.md").write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
