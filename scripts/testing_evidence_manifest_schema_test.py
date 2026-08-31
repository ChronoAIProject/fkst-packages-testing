#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from schema_fixture_runner import CaseResult, DeclaredCase, DeclaredFixtureSource, SchemaSuiteSpec, run_schema_fixture_suite

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas" / "testing-evidence-manifest.v1.schema.json"
FIXTURES = ROOT / "packages" / "testing-runner" / "tests" / "fixtures" / "testing-evidence-manifest.v1"
INVALID_FIXTURES = {
    "invalid-empty-entries": "minItems", "invalid-malformed-artifact-ref": "not",
    "invalid-malformed-digest": "pattern", "invalid-malformed-timestamp": "pattern",
    "invalid-impossible-date": "format", "invalid-hyphen-time-separators": "pattern",
    "invalid-multibyte-over-byte-limit": "x-fkst-maxUtf8Bytes",
    "invalid-missing-required-field": "required", "invalid-overlong-evidence-id": "maxLength",
    "invalid-overlong-reference-kind": "maxLength", "invalid-role-media-mismatch": "oneOf",
    "invalid-size-bytes-fractional": "type", "invalid-size-bytes-negative": "minimum",
    "invalid-size-bytes-over-max": "maximum", "invalid-too-many-entries": "maxItems",
    "invalid-unknown-field": "additionalProperties", "invalid-unsupported-policy-status": "enum",
    "invalid-unsupported-role": "enum", "invalid-unsupported-sensitivity": "enum",
}


def assert_schema(path: Path, schema: dict[str, object]) -> None:
    assert path == SCHEMA
    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["$id"] == "https://chronoaiproject.github.io/fkst-packages-testing/schemas/testing-evidence-manifest.v1.schema.json"
    assert set(schema["properties"]) == set(schema["required"])
    assert len(schema["required"]) == 9
    entry = schema["$defs"]["entry"]
    assert set(entry["required"]) == set(entry["properties"]) - {"assertion_id"}
    assert entry["properties"]["size_bytes"] == {"type": "integer", "minimum": 0, "maximum": 1_000_000_000}


def assert_case(result: CaseResult) -> None:
    if result.name == "valid":
        assert [item["role"] for item in result.fixture["entries"]] == ["runner-log", "screenshot", "sanitized-json"]


def main() -> int:
    cases = (
        DeclaredCase("valid", "valid.json", SCHEMA, True),
        DeclaredCase("valid-year-zero", "valid-year-zero.json", SCHEMA, True),
        *(DeclaredCase(name, f"{name}.json", SCHEMA, False, expected_validator=validator) for name, validator in INVALID_FIXTURES.items()),
    )
    run_schema_fixture_suite(
        SchemaSuiteSpec(schemas=(SCHEMA,), dependencies=(), fixtures=DeclaredFixtureSource(FIXTURES, cases)),
        assert_schema=assert_schema,
        assert_case=assert_case,
    )
    print("testing-evidence-manifest-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
