#!/usr/bin/env python3
from __future__ import annotations

import contextlib
import ast
import importlib
import io
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from jsonschema import Draft202012Validator, SchemaError

import json_schema_test_support as support
import schema_test_suite
from schema_fixture_runner import (
    DeclaredCase,
    DeclaredFixtureSource,
    IndexedFixtureSource,
    SchemaSuiteSpec,
    run_schema_fixture_suite,
)

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = ROOT / "schemas"

ADAPTERS = (
    "testing_package_manifest_test.py",
    "testing_evidence_manifest_schema_test.py",
    "testing_results_schema_test.py",
    "testing_browser_action_schema_test.py",
    "testing_package_executor_request_schema_test.py",
    "testing_runner_invocation_schema_test.py",
)
ADAPTER_OUTPUTS = (
    "testing-package-manifest: PASS\n",
    "testing-evidence-manifest-schema: PASS\n",
    "testing-results-schema: PASS\n",
    "testing-browser-action-schema: PASS\n",
    "testing-package-executor-request-schema: PASS\n",
    "testing-runner-invocation-schema: PASS\n",
)
BROWSER_CASES = (
    "contextual-unapproved-secret-ref", "contextual-unauthorized-action",
    "invalid-click-advisory-status", "invalid-click-secret-ref",
    "invalid-finish-advisory-status", "invalid-finish-handle",
    "invalid-finish-secret-ref", "invalid-forbidden-payload-fields",
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
EXECUTOR_CASES = (
    "contextual-unsupported-execution-profile", "contextual-unsupported-executor-mapping",
    "invalid-approved-refs-extra", "invalid-approved-refs-missing-policy",
    "invalid-capability-set-kind", "invalid-dedup-key-over-byte-limit", "invalid-digest-non-hex",
    "invalid-digest-short", "invalid-digest-uppercase", "invalid-execution-profile-empty",
    "invalid-executor-extra-field", "invalid-executor-missing-package-id",
    "invalid-forbidden-browser-fields", "invalid-forbidden-execution-fields",
    "invalid-forbidden-path-loader-fields", "invalid-forbidden-resolved-entrypoint",
    "invalid-forbidden-secret-fields", "invalid-forbidden-talos-fields",
    "invalid-identity-contract-major-control", "invalid-identity-entrypoint-empty",
    "invalid-identity-package-id-del", "invalid-identity-package-id-multibyte-over-byte-limit",
    "invalid-identity-package-id-non-string", "invalid-identity-package-id-over-byte-limit",
    "invalid-identity-schema", "invalid-package-manifest-kind", "invalid-plan-kind",
    "invalid-policy-kind", "invalid-pql-input-kind", "invalid-ref-control", "invalid-ref-del",
    "invalid-ref-empty", "invalid-ref-fragment", "invalid-ref-multibyte-over-byte-limit",
    "invalid-ref-mutable", "invalid-ref-over-byte-limit", "invalid-ref-query",
    "invalid-reference-extra-field", "invalid-reference-missing-sha256", "invalid-request-schema",
    "invalid-semver-prefixed", "invalid-semver-two-components", "invalid-source-kind",
    "invalid-top-level-missing-dedup-key", "invalid-top-level-unknown", "invalid-trace-id-del",
    "valid-complete",
)
RESULTS_SCHEMAS = (
    "testing-observation.v1.schema.json", "testing-assertion-result.v1.schema.json",
    "testing-case-result.v2.schema.json", "testing-case-result-set.v2.schema.json",
)
RESULTS_VALID = (
    "valid-observation", "valid-assertion", "valid-case-passed", "valid-case-failed",
    "valid-case-skipped", "valid-case-not-applicable", "valid-case-error", "valid-case-blocked",
    "valid-case-lost", "valid-case-year-zero", "valid-result-set",
)
RESULTS_INVALID = {
    "invalid-unknown-field": "additionalProperties", "invalid-missing-required-field": "required",
    "invalid-overlong-reference-kind": "x-fkst-maxUtf8Bytes", "invalid-malformed-digest": "pattern",
    "invalid-impossible-date": "format", "invalid-hyphen-time-separators": "pattern",
    "invalid-multibyte-over-byte-limit": "x-fkst-maxUtf8Bytes", "invalid-nested-multibyte-over-byte-limit": "format",
    "invalid-assertion-truth-table": "const", "invalid-case-outcome": "const",
    "invalid-case-error-rule": "not", "invalid-case-reason-rule": "not",
    "invalid-required-assertion": "contains", "invalid-set-digest-presence": "required",
    "invalid-duration-negative": "minimum", "invalid-duration-over-max": "maximum",
}
EVIDENCE_INVALID = {
    "invalid-empty-entries": "minItems", "invalid-malformed-artifact-ref": "not",
    "invalid-malformed-digest": "pattern", "invalid-malformed-timestamp": "pattern",
    "invalid-impossible-date": "format", "invalid-hyphen-time-separators": "pattern",
    "invalid-multibyte-over-byte-limit": "x-fkst-maxUtf8Bytes", "invalid-missing-required-field": "required",
    "invalid-overlong-evidence-id": "maxLength", "invalid-overlong-reference-kind": "maxLength",
    "invalid-role-media-mismatch": "oneOf", "invalid-size-bytes-fractional": "type",
    "invalid-size-bytes-negative": "minimum", "invalid-size-bytes-over-max": "maximum",
    "invalid-too-many-entries": "maxItems", "invalid-unknown-field": "additionalProperties",
    "invalid-unsupported-policy-status": "enum", "invalid-unsupported-role": "enum",
    "invalid-unsupported-sensitivity": "enum",
}


def errors(validator, value: object) -> list[object]:
    return list(validator.iter_errors(value))


def assert_fixture_outcomes(directory: Path, names: tuple[str, ...], validator, contextual: set[str] = set()) -> None:
    paths = sorted(directory.glob("*.json"))
    assert [path.stem for path in paths] == list(names)
    for path in paths:
        fixture = support.load_json(path)
        assert fixture["case"] == path.stem
        assert isinstance(fixture["portable_valid"], bool)
        assert isinstance(fixture["runtime_valid"], bool)
        assert not fixture["portable_valid"] == (path.stem.startswith("invalid-"))
        fixture_errors = errors(validator, fixture.get("action", fixture.get("request")))
        if fixture["portable_valid"]:
            assert not fixture_errors, (path.stem, fixture_errors)
        else:
            assert fixture_errors, path.stem
            assert fixture["runtime_valid"] is False


def test_support() -> None:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "value.json"
        path.write_text('{"text": "café"}', encoding="utf-8")
        assert support.load_json(path) == {"text": "café"}
        path.write_text("{", encoding="utf-8")
        try:
            support.load_json(path)
        except json.JSONDecodeError:
            pass
        else:
            raise AssertionError("malformed JSON did not raise json.JSONDecodeError")

    schema = {"type": "string"}
    try:
        support.validator_for_schema({"type": 7})
    except SchemaError:
        pass
    else:
        raise AssertionError("validator_for_schema did not check the schema first")

    marker = object()
    seen = {}
    original = support.JsonSchemaValidator

    def spy(value, **kwargs):
        seen["schema"] = value
        seen["kwargs"] = kwargs
        return marker

    support.JsonSchemaValidator = spy
    try:
        assert support.validator_for_schema(schema, resolver="resolver", registry="registry") is marker
    finally:
        support.JsonSchemaValidator = original
    assert seen == {"schema": schema, "kwargs": {"format_checker": support.FORMAT_CHECKER, "resolver": "resolver", "registry": "registry"}}

    byte_schema = {"type": "string", "x-fkst-maxUtf8Bytes": 4}
    byte_validator = support.validator_for_schema(byte_schema)
    assert byte_validator.is_valid("éé")
    assert not byte_validator.is_valid("ééé")
    for limit in (32, 64, 80, 96, 120, 180, 512, 4096):
        assert support.FORMAT_CHECKER.conforms("x" * limit, "fkst-utf8-max-" + str(limit))
        assert not support.FORMAT_CHECKER.conforms("x" * (limit + 1), "fkst-utf8-max-" + str(limit))
    assert support.FORMAT_CHECKER.conforms("2024-02-29T23:59:59Z", "date-time")
    assert not support.FORMAT_CHECKER.conforms("2023-02-29T00:00:00Z", "date-time")
    assert support.FORMAT_CHECKER.conforms("0000-01-01T00:00:00Z", "date-time")
    assert not support.FORMAT_CHECKER.conforms("2024-01-01T00:00:00.000Z", "date-time")
    assert not support.FORMAT_CHECKER.conforms("2024-01-01T24:00:00Z", "date-time")


def run_suite(arguments: list[str]) -> tuple[int, str, str]:
    old_argv = sys.argv
    sys.argv = [str(ROOT / "scripts/schema_test_suite.py"), *arguments]
    stdout, stderr = io.StringIO(), io.StringIO()
    try:
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            code = schema_test_suite.main()
    finally:
        sys.argv = old_argv
    return code, stdout.getvalue(), stderr.getvalue()


def test_aggregator() -> None:
    code, stdout, stderr = run_suite([])
    assert (code, stdout, stderr) == (0, "", "")
    adapter_paths = [str(ROOT / "scripts" / name) for name in ADAPTERS]
    code, stdout, stderr = run_suite(adapter_paths)
    assert (code, stdout, stderr) == (0, "".join(ADAPTER_OUTPUTS), "")

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        marker = root / "marker"
        first = root / "first.py"
        second = root / "second.py"
        returning = root / "returning.py"
        importing = root / "importing.py"
        first.write_text(f"from pathlib import Path\ndef main():\n    Path({str(marker)!r}).write_text('first-ran')\n    raise ValueError('first failure')\n")
        second.write_text(f"from pathlib import Path\ndef main():\n    Path({str(marker)!r}).write_text(Path({str(marker)!r}).read_text() + '|second-ran')\n    raise RuntimeError('second failure')\n")
        returning.write_text("def main():\n    return 7\n")
        importing.write_text("raise RuntimeError('import failure')\n")
        code, stdout, stderr = run_suite([str(first), str(second)])
        assert code == 1 and stdout == ""
        assert stderr == "first.py: first failure\nsecond.py: second failure\n"
        assert marker.read_text() == "first-ran|second-ran"
        assert run_suite([str(returning)]) == (
            1,
            "",
            "returning.py: adapter returned nonzero status: 7\n",
        )
        assert schema_test_suite.main([]) == 0
        try:
            run_suite([str(importing)])
        except RuntimeError as error:
            assert str(error) == "import failure"
        else:
            raise AssertionError("import-time adapter exception was aggregated")


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def test_runner() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        schemas = root / "schemas"
        fixtures = root / "fixtures"
        dependency = schemas / "defs.json"
        primary = schemas / "main.json"
        write_json(dependency, {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "https://example.test/schemas/defs.json",
            "$defs": {"positive": {"type": "integer", "minimum": 1}},
        })
        write_json(primary, {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "https://example.test/schemas/main.json",
            "type": "object",
            "required": ["value"],
            "properties": {"value": {"$ref": "defs.json#/$defs/positive"}},
            "$defs": {
                "absolute": {
                    "$ref": "https://example.test/schemas/defs.json#/$defs/positive"
                },
                "nested": {
                    "$id": "nested/branch.json",
                    "if": {"const": "unused"},
                    "then": {"$ref": "../defs.json#/$defs/positive"},
                }
            },
        })
        write_json(fixtures / "index.json", {
            "schema": "example-index.v1",
            "cases": [
                {"name": "first", "file": "first.json"},
                {"name": "second", "file": "second.json"},
            ],
        })
        write_json(fixtures / "first.json", {"case": "first", "portable_valid": True, "payload": {"value": 1}})
        write_json(fixtures / "second.json", {"case": "second", "portable_valid": False, "payload": {"value": 0}})
        callbacks = []
        results = run_schema_fixture_suite(
            SchemaSuiteSpec(
                schemas=(primary,), dependencies=(dependency,),
                fixtures=IndexedFixtureSource(
                    fixtures, "example-index.v1", primary, "payload",
                    frozenset({"case", "portable_valid", "payload"}),
                ),
            ),
            assert_schema=lambda path, schema: callbacks.append(("schema", path.name)),
            assert_case=lambda result: callbacks.append(("case", result.name)),
        )
        assert tuple(result.name for result in results) == ("first", "second")
        assert callbacks == [("schema", "main.json"), ("case", "first"), ("case", "second")]

        declared = run_schema_fixture_suite(
            SchemaSuiteSpec(
                schemas=(primary,), dependencies=(dependency,),
                fixtures=DeclaredFixtureSource(fixtures, (
                    DeclaredCase("second", "second.json", primary, False, "payload", "minimum"),
                    DeclaredCase("first", "first.json", primary, True, "payload"),
                )),
            )
        )
        assert tuple(result.name for result in declared) == ("second", "first")
        assert declared[0].expected_validator == "minimum"

        try:
            run_schema_fixture_suite(
                SchemaSuiteSpec(
                    schemas=(primary,), dependencies=(dependency,),
                    fixtures=DeclaredFixtureSource(fixtures, (
                        DeclaredCase("second", "second.json", primary, True, "payload"),
                    )),
                )
            )
        except AssertionError as error:
            assert "second" in str(error)
        else:
            raise AssertionError("flipped portable validity did not fail")

        unresolved = schemas / "unresolved.json"
        write_json(unresolved, {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "https://example.test/schemas/unresolved.json",
            "type": "object",
            "allOf": [{"if": {"const": 1}, "then": {"$ref": "https://example.test/missing.json"}}],
        })
        called = []
        try:
            run_schema_fixture_suite(
                SchemaSuiteSpec(
                    schemas=(unresolved,), dependencies=(),
                    fixtures=DeclaredFixtureSource(fixtures, (
                        DeclaredCase("first", "first.json", unresolved, True, "payload"),
                    )),
                ),
                assert_case=lambda result: called.append(result.name),
            )
        except AssertionError as error:
            assert "missing.json" in str(error)
        else:
            raise AssertionError("unused unresolved reference did not fail")
        assert called == []

        missing_id = schemas / "missing-id.json"
        duplicate_id = schemas / "duplicate-id.json"
        write_json(missing_id, {"type": "object"})
        write_json(duplicate_id, {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": "https://example.test/schemas/main.json",
            "type": "object",
        })
        for paths, expected in (((missing_id,), "missing"), ((primary, duplicate_id), "duplicate")):
            try:
                support.offline_registry(paths)
            except AssertionError as error:
                assert expected in str(error)
            else:
                raise AssertionError(f"{expected} $id was accepted")

        invalid_indexes = (
            {"schema": "wrong", "cases": []},
            {"schema": "example-index.v1", "cases": [], "extra": True},
            {"schema": "example-index.v1", "cases": [{"name": "first", "file": "first.json", "extra": True}]},
            {"schema": "example-index.v1", "cases": [{"name": "", "file": "first.json"}]},
            {"schema": "example-index.v1", "cases": [
                {"name": "first", "file": "first.json"},
                {"name": "first", "file": "second.json"},
            ]},
            {"schema": "example-index.v1", "cases": [{"name": "escape", "file": "../first.json"}]},
        )
        for index in invalid_indexes:
            write_json(fixtures / "index.json", index)
            try:
                run_schema_fixture_suite(
                    SchemaSuiteSpec(
                        schemas=(primary,), dependencies=(dependency,),
                        fixtures=IndexedFixtureSource(
                            fixtures, "example-index.v1", primary, "payload",
                            frozenset({"case", "portable_valid", "payload"}),
                        ),
                    )
                )
            except AssertionError:
                pass
            else:
                raise AssertionError(f"invalid index was accepted: {index!r}")

        write_json(fixtures / "index.json", {
            "schema": "example-index.v1",
            "cases": [{"name": "first", "file": "first.json"}],
        })
        invalid_fixtures = (
            {"case": "first", "portable_valid": True},
            {"case": "wrong", "portable_valid": True, "payload": {"value": 1}},
            {"case": "first", "portable_valid": "true", "payload": {"value": 1}},
            {"case": "first", "portable_valid": True, "payload": {"value": 1}, "extra": True},
        )
        for fixture in invalid_fixtures:
            write_json(fixtures / "first.json", fixture)
            try:
                run_schema_fixture_suite(
                    SchemaSuiteSpec(
                        schemas=(primary,), dependencies=(dependency,),
                        fixtures=IndexedFixtureSource(
                            fixtures, "example-index.v1", primary, "payload",
                            frozenset({"case", "portable_valid", "payload"}),
                        ),
                    )
                )
            except AssertionError:
                pass
            else:
                raise AssertionError(f"invalid fixture wrapper was accepted: {fixture!r}")


def test_adapter_ownership() -> None:
    forbidden_imports = {"RefResolver", "Registry", "Resource", "Draft202012Validator"}
    for name in ADAPTERS:
        tree = ast.parse((ROOT / "scripts" / name).read_text(encoding="utf-8"))
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                assert not forbidden_imports.intersection(alias.name for alias in node.names), name
            if isinstance(node, ast.Call):
                function = node.func
                if isinstance(function, ast.Name):
                    assert function.id not in forbidden_imports, (name, function.id)
                if isinstance(function, ast.Attribute):
                    assert function.attr not in {"glob", "iter_errors"}, (name, function.attr)


def test_adapters() -> None:
    expected = dict(zip(ADAPTERS, ADAPTER_OUTPUTS))
    for name, line in expected.items():
        module = importlib.import_module(Path(name).stem)
        stdout, stderr = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            assert module.main() == 0
        assert (stdout.getvalue(), stderr.getvalue()) == (line, "")
        result = subprocess.run(
            [sys.executable, "-S", "-B", "-W", "ignore::DeprecationWarning", str(ROOT / "scripts" / name)],
            cwd=ROOT, env=os.environ.copy(),
            text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        assert (result.returncode, result.stdout, result.stderr) == (0, line, "")

    browser_dir = ROOT / "packages/testing-runner/tests/fixtures/testing-browser-action.v1"
    browser_schema = support.load_json(SCHEMA_ROOT / "testing-runner.ai-browser-control.action.v1.schema.json")
    browser_validator = support.validator_for_schema(browser_schema)
    assert_fixture_outcomes(browser_dir, BROWSER_CASES, browser_validator)
    for path in sorted(browser_dir.glob("*.json")):
        fixture = support.load_json(path)
        assert isinstance(fixture["allowed_actions"], list)
        assert isinstance(fixture["approved_secret_refs"], list)
        assert isinstance(fixture["action"], dict)
    assert {p.stem for p in sorted(browser_dir.glob("*.json")) if (lambda f: f["portable_valid"] and not f["runtime_valid"])(support.load_json(p))} == {"contextual-unauthorized-action", "contextual-unapproved-secret-ref"}
    assert browser_schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert browser_schema["$id"] == "https://chronoaiproject.github.io/fkst-packages-testing/schemas/testing-runner.ai-browser-control.action.v1.schema.json"
    assert browser_schema["additionalProperties"] is False
    assert set(browser_schema["properties"]) == {"schema", "turn", "kind", "handle", "secret_ref", "advisory_status"}
    assert len(browser_schema["oneOf"]) == 5 and "x-fkst-canonicalization" not in browser_schema

    executor_dir = ROOT / "packages/testing-runner/tests/fixtures/testing-package-executor.request.v1"
    executor_schema = support.load_json(SCHEMA_ROOT / "testing-package-executor.request.v1.schema.json")
    executor_validator = support.validator_for_schema(executor_schema)
    assert_fixture_outcomes(executor_dir, EXECUTOR_CASES, executor_validator)
    for path in sorted(executor_dir.glob("*.json")):
        fixture = support.load_json(path)
        assert isinstance(fixture["resolver_error"], str) and isinstance(fixture["request"], dict)
    contextual = {p.stem for p in executor_dir.glob("*.json") if (lambda f: f["portable_valid"] and f["resolver_error"])(support.load_json(p))}
    assert contextual == {"contextual-unsupported-execution-profile", "contextual-unsupported-executor-mapping"}
    assert all(support.load_json(executor_dir / f"{n}.json")["resolver_error"] == "unsupported-mapping" for n in contextual)
    assert executor_schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert executor_schema["$id"] == "https://chronoaiproject.github.io/fkst-packages-testing/schemas/testing-package-executor.request.v1.schema.json"
    assert executor_schema["additionalProperties"] is False
    assert set(executor_schema["required"]) == set(executor_schema["properties"])
    assert set(executor_schema["properties"]) == {"schema", "executor", "execution_profile", "approved_input_refs", "trace_id", "dedup_key"}
    encoded = json.dumps(executor_schema, sort_keys=True)
    assert all(value not in encoded for value in ("browser-deterministic.v1", "testing-runner.run", "testing-runner.v1"))


def test_results_and_evidence() -> None:
    result_dir = ROOT / "packages/testing-runner/tests/fixtures/testing-results"
    schemas = {name: support.load_json(SCHEMA_ROOT / name) for name in RESULTS_SCHEMAS}
    for name, schema in schemas.items():
        support.validator_for_schema(schema)
        assert schema["$id"].endswith(name)
        assert schema["x-fkst-canonicalization"] == "fkst-testing-results-canonical-json.v1"
    registry = __import__("referencing").Registry()
    for name, schema in {**schemas, "testing-evidence-manifest.v1.schema.json": support.load_json(SCHEMA_ROOT / "testing-evidence-manifest.v1.schema.json")}.items():
        registry = registry.with_resource(schema["$id"], __import__("referencing").Resource.from_contents(schema))
    mapping = {"testing-observation.v1": RESULTS_SCHEMAS[0], "testing-assertion-result.v1": RESULTS_SCHEMAS[1], "testing-case-result.v2": RESULTS_SCHEMAS[2], "testing-case-result-set.v2": RESULTS_SCHEMAS[3]}
    for name in RESULTS_VALID:
        value = support.load_json(result_dir / f"{name}.json")
        support.validator_for_schema(schemas[mapping[value["schema"]]], registry=registry).validate(value)
    for name, expected in RESULTS_INVALID.items():
        value = support.load_json(result_dir / f"{name}.json")
        seen = {str(error.validator) for error in support.validator_for_schema(schemas[mapping[value["schema"]]], registry=registry).iter_errors(value)}
        assert expected in seen, (name, expected, seen)

    evidence_schema = support.load_json(SCHEMA_ROOT / "testing-evidence-manifest.v1.schema.json")
    support.validator_for_schema(evidence_schema)
    assert evidence_schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert evidence_schema["$id"] == "https://chronoaiproject.github.io/fkst-packages-testing/schemas/testing-evidence-manifest.v1.schema.json"
    assert set(evidence_schema["properties"]) == set(evidence_schema["required"]) and len(evidence_schema["required"]) == 9
    entry = evidence_schema["$defs"]["entry"]
    assert set(entry["required"]) == set(entry["properties"]) - {"assertion_id"}
    assert entry["properties"]["size_bytes"] == {"type": "integer", "minimum": 0, "maximum": 1_000_000_000}
    evidence_dir = ROOT / "packages/testing-runner/tests/fixtures/testing-evidence-manifest.v1"
    assert {p.stem for p in evidence_dir.glob("*.json")} == {"valid", "valid-year-zero", *EVIDENCE_INVALID}
    evidence_validator = support.validator_for_schema(evidence_schema)
    valid = support.load_json(evidence_dir / "valid.json")
    assert [entry["role"] for entry in valid["entries"]] == ["runner-log", "screenshot", "sanitized-json"]
    for name in ("valid", "valid-year-zero"):
        evidence_validator.validate(support.load_json(evidence_dir / f"{name}.json"))
    for name, expected in EVIDENCE_INVALID.items():
        seen = {str(error.validator) for error in evidence_validator.iter_errors(support.load_json(evidence_dir / f"{name}.json"))}
        assert expected in seen, (name, expected, seen)


def test_invocation_and_manifest() -> None:
    fixture_dir = ROOT / "packages/testing-runner/tests/fixtures/testing-runner-invocation.v1"
    index = support.load_json(fixture_dir / "index.json")
    assert index == {"schema": "testing-runner-invocation-fixture-index.v1", "cases": [{"name": "valid-canonical-envelope", "file": "valid-canonical-envelope.json"}]}
    fixture = support.load_json(fixture_dir / "valid-canonical-envelope.json")
    assert set(fixture) == {"case", "portable_valid", "lua_valid", "lua_error", "request"}
    assert fixture["case"] == "valid-canonical-envelope" and fixture["portable_valid"] is True and fixture["lua_valid"] is True and fixture["lua_error"] == ""
    schema = support.load_json(SCHEMA_ROOT / "testing-runner-invocation.v1.schema.json")
    assert schema["additionalProperties"] is False and set(schema["required"]) == set(schema["properties"])

    manifest_dir = ROOT / "packages/testing-runner/tests/fixtures/testing-package-manifest.v1"
    manifest_schema = support.load_json(SCHEMA_ROOT / "testing-package-manifest.v1.schema.json")
    Draft202012Validator.check_schema(manifest_schema)
    assert set(manifest_schema["properties"]) == set(manifest_schema["required"]) and len(manifest_schema["required"]) == 14
    manifest_validator = Draft202012Validator(manifest_schema)
    valid = support.load_json(manifest_dir / "valid.json")
    assert valid["package_id"] == "QA_RUNNER@V1"
    manifest_validator.validate(valid)
    invalid_names = ("invalid-package-id-u0000", "invalid-package-id-u001f", "invalid-package-id-slash", "invalid-package-id-backslash", "invalid-package-id-dot-dot", "invalid-unknown-top-level-field", "invalid-malformed-digest", "invalid-unsupported-major")
    for name in invalid_names:
        assert errors(manifest_validator, support.load_json(manifest_dir / f"{name}.json")), name
    for codepoint in range(0x20):
        mutated = dict(valid)
        mutated["package_id"] = f"QA{chr(codepoint)}RUNNER@V1"
        assert not manifest_validator.is_valid(mutated), codepoint


def main() -> int:
    test_support()
    test_aggregator()
    test_runner()
    test_adapter_ownership()
    test_adapters()
    test_results_and_evidence()
    test_invocation_and_manifest()
    print("schema-fixture-runner: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
