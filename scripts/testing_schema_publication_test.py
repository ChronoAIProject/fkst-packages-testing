#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

from json_schema_test_support import assert_all_refs_resolve, offline_registry, validator_for_schema_file
from schema_artifact_policy import validate_schema_file

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = ROOT / "schemas"
GLOBAL_INDEX = ROOT / "schema-fixtures" / "testing-schema-fixtures.v1.json"


def load(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    assert isinstance(value, dict), path
    return value


def main() -> int:
    schema_paths = tuple(sorted(SCHEMA_ROOT.glob("*.schema.json")))
    registry = offline_registry(schema_paths)
    validators = {}
    schema_names = {}
    for path in schema_paths:
        schema = validate_schema_file(path)
        assert_all_refs_resolve(schema, registry=registry)
        _, validators[path] = validator_for_schema_file(path, registry=registry)
        schema_names[path.name.removesuffix(".schema.json")] = path

    fixture_index = load(GLOBAL_INDEX)
    entries = fixture_index["fixture_sets"]
    assert isinstance(entries, list)
    assert len(entries) == len(schema_paths)
    assert {entry["schema_path"] for entry in entries} == {path.relative_to(ROOT).as_posix() for path in schema_paths}
    seen_indexes = set()
    total = 0
    for entry in entries:
        index_path = ROOT / entry["index_path"]
        if index_path in seen_indexes:
            continue
        seen_indexes.add(index_path)
        index = load(index_path)
        for case in index["cases"]:
            fixture = load(ROOT / entry["fixture_root"] / case["file"])
            instance = fixture if case["instance_field"] is None else fixture[case["instance_field"]]
            schema_path = schema_names[case["schema"]]
            errors = tuple(validators[schema_path].iter_errors(instance))
            assert bool(errors) is not case["portable_valid"], case["name"]
            total += 1

    commands = (
        [sys.executable, str(ROOT / "scripts/schema_artifact_policy.py"), "--check"],
        [sys.executable, str(ROOT / "scripts/generate_testing_schema_fixture_index.py"), "--check"],
        [sys.executable, str(ROOT / "scripts/generate_testing_schema_catalog.py"), "--check"],
    )
    for command in commands:
        subprocess.run(command, cwd=ROOT, check=True)
    print(f"testing-schema-publication: PASS ({len(schema_paths)} schemas, {total} cases)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
