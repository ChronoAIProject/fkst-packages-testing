#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
POLICY_PATH = ROOT / "schema-release" / "testing-schema-policy.v1.json"
DRAFT = "https://json-schema.org/draft/2020-12/schema"
ALLOWED_KEYWORDS = frozenset({
    "$schema", "$id", "$ref", "$defs",
    "title", "description",
    "type", "const", "enum",
    "properties", "required", "additionalProperties",
    "items", "minItems", "maxItems", "uniqueItems", "contains", "minContains", "maxContains",
    "minimum", "maximum",
    "minLength", "maxLength", "pattern", "format",
    "allOf", "anyOf", "oneOf", "not", "if", "then", "else",
    "x-fkst-canonicalization", "x-fkst-maxUtf8Bytes",
})
ALLOWED_EXTENSIONS = frozenset({"x-fkst-canonicalization", "x-fkst-maxUtf8Bytes"})
ALLOWED_FORMATS = frozenset({
    "date-time",
    "fkst-utf8-max-32", "fkst-utf8-max-64", "fkst-utf8-max-80",
    "fkst-utf8-max-96", "fkst-utf8-max-120", "fkst-utf8-max-180",
    "fkst-utf8-max-512", "fkst-utf8-max-4096",
})
SCHEMA_MAP_KEYWORDS = frozenset({"properties", "$defs"})
SCHEMA_ARRAY_KEYWORDS = frozenset({"allOf", "anyOf", "oneOf"})
SCHEMA_VALUE_KEYWORDS = frozenset({
    "additionalProperties", "items", "contains", "not", "if", "then", "else",
})


def policy_document() -> dict[str, object]:
    return {
        "schema": "testing-schema-policy.v1",
        "draft": DRAFT,
        "allowed_keywords": sorted(ALLOWED_KEYWORDS),
        "allowed_extensions": sorted(ALLOWED_EXTENSIONS),
        "allowed_formats": sorted(ALLOWED_FORMATS),
    }


def policy_bytes() -> bytes:
    return (json.dumps(policy_document(), ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n").encode()


def _schema_children(keyword: str, value: object) -> Iterable[tuple[str, object]]:
    if keyword in SCHEMA_MAP_KEYWORDS and isinstance(value, dict):
        for name, child in value.items():
            yield name, child
    elif keyword in SCHEMA_ARRAY_KEYWORDS and isinstance(value, list):
        for index, child in enumerate(value):
            yield str(index), child
    elif keyword in SCHEMA_VALUE_KEYWORDS and isinstance(value, (dict, bool)):
        yield keyword, value


def validate_schema_policy(schema: object, source: str = "<schema>") -> None:
    def visit(value: object, location: str) -> None:
        if isinstance(value, bool):
            return
        if not isinstance(value, dict):
            raise ValueError(f"{source}:{location}: schema location must be an object or Boolean")
        for keyword, child in value.items():
            if keyword not in ALLOWED_KEYWORDS:
                if keyword.startswith("x-"):
                    raise ValueError(f"{source}:{location}: unsupported extension {keyword!r}")
                raise ValueError(f"{source}:{location}: unsupported keyword {keyword!r}")
            if keyword == "format":
                if not isinstance(child, str) or child not in ALLOWED_FORMATS:
                    raise ValueError(f"{source}:{location}: unsupported format {child!r}")
            if keyword == "$schema" and child != DRAFT:
                raise ValueError(f"{source}:{location}: unsupported draft {child!r}")
            for name, nested in _schema_children(keyword, child):
                visit(nested, f"{location}/{keyword}/{name}")

    visit(schema, "#")


def validate_schema_file(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"unable to load schema {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"schema root must be an object: {path}")
    validate_schema_policy(value, path.as_posix())
    return value


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("paths", nargs="*", type=Path)
    args = parser.parse_args()
    paths = args.paths or sorted((ROOT / "schemas").glob("*.schema.json"))
    for path in paths:
        validate_schema_file(path)
    expected = policy_bytes()
    if args.check:
        if not POLICY_PATH.is_file() or POLICY_PATH.read_bytes() != expected:
            raise SystemExit(f"schema policy drift: {POLICY_PATH.relative_to(ROOT)}")
    else:
        POLICY_PATH.parent.mkdir(parents=True, exist_ok=True)
        POLICY_PATH.write_bytes(expected)
    print(f"schema-artifact-policy: PASS ({len(paths)} schemas)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
