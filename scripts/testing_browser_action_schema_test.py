#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from json_schema_test_support import load_json, validator_for_schema


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas" / "testing-runner.ai-browser-control.action.v1.schema.json"
FIXTURES = (
    ROOT
    / "packages"
    / "testing-runner"
    / "tests"
    / "fixtures"
    / "testing-browser-action.v1"
)


def main() -> int:
    schema = load_json(SCHEMA)
    validator = validator_for_schema(schema)

    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["$id"] == (
        "https://chronoaiproject.github.io/fkst-packages-testing/"
        "schemas/testing-runner.ai-browser-control.action.v1.schema.json"
    )
    assert schema["additionalProperties"] is False
    assert set(schema["properties"]) == {
        "schema",
        "turn",
        "kind",
        "handle",
        "secret_ref",
        "advisory_status",
    }
    assert len(schema["oneOf"]) == 5
    assert "x-fkst-canonicalization" not in schema

    fixture_paths = sorted(FIXTURES.glob("*.json"))
    assert fixture_paths
    contextual_cases = set()
    for path in fixture_paths:
        fixture = load_json(path)
        assert fixture["case"] == path.stem
        assert isinstance(fixture["portable_valid"], bool)
        assert isinstance(fixture["runtime_valid"], bool)
        assert isinstance(fixture["allowed_actions"], list)
        assert isinstance(fixture["approved_secret_refs"], list)
        assert isinstance(fixture["action"], dict)
        errors = list(validator.iter_errors(fixture["action"]))
        if fixture["portable_valid"]:
            assert not errors, (path.stem, [error.message for error in errors])
        else:
            assert errors, f"schema accepted invalid shared fixture: {path.stem}"
            assert fixture["runtime_valid"] is False
        if fixture["portable_valid"] and not fixture["runtime_valid"]:
            contextual_cases.add(path.stem)

    assert contextual_cases == {
        "contextual-unauthorized-action",
        "contextual-unapproved-secret-ref",
    }
    print("testing-browser-action-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
