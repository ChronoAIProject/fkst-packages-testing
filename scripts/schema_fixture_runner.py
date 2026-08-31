from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path

from jsonschema import ValidationError

from json_schema_test_support import (
    assert_all_refs_resolve,
    load_json,
    offline_registry,
    validator_for_schema_file,
)


@dataclass(frozen=True)
class DeclaredCase:
    name: str
    file: str
    schema_path: Path
    portable_valid: bool
    instance_field: str | None = None
    expected_validator: str | None = None


@dataclass(frozen=True)
class IndexedFixtureSource:
    root: Path
    index_schema: str
    schema_path: Path
    instance_field: str
    wrapper_fields: frozenset[str]


@dataclass(frozen=True)
class DeclaredFixtureSource:
    root: Path
    cases: tuple[DeclaredCase, ...]


@dataclass(frozen=True)
class SchemaSuiteSpec:
    schemas: tuple[Path, ...]
    dependencies: tuple[Path, ...]
    fixtures: IndexedFixtureSource | DeclaredFixtureSource


@dataclass(frozen=True)
class CaseResult:
    name: str
    path: Path
    schema_path: Path
    fixture: Mapping[str, object]
    instance: object
    portable_valid: bool
    errors: tuple[ValidationError, ...]
    expected_validator: str | None
    validation_errors: Callable[[object], tuple[ValidationError, ...]]


def _mapping(path: Path) -> dict[str, object]:
    value = load_json(path)
    if not isinstance(value, dict):
        raise AssertionError(f"expected JSON object: {path}")
    return value


def _safe_path(root: Path, filename: str) -> Path:
    if not filename or Path(filename).is_absolute():
        raise AssertionError(f"fixture file must be a non-empty relative path: {filename!r}")
    root = root.resolve()
    path = (root / filename).resolve()
    try:
        path.relative_to(root)
    except ValueError as error:
        raise AssertionError(f"fixture path escapes its root: {filename!r}") from error
    if path == root or not path.is_file():
        raise AssertionError(f"fixture file does not exist: {filename!r}")
    return path


def _declared_cases(source: DeclaredFixtureSource) -> tuple[DeclaredCase, ...]:
    names = set()
    files = set()
    for case in source.cases:
        if not isinstance(case.name, str) or not case.name or case.name in names:
            raise AssertionError(f"declared case name must be non-empty and unique: {case.name!r}")
        if not isinstance(case.file, str) or not case.file or case.file in files:
            raise AssertionError(f"declared case file must be non-empty and unique: {case.file!r}")
        if not isinstance(case.portable_valid, bool):
            raise AssertionError(f"declared portable_valid must be Boolean: {case.name}")
        if case.instance_field is not None and not isinstance(case.instance_field, str):
            raise AssertionError(f"declared instance_field must be a string: {case.name}")
        if case.expected_validator is not None and not isinstance(case.expected_validator, str):
            raise AssertionError(f"declared expected_validator must be a string: {case.name}")
        names.add(case.name)
        files.add(case.file)
    return source.cases


