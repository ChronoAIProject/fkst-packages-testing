#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from schema_fixture_runner import DeclaredCase, DeclaredFixtureSource, SchemaSuiteSpec, run_schema_fixture_suite

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = ROOT / "schemas"
FIXTURES = ROOT / "packages" / "testing-runner" / "tests" / "fixtures" / "testing-results"
SCHEMAS = {
    "testing-observation.v1": SCHEMA_ROOT / "testing-observation.v1.schema.json",
    "testing-assertion-result.v1": SCHEMA_ROOT / "testing-assertion-result.v1.schema.json",
    "testing-case-result.v2": SCHEMA_ROOT / "testing-case-result.v2.schema.json",
    "testing-case-result-set.v2": SCHEMA_ROOT / "testing-case-result-set.v2.schema.json",
}
DEPENDENCY = SCHEMA_ROOT / "testing-evidence-manifest.v1.schema.json"
VALID_CASES = {
    "valid-observation": "testing-observation.v1",
    "valid-assertion": "testing-assertion-result.v1",
    "valid-case-passed": "testing-case-result.v2",
    "valid-case-failed": "testing-case-result.v2",
    "valid-case-skipped": "testing-case-result.v2",
    "valid-case-not-applicable": "testing-case-result.v2",
    "valid-case-error": "testing-case-result.v2",
    "valid-case-blocked": "testing-case-result.v2",
    "valid-case-lost": "testing-case-result.v2",
    "valid-case-year-zero": "testing-case-result.v2",
    "valid-result-set": "testing-case-result-set.v2",
}
INVALID_CASES = {
    "invalid-unknown-field": ("testing-observation.v1", "additionalProperties"),
    "invalid-missing-required-field": ("testing-assertion-result.v1", "required"),
    "invalid-overlong-reference-kind": ("testing-observation.v1", "x-fkst-maxUtf8Bytes"),
    "invalid-malformed-digest": ("testing-case-result.v2", "pattern"),
    "invalid-impossible-date": ("testing-case-result.v2", "format"),
    "invalid-hyphen-time-separators": ("testing-case-result.v2", "pattern"),
    "invalid-multibyte-over-byte-limit": ("testing-observation.v1", "x-fkst-maxUtf8Bytes"),
    "invalid-nested-multibyte-over-byte-limit": ("testing-case-result.v2", "format"),
    "invalid-assertion-truth-table": ("testing-assertion-result.v1", "const"),
    "invalid-case-outcome": ("testing-case-result.v2", "const"),
    "invalid-case-error-rule": ("testing-case-result.v2", "not"),
    "invalid-case-reason-rule": ("testing-case-result.v2", "not"),
    "invalid-required-assertion": ("testing-case-result.v2", "contains"),
    "invalid-set-digest-presence": ("testing-case-result-set.v2", "required"),
    "invalid-duration-negative": ("testing-case-result.v2", "minimum"),
    "invalid-duration-over-max": ("testing-case-result.v2", "maximum"),
}


def assert_schema(path: Path, schema: dict[str, object]) -> None:
    assert schema["$id"].endswith(path.name)
    assert schema["x-fkst-canonicalization"] == "fkst-testing-results-canonical-json.v1"


def main() -> int:
    cases = tuple(
        DeclaredCase(name, f"{name}.json", SCHEMAS[schema_name], True)
        for name, schema_name in VALID_CASES.items()
    ) + tuple(
        DeclaredCase(name, f"{name}.json", SCHEMAS[schema_name], False, expected_validator=validator)
        for name, (schema_name, validator) in INVALID_CASES.items()
    )
    run_schema_fixture_suite(
        SchemaSuiteSpec(
            schemas=tuple(SCHEMAS.values()),
            dependencies=(DEPENDENCY,),
            fixtures=DeclaredFixtureSource(FIXTURES, cases),
        ),
        assert_schema=assert_schema,
    )
    print("testing-results-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
