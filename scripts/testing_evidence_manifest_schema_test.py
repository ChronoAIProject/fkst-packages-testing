#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from json_schema_test_support import load_json
from schema_fixture_runner import (
    FixtureSpec,
    load_schema_validator,
    raise_first_error,
    run_fixtures,
)


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas" / "testing-evidence-manifest.v1.schema.json"
FIXTURES = (
    ROOT
    / "packages"
    / "testing-runner"
    / "tests"
    / "fixtures"
    / "testing-evidence-manifest.v1"
)
INVALID_FIXTURES = {
    "invalid-empty-entries": "minItems",
    "invalid-malformed-artifact-ref": "not",
    "invalid-malformed-digest": "pattern",
    "invalid-malformed-timestamp": "pattern",
    "invalid-impossible-date": "format",
    "invalid-hyphen-time-separators": "pattern",
    "invalid-multibyte-over-byte-limit": "x-fkst-maxUtf8Bytes",
    "invalid-missing-required-field": "required",
    "invalid-overlong-evidence-id": "maxLength",
    "invalid-overlong-reference-kind": "maxLength",
    "invalid-role-media-mismatch": "oneOf",
    "invalid-size-bytes-fractional": "type",
    "invalid-size-bytes-negative": "minimum",
    "invalid-size-bytes-over-max": "maximum",
    "invalid-too-many-entries": "maxItems",
    "invalid-unknown-field": "additionalProperties",
    "invalid-unsupported-policy-status": "enum",
    "invalid-unsupported-role": "enum",
    "invalid-unsupported-sensitivity": "enum",
}


def main() -> int:
    schema, validator = load_schema_validator(SCHEMA)

    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["$id"] == (
        "https://chronoaiproject.github.io/fkst-packages-testing/"
        "schemas/testing-evidence-manifest.v1.schema.json"
    )
    assert set(schema["properties"]) == set(schema["required"])
    assert len(schema["required"]) == 9

    entry = schema["$defs"]["entry"]
    assert set(entry["required"]) == set(entry["properties"]) - {"assertion_id"}
    assert entry["properties"]["size_bytes"] == {
        "type": "integer",
        "minimum": 0,
        "maximum": 1_000_000_000,
    }

    valid_fixture_names = {"valid", "valid-year-zero"}
    fixture_names = {path.stem for path in FIXTURES.glob("*.json")}
    assert fixture_names == { *valid_fixture_names, *INVALID_FIXTURES }, fixture_names

    valid = load_json(FIXTURES / "valid.json")
    assert [item["role"] for item in valid["entries"]] == [
        "runner-log",
        "screenshot",
        "sanitized-json",
    ]
    run_fixtures(
        (
            FixtureSpec(name, FIXTURES / f"{name}.json", expected_valid=True)
            for name in valid_fixture_names
        ),
        validator_for=lambda _spec, _fixture: validator,
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
            for name, expected_validator in INVALID_FIXTURES.items()
        ),
        validator_for=lambda _spec, _fixture: validator,
    )

    print("testing-evidence-manifest-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
