from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Callable, Iterable, Mapping

from jsonschema import ValidationError

from json_schema_test_support import load_json, validator_for_schema


@dataclass(frozen=True)
class FixtureSpec:
    name: str
    path: Path
    expected_valid: bool | None = None
    expected_validator: object | None = None


@dataclass(frozen=True)
class FixtureResult:
    spec: FixtureSpec
    fixture: Mapping[str, object]
    errors: tuple[ValidationError, ...]


def discover_fixtures(directory: Path) -> tuple[FixtureSpec, ...]:
    return tuple(
        FixtureSpec(path.stem, path)
        for path in sorted(directory.glob("*.json"))
    )


def load_schema_validator(
    path: Path,
    *,
    validator_factory: Callable[[dict[str, object]], object] = validator_for_schema,
) -> tuple[dict[str, object], object]:
    schema = load_json(path)
    return schema, validator_factory(schema)


def raise_first_error(
    _spec: FixtureSpec,
    errors: tuple[ValidationError, ...],
) -> None:
    raise errors[0]


def assert_no_errors_with_messages(
    spec: FixtureSpec,
    errors: tuple[ValidationError, ...],
) -> None:
    assert not errors, (spec.name, [error.message for error in errors])


def run_fixtures(
    specs: Iterable[FixtureSpec],
    *,
    validator_for: Callable[[FixtureSpec, dict[str, object]], object],
    instance_for: Callable[[FixtureSpec, dict[str, object]], object] = (
        lambda _spec, fixture: fixture
    ),
    expected_valid_for: Callable[[FixtureSpec, dict[str, object]], bool] = (
        lambda spec, _fixture: bool(spec.expected_valid)
    ),
    expected_validator_for: Callable[
        [FixtureSpec, dict[str, object]], object | None
    ] = lambda spec, _fixture: spec.expected_validator,
    validator_key: Callable[[ValidationError], object] = lambda error: error.validator,
    before_validate: Callable[[FixtureSpec, dict[str, object]], None] | None = None,
    after_validate: Callable[[FixtureResult], None] | None = None,
    valid_failure: Callable[
        [FixtureSpec, tuple[ValidationError, ...]], None
    ] | None = None,
) -> tuple[FixtureResult, ...]:
    results = []
    for spec in specs:
        fixture = load_json(spec.path)
        if before_validate is not None:
            before_validate(spec, fixture)
        validator = validator_for(spec, fixture)
        errors = tuple(validator.iter_errors(instance_for(spec, fixture)))
        if expected_valid_for(spec, fixture):
            if errors:
                if valid_failure is None:
                    assert not errors
                else:
                    valid_failure(spec, errors)
        else:
            assert errors, f"schema accepted invalid shared fixture: {spec.name}"

        expected_validator = expected_validator_for(spec, fixture)
        if expected_validator is not None:
            validators = {validator_key(error) for error in errors}
            assert expected_validator in validators, (
                spec.name,
                expected_validator,
                sorted(str(value) for value in validators),
            )

        result = FixtureResult(
            spec=spec,
            fixture=MappingProxyType(fixture),
            errors=errors,
        )
        if after_validate is not None:
            after_validate(result)
        results.append(result)
    return tuple(results)
