#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from schema_fixture_runner import CaseResult, DeclaredCase, DeclaredFixtureSource, SchemaSuiteSpec, run_schema_fixture_suite

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas" / "testing-runner.ai-browser-control.action.v1.schema.json"
FIXTURES = ROOT / "packages" / "testing-runner" / "tests" / "fixtures" / "testing-browser-action.v1"
CASE_NAMES = (
    "contextual-unapproved-secret-ref", "contextual-unauthorized-action",
    "invalid-click-advisory-status", "invalid-click-secret-ref", "invalid-finish-advisory-status",
    "invalid-finish-handle", "invalid-finish-secret-ref", "invalid-forbidden-payload-fields",
    "invalid-handle-control-character", "invalid-handle-del", "invalid-handle-empty",
    "invalid-handle-multibyte-over-byte-limit", "invalid-handle-over-byte-limit",
    "invalid-missing-kind-field", "invalid-missing-kind", "invalid-missing-schema",
    "invalid-missing-turn", "invalid-press-tab-advisory-status", "invalid-press-tab-handle",
    "invalid-press-tab-secret-ref", "invalid-secret-ref-malformed",
    "invalid-secret-ref-over-byte-limit", "invalid-submit-advisory-status",
    "invalid-submit-secret-ref", "invalid-turn-fractional", "invalid-turn-nine",
    "invalid-turn-zero", "invalid-type-advisory-status", "invalid-type-missing-handle",
    "invalid-type-missing-secret-ref", "invalid-unknown-field", "invalid-unknown-kind",
    "valid-click", "valid-finish-blocked", "valid-finish-success", "valid-press-tab",
    "valid-submit", "valid-type",
)


def assert_schema(path: Path, schema: dict[str, object]) -> None:
    assert path == SCHEMA
    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["$id"] == "https://chronoaiproject.github.io/fkst-packages-testing/schemas/testing-runner.ai-browser-control.action.v1.schema.json"
    assert schema["additionalProperties"] is False
    assert set(schema["properties"]) == {"schema", "turn", "kind", "handle", "secret_ref", "advisory_status"}
    assert len(schema["oneOf"]) == 5
    assert "x-fkst-canonicalization" not in schema


def assert_case(result: CaseResult) -> None:
    fixture = result.fixture
    assert isinstance(fixture["runtime_valid"], bool)
    assert isinstance(fixture["allowed_actions"], list)
    assert isinstance(fixture["approved_secret_refs"], list)
    assert isinstance(fixture["action"], dict)
    if not result.portable_valid:
        assert fixture["runtime_valid"] is False


def main() -> int:
    results = run_schema_fixture_suite(
        SchemaSuiteSpec(
            schemas=(SCHEMA,), dependencies=(),
            fixtures=DeclaredFixtureSource(
                root=FIXTURES,
                cases=tuple(DeclaredCase(name, f"{name}.json", SCHEMA, not name.startswith("invalid-"), "action") for name in CASE_NAMES),
            ),
        ),
        assert_schema=assert_schema,
        assert_case=assert_case,
    )
    assert {result.name for result in results if result.portable_valid and not result.fixture["runtime_valid"]} == {
        "contextual-unauthorized-action", "contextual-unapproved-secret-ref"
    }
    print("testing-browser-action-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
