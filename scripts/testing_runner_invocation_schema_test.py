#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
from jsonschema import RefResolver
from json_schema_test_support import load_json, validator_for_schema
from schema_fixture_runner import FixtureSpec, load_schema_validator, run_fixtures

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas/testing-runner-invocation.v1.schema.json"
DEPENDENCY = ROOT / "schemas/testing-package-executor.request.v1.schema.json"
FIXTURES = ROOT / "packages/testing-runner/tests/fixtures/testing-runner-invocation.v1"


def main() -> int:
    def validator_factory(schema):
        dependency = load_json(DEPENDENCY)
        resolver = RefResolver.from_schema(schema, store={dependency["$id"]: dependency})
        return validator_for_schema(schema, resolver=resolver)

    schema, validator = load_schema_validator(
        SCHEMA,
        validator_factory=validator_factory,
    )
    index = load_json(FIXTURES / "index.json")
    assert set(index) == {"schema", "cases"}
    assert index == {"schema": "testing-runner-invocation-fixture-index.v1", "cases": [{"name": "valid-canonical-envelope", "file": "valid-canonical-envelope.json"}]}

    case = index["cases"][0]

    def before_validate(_spec, fixture) -> None:
        assert set(fixture) == {"case", "portable_valid", "lua_valid", "lua_error", "request"}
        assert fixture["case"] == "valid-canonical-envelope"
        assert fixture["portable_valid"] is True and fixture["lua_valid"] is True and fixture["lua_error"] == ""

    run_fixtures(
        (FixtureSpec(case["name"], FIXTURES / case["file"], expected_valid=True),),
        validator_for=lambda _spec, _fixture: validator,
        instance_for=lambda _spec, fixture: fixture["request"],
        before_validate=before_validate,
    )
    assert schema["additionalProperties"] is False
    assert set(schema["required"]) == set(schema["properties"])
    print("testing-runner-invocation-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