def _indexed_cases(source: IndexedFixtureSource) -> tuple[DeclaredCase, ...]:
    index = _mapping(_safe_path(source.root, "index.json"))
    if set(index) != {"schema", "cases"}:
        raise AssertionError("fixture index must contain exactly 'schema' and 'cases'")
    if index["schema"] != source.index_schema:
        raise AssertionError(
            f"fixture index schema mismatch: expected {source.index_schema!r}"
        )
    entries = index["cases"]
    if not isinstance(entries, list):
        raise AssertionError("fixture index cases must be an array")
    cases = []
    names = set()
    files = set()
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"name", "file"}:
            raise AssertionError("fixture index case must contain exactly 'name' and 'file'")
        name = entry["name"]
        filename = entry["file"]
        if not isinstance(name, str) or not name or name in names:
            raise AssertionError(f"fixture case name must be non-empty and unique: {name!r}")
        if not isinstance(filename, str) or not filename or filename in files:
            raise AssertionError(
                f"fixture case file must be non-empty and unique: {filename!r}"
            )
        names.add(name)
        files.add(filename)
        path = _safe_path(source.root, filename)
        fixture = _mapping(path)
        if set(fixture) != set(source.wrapper_fields):
            raise AssertionError(f"fixture wrapper fields mismatch: {name}")
        if fixture.get("case") != name:
            raise AssertionError(f"fixture case does not match index: {name}")
        portable_valid = fixture.get("portable_valid")
        if not isinstance(portable_valid, bool):
            raise AssertionError(f"fixture portable_valid must be Boolean: {name}")
        cases.append(
            DeclaredCase(
                name=name,
                file=filename,
                schema_path=source.schema_path,
                portable_valid=portable_valid,
                instance_field=source.instance_field,
            )
        )
    return tuple(cases)


def run_schema_fixture_suite(
    spec: SchemaSuiteSpec,
    *,
    assert_schema: Callable[[Path, dict[str, object]], None] | None = None,
    assert_case: Callable[[CaseResult], None] | None = None,
) -> tuple[CaseResult, ...]:
    schema_paths = (*spec.schemas, *spec.dependencies)
    registry = offline_registry(schema_paths)
    validators = {}
    schemas = {}
    for path in schema_paths:
        schema, validator = validator_for_schema_file(path, registry=registry)
        assert_all_refs_resolve(schema, registry=registry)
        schemas[path] = schema
        validators[path] = validator

    if assert_schema is not None:
        for path in spec.schemas:
            assert_schema(path, schemas[path])

    source = spec.fixtures
    cases = (
        _indexed_cases(source)
        if isinstance(source, IndexedFixtureSource)
        else _declared_cases(source)
    )
    results = []
    for case in cases:
        path = _safe_path(source.root, case.file)
        fixture = _mapping(path)
        if "case" in fixture and fixture["case"] != case.name:
            raise AssertionError(f"fixture case does not match declaration: {case.name}")
        if "portable_valid" in fixture:
            if not isinstance(fixture["portable_valid"], bool):
                raise AssertionError(f"fixture portable_valid must be Boolean: {case.name}")
            if fixture["portable_valid"] is not case.portable_valid:
                raise AssertionError(f"fixture portable_valid does not match declaration: {case.name}")
        if case.instance_field is None:
            instance = fixture
        else:
            if case.instance_field not in fixture:
                raise AssertionError(
                    f"fixture is missing instance field {case.instance_field!r}: {case.name}"
                )
            instance = fixture[case.instance_field]
        validator = validators.get(case.schema_path)
        if validator is None:
            raise AssertionError(f"case schema is not registered: {case.schema_path}")

        def validation_errors(
            value: object, validator=validator
        ) -> tuple[ValidationError, ...]:
            return tuple(validator.iter_errors(value))

        errors = validation_errors(instance)
        if case.portable_valid and errors:
            raise AssertionError(
                f"expected valid fixture {case.name}: {[error.message for error in errors]}"
            )
        if not case.portable_valid and not errors:
            raise AssertionError(f"schema accepted invalid shared fixture: {case.name}")
        if case.expected_validator is not None:
            validators_seen = {str(error.validator) for error in errors}
            if case.expected_validator not in validators_seen:
                raise AssertionError(
                    f"fixture {case.name} expected validator {case.expected_validator!r}; "
                    f"saw {sorted(validators_seen)!r}"
                )
        result = CaseResult(
            name=case.name,
            path=path,
            schema_path=case.schema_path,
            fixture=fixture,
            instance=instance,
            portable_valid=case.portable_valid,
            errors=errors,
            expected_validator=case.expected_validator,
            validation_errors=validation_errors,
        )
        results.append(result)
        if assert_case is not None:
            assert_case(result)
    return tuple(results)
