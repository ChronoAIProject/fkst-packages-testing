#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

from schema_fixture_runner import (
    assert_no_errors_with_messages,
    discover_fixtures,
    load_schema_validator,
    run_fixtures,
)


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
    schema, validator = load_schema_validator(SCHEMA)

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

    fixture_specs = discover_fixtures(FIXTURES)
    assert fixture_specs
    contextual_cases = set()

    def before_validate(spec, fixture) -> None:
        assert fixture["case"] == spec.name
        assert isinstance(fixture["portable_valid"], bool)
        assert isinstance(fixture["runtime_valid"], bool)
        assert isinstance(fixture["resolver_error"], str)
        assert isinstance(fixture["request"], dict)

    def after_validate(result) -> None:
        fixture = result.fixture
        if not fixture["portable_valid"]:
            assert fixture["runtime_valid"] is False
            assert fixture["resolver_error"] == ""
        if fixture["portable_valid"] and fixture["resolver_error"]:
            assert fixture["runtime_valid"] is True
            contextual_cases.add(result.spec.name)

    run_fixtures(
        fixture_specs,
        validator_for=lambda _spec, _fixture: validator,
        instance_for=lambda _spec, fixture: fixture["request"],
        expected_valid_for=lambda _spec, fixture: fixture["portable_valid"],
        before_validate=before_validate,
        after_validate=after_validate,
        valid_failure=assert_no_errors_with_messages,
    )

    assert contextual_cases == CONTEXTUAL_CASES
    print("testing-package-executor-request-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
