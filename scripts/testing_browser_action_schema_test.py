#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from schema_fixture_runner import (
    assert_no_errors_with_messages,
    discover_fixtures,
    load_schema_validator,
    run_fixtures,
)


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
    schema, validator = load_schema_validator(SCHEMA)

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

    fixture_specs = discover_fixtures(FIXTURES)
    assert fixture_specs
    contextual_cases = set()

    def before_validate(spec, fixture) -> None:
        assert fixture["case"] == spec.name
        assert isinstance(fixture["portable_valid"], bool)
        assert isinstance(fixture["runtime_valid"], bool)
        assert isinstance(fixture["allowed_actions"], list)
        assert isinstance(fixture["approved_secret_refs"], list)
        assert isinstance(fixture["action"], dict)

    def after_validate(result) -> None:
        fixture = result.fixture
        if not fixture["portable_valid"]:
            assert fixture["runtime_valid"] is False
        if fixture["portable_valid"] and not fixture["runtime_valid"]:
            contextual_cases.add(result.spec.name)

    run_fixtures(
        fixture_specs,
        validator_for=lambda _spec, _fixture: validator,
        instance_for=lambda _spec, fixture: fixture["action"],
        expected_valid_for=lambda _spec, fixture: fixture["portable_valid"],
        before_validate=before_validate,
        after_validate=after_validate,
        valid_failure=assert_no_errors_with_messages,
    )

    assert contextual_cases == {
        "contextual-unauthorized-action",
        "contextual-unapproved-secret-ref",
    }
    print("testing-browser-action-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
