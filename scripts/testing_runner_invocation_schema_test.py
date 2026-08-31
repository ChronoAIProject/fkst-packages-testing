#!/usr/bin/env python3
from __future__ import annotations

import json
import tempfile
from pathlib import Path

from schema_fixture_runner import CaseResult, IndexedFixtureSource, SchemaSuiteSpec, run_schema_fixture_suite

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas/testing-runner-invocation.v1.schema.json"
DEPENDENCY = ROOT / "schemas/testing-package-executor.request.v1.schema.json"
FIXTURES = ROOT / "packages/testing-runner/tests/fixtures/testing-runner-invocation.v1"
RUNTIME_OUTCOMES = FIXTURES / "runtime-outcomes.json"
WRAPPER_FIELDS = frozenset({"case", "portable_valid", "lua_valid", "lua_error", "request"})
REQUIRED_ROOT_FIELDS = (
    "schema", "canonicalization", "invocation_id", "qa_run_ref", "attempt_ref",
    "executor", "resolved_executor", "execution_profile", "approved_input_refs",
    "requested_capabilities", "budgets", "deadline_epoch_seconds", "producer",
    "trace_id", "dedup_key", "canonical_request_sha256",
)
RUNTIME_REASONS = (
    "mapping-ambiguous", "mapping-missing", "unsupported-execution-profile",
    "unsupported-mapping", "capability-mismatch", "policy-mismatch",
    "lineage-mismatch", "lineage-rebuilt", "lineage-substituted", "stale-plan",
    "deadline-expired", "cancelled", "current-claim-unavailable",
    "current-claim-superseded", "replay-conflict",
)


def fixture_source(schema_path: Path = SCHEMA) -> IndexedFixtureSource:
    return IndexedFixtureSource(
        root=FIXTURES,
        index_schema="testing-runner-invocation-fixture-index.v1",
        schema_path=schema_path,
        instance_field="request",
        wrapper_fields=WRAPPER_FIELDS,
        excluded_files=("runtime-outcomes.json",),
    )


def assert_schema(path: Path, schema: dict[str, object]) -> None:
    assert path == SCHEMA
    assert schema["additionalProperties"] is False
    assert tuple(schema["required"]) == REQUIRED_ROOT_FIELDS
    assert tuple(schema["properties"]) == REQUIRED_ROOT_FIELDS


def assert_case(result: CaseResult) -> None:
    fixture = result.fixture
    assert isinstance(fixture["lua_valid"], bool)
    assert isinstance(fixture["lua_error"], str)
    if fixture["lua_valid"]:
        assert fixture["lua_error"] == ""
    else:
        assert fixture["lua_error"] != ""
    if result.name == "valid-canonical-envelope":
        assert fixture["request"]["canonical_request_sha256"] == (
            "e307a583193b235addb17935725e3c52fa125860b4f3fa340431b6e6d43e9066"
        )


def assert_runtime_outcomes(results: tuple[CaseResult, ...]) -> None:
    sidecar = json.loads(RUNTIME_OUTCOMES.read_text(encoding="utf-8"))
    assert set(sidecar) == {"schema", "cases"}
    assert sidecar["schema"] == "testing-runner-invocation-runtime-outcomes.v1"
    cases = sidecar["cases"]
    assert isinstance(cases, list)
    assert all(isinstance(case, dict) and set(case) == {"name", "runtime_reason"} for case in cases)
    assert tuple(case["runtime_reason"] for case in cases) == RUNTIME_REASONS
    assert tuple(case["name"] for case in cases) == tuple(
        f"runtime-{reason}" for reason in RUNTIME_REASONS
    )
    by_name = {result.name: result for result in results}
    assert len(by_name) == len(results)
    for case in cases:
        fixture = by_name[case["name"]].fixture
        assert fixture["portable_valid"] is True
        assert fixture["lua_valid"] is True
        assert fixture["lua_error"] == ""


def assert_preflight_failure(spec: SchemaSuiteSpec) -> None:
    callback_calls = 0

    def callback(*_: object) -> None:
        nonlocal callback_calls
        callback_calls += 1

    try:
        run_schema_fixture_suite(spec, assert_schema=callback, assert_case=callback)
    except Exception:
        assert callback_calls == 0
    else:
        raise AssertionError("invalid offline schema bundle passed preflight")


def assert_offline_preflight() -> None:
    assert_preflight_failure(
        SchemaSuiteSpec(schemas=(SCHEMA,), dependencies=(), fixtures=fixture_source())
    )
    with tempfile.TemporaryDirectory() as directory:
        temporary = Path(directory)
        schema_path = temporary / SCHEMA.name
        dependency_path = temporary / DEPENDENCY.name
        schema = json.loads(SCHEMA.read_text(encoding="utf-8"))
        schema["properties"]["invocation_id"] = {"$ref": "./missing.schema.json"}
        schema_path.write_text(json.dumps(schema), encoding="utf-8")
        dependency_path.write_bytes(DEPENDENCY.read_bytes())
        assert_preflight_failure(
            SchemaSuiteSpec(
                schemas=(schema_path,),
                dependencies=(dependency_path,),
                fixtures=fixture_source(schema_path),
            )
        )


def main() -> int:
    results = run_schema_fixture_suite(
        SchemaSuiteSpec(
            schemas=(SCHEMA,),
            dependencies=(DEPENDENCY,),
            fixtures=fixture_source(),
        ),
        assert_schema=assert_schema,
        assert_case=assert_case,
    )
    assert_runtime_outcomes(results)
    assert_offline_preflight()
    print("testing-runner-invocation-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
