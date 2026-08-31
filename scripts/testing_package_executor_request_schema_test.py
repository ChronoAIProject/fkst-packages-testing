#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

from json_schema_test_support import load_json, validator_for_schema


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas" / "testing-package-executor.request.v1.schema.json"
FIXTURES = (
    ROOT
    / "packages"
    / "testing-runner"
    / "tests"
    / "fixtures"
    / "testing-package-executor.request.v1"
)
CONTEXTUAL_CASES = {
    "contextual-unsupported-execution-profile",
    "contextual-unsupported-executor-mapping",
}


def main() -> int:
    schema = load_json(SCHEMA)
    validator = validator_for_schema(schema)

    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["$id"] == (
        "https://chronoaiproject.github.io/fkst-packages-testing/"
        "schemas/testing-package-executor.request.v1.schema.json"
    )
    assert schema["additionalProperties"] is False
    assert set(schema["required"]) == set(schema["properties"])
    assert set(schema["properties"]) == {
        "schema",
        "executor",
        "execution_profile",
        "approved_input_refs",
        "trace_id",
        "dedup_key",
    }
    encoded_schema = json.dumps(schema, sort_keys=True)
    for resolver_literal in (
        "browser-deterministic.v1",
        "testing-runner.run",
        "testing-runner.v1",
    ):
        assert resolver_literal not in encoded_schema

    fixture_paths = sorted(FIXTURES.glob("*.json"))
    assert fixture_paths
    contextual_cases = set()
    for path in fixture_paths:
        fixture = load_json(path)
        assert fixture["case"] == path.stem
        assert isinstance(fixture["portable_valid"], bool)
        assert isinstance(fixture["runtime_valid"], bool)
        assert isinstance(fixture["resolver_error"], str)
        assert isinstance(fixture["request"], dict)
        errors = list(validator.iter_errors(fixture["request"]))
        if fixture["portable_valid"]:
            assert not errors, (path.stem, [error.message for error in errors])
        else:
            assert errors, f"schema accepted invalid shared fixture: {path.stem}"
            assert fixture["runtime_valid"] is False
            assert fixture["resolver_error"] == ""
        if fixture["portable_valid"] and fixture["resolver_error"]:
            assert fixture["runtime_valid"] is True
            contextual_cases.add(path.stem)

    assert contextual_cases == CONTEXTUAL_CASES
    print("testing-package-executor-request-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
