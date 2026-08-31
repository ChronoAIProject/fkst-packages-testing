#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

from schema_fixture_runner import CaseResult, DeclaredCase, DeclaredFixtureSource, SchemaSuiteSpec, run_schema_fixture_suite

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas" / "testing-package-executor.request.v1.schema.json"
FIXTURES = ROOT / "packages" / "testing-runner" / "tests" / "fixtures" / "testing-package-executor.request.v1"
CASE_NAMES = (
    "contextual-unsupported-execution-profile", "contextual-unsupported-executor-mapping",
    "invalid-approved-refs-extra", "invalid-approved-refs-missing-policy", "invalid-capability-set-kind",
    "invalid-dedup-key-over-byte-limit", "invalid-digest-non-hex", "invalid-digest-short",
    "invalid-digest-uppercase", "invalid-execution-profile-empty", "invalid-executor-extra-field",
    "invalid-executor-missing-package-id", "invalid-forbidden-browser-fields",
    "invalid-forbidden-execution-fields", "invalid-forbidden-path-loader-fields",
    "invalid-forbidden-resolved-entrypoint", "invalid-forbidden-secret-fields",
    "invalid-forbidden-talos-fields", "invalid-identity-contract-major-control",
    "invalid-identity-entrypoint-empty", "invalid-identity-package-id-del",
    "invalid-identity-package-id-multibyte-over-byte-limit", "invalid-identity-package-id-non-string",
    "invalid-identity-package-id-over-byte-limit", "invalid-identity-schema",
    "invalid-package-manifest-kind", "invalid-plan-kind", "invalid-policy-kind",
    "invalid-pql-input-kind", "invalid-ref-control", "invalid-ref-del", "invalid-ref-empty",
    "invalid-ref-fragment", "invalid-ref-multibyte-over-byte-limit", "invalid-ref-mutable",
    "invalid-ref-over-byte-limit", "invalid-ref-query", "invalid-reference-extra-field",
    "invalid-reference-missing-sha256", "invalid-request-schema", "invalid-semver-prefixed",
    "invalid-semver-two-components", "invalid-source-kind", "invalid-top-level-missing-dedup-key",
    "invalid-top-level-unknown", "invalid-trace-id-del", "valid-complete",
)
CONTEXTUAL_CASES = {"contextual-unsupported-execution-profile", "contextual-unsupported-executor-mapping"}


def assert_schema(path: Path, schema: dict[str, object]) -> None:
    assert path == SCHEMA
    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["$id"] == "https://chronoaiproject.github.io/fkst-packages-testing/schemas/testing-package-executor.request.v1.schema.json"
    assert schema["additionalProperties"] is False
    assert set(schema["required"]) == set(schema["properties"])
    assert set(schema["properties"]) == {"schema", "executor", "execution_profile", "approved_input_refs", "trace_id", "dedup_key"}
    encoded_schema = json.dumps(schema, sort_keys=True)
    for resolver_literal in ("browser-deterministic.v1", "testing-runner.run", "testing-runner.v1"):
        assert resolver_literal not in encoded_schema


def assert_case(result: CaseResult) -> None:
    fixture = result.fixture
    assert isinstance(fixture["runtime_valid"], bool)
    assert isinstance(fixture["resolver_error"], str)
    assert isinstance(fixture["request"], dict)
    if not result.portable_valid:
        assert fixture["runtime_valid"] is False
        assert fixture["resolver_error"] == ""
    if result.portable_valid and fixture["resolver_error"]:
        assert fixture["runtime_valid"] is True


def main() -> int:
    results = run_schema_fixture_suite(
        SchemaSuiteSpec(
            schemas=(SCHEMA,), dependencies=(),
            fixtures=DeclaredFixtureSource(
                root=FIXTURES,
                cases=tuple(DeclaredCase(name, f"{name}.json", SCHEMA, not name.startswith("invalid-"), "request") for name in CASE_NAMES),
                required_fields=frozenset({"case", "portable_valid"}),
            ),
        ),
        assert_schema=assert_schema,
        assert_case=assert_case,
    )
    assert {result.name for result in results if result.portable_valid and result.fixture["resolver_error"]} == CONTEXTUAL_CASES
    print("testing-package-executor-request-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
