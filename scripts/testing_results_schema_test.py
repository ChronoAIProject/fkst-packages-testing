#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from referencing import Registry, Resource

from json_schema_test_support import load_json, validator_for_schema
from schema_fixture_runner import (
    FixtureSpec,
    load_schema_validator,
    raise_first_error,
    run_fixtures,
)


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = ROOT / "schemas"
FIXTURES = ROOT / "packages" / "testing-runner" / "tests" / "fixtures" / "testing-results"

SCHEMA_NAMES = (
    "testing-observation.v1.schema.json",
    "testing-assertion-result.v1.schema.json",
    "testing-case-result.v2.schema.json",
    "testing-case-result-set.v2.schema.json",
)
VALID = (
    "valid-observation",
    "valid-assertion",
    "valid-case-passed",
    "valid-case-failed",
    "valid-case-skipped",
    "valid-case-not-applicable",
    "valid-case-error",
    "valid-case-blocked",
    "valid-case-lost",
    "valid-case-year-zero",
    "valid-result-set",
)
INVALID_VALIDATORS = {
    "invalid-unknown-field": "additionalProperties",
    "invalid-missing-required-field": "required",
    "invalid-overlong-reference-kind": "x-fkst-maxUtf8Bytes",
    "invalid-malformed-digest": "pattern",
    "invalid-impossible-date": "format",
    "invalid-hyphen-time-separators": "pattern",
    "invalid-multibyte-over-byte-limit": "x-fkst-maxUtf8Bytes",
    "invalid-nested-multibyte-over-byte-limit": "format",
    "invalid-assertion-truth-table": "const",
    "invalid-case-outcome": "const",
    "invalid-case-error-rule": "not",
    "invalid-case-reason-rule": "not",
    "invalid-required-assertion": "contains",
    "invalid-set-digest-presence": "required",
    "invalid-duration-negative": "minimum",
    "invalid-duration-over-max": "maximum",
}
SCHEMA_BY_DISCRIMINATOR = {
    "testing-observation.v1": "testing-observation.v1.schema.json",
    "testing-assertion-result.v1": "testing-assertion-result.v1.schema.json",
    "testing-case-result.v2": "testing-case-result.v2.schema.json",
    "testing-case-result-set.v2": "testing-case-result-set.v2.schema.json",
}


def make_registry() -> Registry:
    registry = Registry()
    for name in (*SCHEMA_NAMES, "testing-evidence-manifest.v1.schema.json"):
        schema = load_json(SCHEMA_ROOT / name)
        registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))
    return registry


def validator_for(name: str, registry: Registry):
    _, validator = load_schema_validator(
        SCHEMA_ROOT / name,
        validator_factory=lambda schema: validator_for_schema(schema, registry=registry),
    )
    return validator


def main() -> int:
    registry = make_registry()
    for name in SCHEMA_NAMES:
        schema, _validator = load_schema_validator(SCHEMA_ROOT / name)
        assert schema["$id"].endswith(name)
        assert schema["x-fkst-canonicalization"] == "fkst-testing-results-canonical-json.v1"

    def validator_for_fixture(_spec, fixture):
        return validator_for(SCHEMA_BY_DISCRIMINATOR[fixture["schema"]], registry)

    run_fixtures(
        (
            FixtureSpec(name, FIXTURES / f"{name}.json", expected_valid=True)
            for name in VALID
        ),
        validator_for=validator_for_fixture,
        valid_failure=raise_first_error,
    )
    run_fixtures(
        (
            FixtureSpec(
                name,
                FIXTURES / f"{name}.json",
                expected_valid=False,
                expected_validator=expected_validator,
            )
            for name, expected_validator in INVALID_VALIDATORS.items()
        ),
        validator_for=validator_for_fixture,
        validator_key=lambda error: str(error.validator),
    )

    print("testing-results-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
