#!/usr/bin/env python3
from __future__ import annotations

import json
import re
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker, ValidationError, validators


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas" / "testing-evidence-manifest.v1.schema.json"
FIXTURES = (
    ROOT
    / "packages"
    / "testing-runner"
    / "tests"
    / "fixtures"
    / "testing-evidence-manifest.v1"
)
INVALID_FIXTURES = {
    "invalid-empty-entries": "minItems",
    "invalid-malformed-artifact-ref": "not",
    "invalid-malformed-digest": "pattern",
    "invalid-malformed-timestamp": "pattern",
    "invalid-impossible-date": "format",
    "invalid-hyphen-time-separators": "pattern",
    "invalid-multibyte-over-byte-limit": "x-fkst-maxUtf8Bytes",
    "invalid-missing-required-field": "required",
    "invalid-overlong-evidence-id": "maxLength",
    "invalid-overlong-reference-kind": "maxLength",
    "invalid-role-media-mismatch": "oneOf",
    "invalid-size-bytes-fractional": "type",
    "invalid-size-bytes-negative": "minimum",
    "invalid-size-bytes-over-max": "maximum",
    "invalid-too-many-entries": "maxItems",
    "invalid-unknown-field": "additionalProperties",
    "invalid-unsupported-policy-status": "enum",
    "invalid-unsupported-role": "enum",
    "invalid-unsupported-sensitivity": "enum",
}


def load_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def utf8_max_bytes(validator, limit, instance, schema):
    if isinstance(instance, str) and len(instance.encode("utf-8")) > limit:
        yield ValidationError(f"UTF-8 value exceeds {limit} bytes")


EvidenceValidator = validators.extend(
    Draft202012Validator,
    {"x-fkst-maxUtf8Bytes": utf8_max_bytes},
)
FORMAT_CHECKER = FormatChecker()


@FORMAT_CHECKER.checks("date-time")
def strict_utc_timestamp(value: object) -> bool:
    if not isinstance(value, str):
        return True
    match = re.fullmatch(
        r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z",
        value,
    )
    if match is None:
        return False
    year, month, day, hour, minute, second = map(int, match.groups())
    leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
    days = (31, 29 if leap else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31)
    return (
        1 <= month <= 12
        and 1 <= day <= days[month - 1]
        and hour <= 23
        and minute <= 59
        and second <= 59
    )


def main() -> int:
    schema = load_json(SCHEMA)
    Draft202012Validator.check_schema(schema)
    validator = EvidenceValidator(schema, format_checker=FORMAT_CHECKER)

    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["$id"] == (
        "https://chronoaiproject.github.io/fkst-packages-testing/"
        "schemas/testing-evidence-manifest.v1.schema.json"
    )
    assert set(schema["properties"]) == set(schema["required"])
    assert len(schema["required"]) == 9

    entry = schema["$defs"]["entry"]
    assert set(entry["required"]) == set(entry["properties"]) - {"assertion_id"}
    assert entry["properties"]["size_bytes"] == {
        "type": "integer",
        "minimum": 0,
        "maximum": 1_000_000_000,
    }

    valid_fixture_names = {"valid", "valid-year-zero"}
    fixture_names = {path.stem for path in FIXTURES.glob("*.json")}
    assert fixture_names == { *valid_fixture_names, *INVALID_FIXTURES }, fixture_names

    valid = load_json(FIXTURES / "valid.json")
    assert [item["role"] for item in valid["entries"]] == [
        "runner-log",
        "screenshot",
        "sanitized-json",
    ]
    for name in valid_fixture_names:
        validator.validate(load_json(FIXTURES / f"{name}.json"))

    for name, expected_validator in INVALID_FIXTURES.items():
        fixture = load_json(FIXTURES / f"{name}.json")
        errors = list(validator.iter_errors(fixture))
        assert errors, f"schema accepted invalid shared fixture: {name}"
        validators = {error.validator for error in errors}
        assert expected_validator in validators, (
            name,
            expected_validator,
            sorted(str(value) for value in validators),
        )

    print("testing-evidence-manifest-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
