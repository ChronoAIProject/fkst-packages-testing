#!/usr/bin/env python3
from __future__ import annotations

import json
import re
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker, ValidationError, validators
from referencing import Registry, Resource


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = ROOT / "schemas"
FIXTURES = ROOT / "packages" / "testing-runner" / "tests" / "fixtures" / "testing-results"

SCHEMA_NAMES = (
    "testing-observation.v1.schema.json",
    "testing-assertion-result.v1.schema.json",
    "testing-case-result.v2.schema.json",
    "testing-case-result-set.v2.schema.json",
)
VALID = (
    "valid-observation",
    "valid-assertion",
    "valid-case-passed",
    "valid-case-failed",
    "valid-case-skipped",
    "valid-case-not-applicable",
    "valid-case-error",
    "valid-case-blocked",
    "valid-case-lost",
    "valid-case-year-zero",
    "valid-result-set",
)
INVALID_VALIDATORS = {
    "invalid-unknown-field": "additionalProperties",
    "invalid-missing-required-field": "required",
    "invalid-overlong-reference-kind": "x-fkst-maxUtf8Bytes",
    "invalid-malformed-digest": "pattern",
    "invalid-impossible-date": "format",
    "invalid-hyphen-time-separators": "pattern",
    "invalid-multibyte-over-byte-limit": "x-fkst-maxUtf8Bytes",
    "invalid-nested-multibyte-over-byte-limit": "format",
    "invalid-assertion-truth-table": "const",
    "invalid-case-outcome": "const",
    "invalid-case-error-rule": "not",
    "invalid-case-reason-rule": "not",
    "invalid-required-assertion": "contains",
    "invalid-set-digest-presence": "required",
    "invalid-duration-negative": "minimum",
    "invalid-duration-over-max": "maximum",
}


def load(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def utf8_max_bytes(validator, limit, instance, schema):
    if isinstance(instance, str) and len(instance.encode("utf-8")) > limit:
        yield ValidationError(f"UTF-8 value exceeds {limit} bytes")


ResultsValidator = validators.extend(
    Draft202012Validator,
    {"x-fkst-maxUtf8Bytes": utf8_max_bytes},
)
FORMAT_CHECKER = FormatChecker()


def register_utf8_format(limit: int) -> None:
    @FORMAT_CHECKER.checks(f"fkst-utf8-max-{limit}")
    def utf8_format(value: object) -> bool:
        return not isinstance(value, str) or len(value.encode("utf-8")) <= limit


for byte_limit in (64, 96, 180, 512, 4096):
    register_utf8_format(byte_limit)


@FORMAT_CHECKER.checks("date-time")
def strict_utc_timestamp(value: object) -> bool:
    if not isinstance(value, str):
        return True
    match = re.fullmatch(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z", value)
    if match is None:
        return False
    year, month, day, hour, minute, second = map(int, match.groups())
    leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
    days = (31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    return 1 <= month <= 12 and 1 <= day <= days[month - 1] and hour <= 23 and minute <= 59 and second <= 59


def make_registry() -> Registry:
    registry = Registry()
    for name in (*SCHEMA_NAMES, "testing-evidence-manifest.v1.schema.json"):
        schema = load(SCHEMA_ROOT / name)
        registry = registry.with_resource(schema["$id"], Resource.from_contents(schema))
    return registry


def validator_for(name: str, registry: Registry) -> ResultsValidator:
    schema = load(SCHEMA_ROOT / name)
    Draft202012Validator.check_schema(schema)
    return ResultsValidator(schema, registry=registry, format_checker=FORMAT_CHECKER)


def validate_fixture(name: str, registry: Registry) -> None:
    value = load(FIXTURES / f"{name}.json")
    schema_name = {
        "testing-observation.v1": "testing-observation.v1.schema.json",
        "testing-assertion-result.v1": "testing-assertion-result.v1.schema.json",
        "testing-case-result.v2": "testing-case-result.v2.schema.json",
        "testing-case-result-set.v2": "testing-case-result-set.v2.schema.json",
    }[value["schema"]]
    validator_for(schema_name, registry).validate(value)


def main() -> int:
    registry = make_registry()
    for name in SCHEMA_NAMES:
        schema = load(SCHEMA_ROOT / name)
        Draft202012Validator.check_schema(schema)
        assert schema["$id"].endswith(name)
        assert schema["x-fkst-canonicalization"] == "fkst-testing-results-canonical-json.v1"

    for name in VALID:
        validate_fixture(name, registry)

    for name, expected_validator in INVALID_VALIDATORS.items():
        value = load(FIXTURES / f"{name}.json")
        schema_name = {
            "testing-observation.v1": "testing-observation.v1.schema.json",
            "testing-assertion-result.v1": "testing-assertion-result.v1.schema.json",
            "testing-case-result.v2": "testing-case-result.v2.schema.json",
            "testing-case-result-set.v2": "testing-case-result-set.v2.schema.json",
        }[value["schema"]]
        errors = list(validator_for(schema_name, registry).iter_errors(value))
        validators_seen = {str(error.validator) for error in errors}
        assert expected_validator in validators_seen, (
            name,
            expected_validator,
            sorted(validators_seen),
        )

    print("testing-results-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
