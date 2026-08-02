#!/usr/bin/env python3
"""Validate static helper manifests without executing them."""
from __future__ import annotations

import re
import shlex
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HELPERS = ROOT / "helpers"
REQUIRED = {
    "HELPER_ID",
    "HELPER_NAME",
    "HELPER_CATEGORY",
    "HELPER_VERSION",
    "HELPER_DESCRIPTION",
    "HELPER_ENTRYPOINT",
    "HELPER_TARGET",
}
ALLOWED = REQUIRED | {
    "HELPER_TAGS",
    "HELPER_MAINTAINER",
    "HELPER_DOCS",
    "HELPER_STANDALONE",
}
STANDARD_DIRS = ("assets", "files", "lib", "templates", "tests")
SLUG = re.compile(r"^[a-z0-9]+(?:[._-][a-z0-9]+)*$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[+-][A-Za-z0-9._-]+)?$")
ASSIGNMENT = re.compile(r"^([A-Z_][A-Z0-9_]*)=(.*)$")


def parse_manifest(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = ASSIGNMENT.fullmatch(line)
        if not match:
            raise ValueError(f"{path}:{number}: only literal KEY=VALUE assignments are allowed")
        key, encoded = match.groups()
        if key not in ALLOWED:
            raise ValueError(f"{path}:{number}: unsupported field {key}")
        if not (encoded.startswith('"') and encoded.endswith('"')):
            raise ValueError(f"{path}:{number}: values must be double-quoted literals")
        if any(token in encoded for token in ("$(", "`", "${", "$((", ";", "&&", "||")):
            raise ValueError(f"{path}:{number}: dynamic shell syntax is not allowed")
        try:
            parts = shlex.split(encoded, posix=True)
        except ValueError as exc:
            raise ValueError(f"{path}:{number}: {exc}") from exc
        if len(parts) != 1:
            raise ValueError(f"{path}:{number}: value must be one quoted literal")
        if key in values:
            raise ValueError(f"{path}:{number}: duplicate field {key}")
        values[key] = parts[0]
    return values


def main() -> int:
    manifests = sorted(HELPERS.glob("*/manifest.env"))
    nested = sorted(path for path in HELPERS.rglob("manifest.env") if path not in manifests)
    errors: list[str] = []
    if nested:
        for path in nested:
            errors.append(
                f"{path}: manifests must be directly under helpers/<helper-id>/; "
                "categories belong in HELPER_CATEGORY metadata"
            )
    if not manifests:
        print("ERROR: no helper manifests found", file=sys.stderr)
        return 1

    ids: set[str] = set()
    for manifest in manifests:
        try:
            values = parse_manifest(manifest)
            missing = REQUIRED - values.keys()
            if missing:
                raise ValueError(f"{manifest}: missing fields: {', '.join(sorted(missing))}")
            helper_id = values["HELPER_ID"]
            category = values["HELPER_CATEGORY"]
            if not SLUG.fullmatch(helper_id):
                raise ValueError(f"{manifest}: invalid HELPER_ID {helper_id!r}")
            if not SLUG.fullmatch(category):
                raise ValueError(f"{manifest}: invalid HELPER_CATEGORY {category!r}")
            if not SEMVER.fullmatch(values["HELPER_VERSION"]):
                raise ValueError(f"{manifest}: invalid HELPER_VERSION {values['HELPER_VERSION']!r}")
            if helper_id in ids:
                raise ValueError(f"{manifest}: duplicate HELPER_ID {helper_id}")
            ids.add(helper_id)
            if manifest.parent.name != helper_id:
                raise ValueError(f"{manifest}: directory must match HELPER_ID")
            entry = manifest.parent / values["HELPER_ENTRYPOINT"]
            if not entry.is_file():
                raise ValueError(f"{manifest}: entrypoint does not exist: {entry.name}")
            docs = manifest.parent / values.get("HELPER_DOCS", "README.md")
            if not docs.is_file():
                raise ValueError(f"{manifest}: documentation file does not exist: {docs.name}")
            missing_dirs = [name for name in STANDARD_DIRS if not (manifest.parent / name).is_dir()]
            if missing_dirs:
                raise ValueError(
                    f"{manifest}: missing standard helper directories: {', '.join(missing_dirs)}"
                )
            standalone = values.get("HELPER_STANDALONE", "false").lower()
            if standalone not in {"true", "false"}:
                raise ValueError(f"{manifest}: HELPER_STANDALONE must be true or false")
            print(f"OK  {helper_id} [{category}] v{values['HELPER_VERSION']}")
        except ValueError as exc:
            errors.append(str(exc))

    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print(f"Validated {len(manifests)} static helper manifest(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
