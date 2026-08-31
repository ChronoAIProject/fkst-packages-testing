#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path

from schema_fixture_runner import CaseResult, IndexedFixtureSource, SchemaSuiteSpec, run_schema_fixture_suite

ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas/testing-runner-invocation.v1.schema.json"
DEPENDENCY = ROOT / "schemas/testing-package-executor.request.v1.schema.json"
FIXTURES = ROOT / "packages/testing-runner/tests/fixtures/testing-runner-invocation.v1"


def assert_schema(path: Path, schema: dict[str, object]) -> None:
    assert path == SCHEMA
    assert schema["additionalProperties"] is False
    assert set(schema["required"]) == set(schema["properties"])


def assert_case(result: CaseResult) -> None:
    fixture = result.fixture
    assert result.name == "valid-canonical-envelope"
    assert fixture["portable_valid"] is True
    assert fixture["lua_valid"] is True
    assert fixture["lua_error"] == ""


def main() -> int:
    results = run_schema_fixture_suite(
        SchemaSuiteSpec(
            schemas=(SCHEMA,), dependencies=(DEPENDENCY,),
            fixtures=IndexedFixtureSource(
                root=FIXTURES,
                index_schema="testing-runner-invocation-fixture-index.v1",
                schema_path=SCHEMA,
                instance_field="request",
                wrapper_fields=frozenset({"case", "portable_valid", "lua_valid", "lua_error", "request"}),
            ),
        ),
        assert_schema=assert_schema,
        assert_case=assert_case,
    )
    assert tuple(result.name for result in results) == ("valid-canonical-envelope",)
    print("testing-runner-invocation-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
