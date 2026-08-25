#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path

from jsonschema import Draft202012Validator, ValidationError, validators


ROOT = Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "schemas" / "testing-observation.v1.schema.json"
FIXTURES = (
    ROOT
    / "packages"
    / "testing-runner"
    / "tests"
    / "fixtures"
    / "testing-observation.v1"
)
INVALID_FIXTURES = {
    "invalid-control-character": "not",
    "invalid-empty-kind": "minLength",
    "invalid-empty-observation-id": "minLength",
    "invalid-empty-reference-ref": "minLength",
    "invalid-empty-value": "minLength",
    "invalid-evidence-refs-object": "type",
    "invalid-malformed-evidence-reference": "type",
    "invalid-malformed-source-reference": "required",
    "invalid-missing-required-field": "required",
    "invalid-multibyte-over-byte-limit": "x-fkst-maxUtf8Bytes",
    "invalid-non-hex-digest": "pattern",
    "invalid-overlong-kind": "maxLength",
    "invalid-overlong-observation-id": "maxLength",
    "invalid-overlong-reference-kind": "maxLength",
    "invalid-overlong-reference-ref": "maxLength",
    "invalid-overlong-value": "maxLength",
    "invalid-short-digest": "pattern",
    "invalid-too-many-evidence-references": "maxItems",
    "invalid-unknown-evidence-reference-field": "additionalProperties",
    "invalid-unknown-source-reference-field": "additionalProperties",
    "invalid-unknown-top-level-field": "additionalProperties",
    "invalid-unsupported-schema-major": "const",
    "invalid-unsupported-schema-name": "const",
    "invalid-uppercase-digest": "pattern",
}


def load_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def utf8_max_bytes(validator, limit, instance, schema):
    if isinstance(instance, str) and len(instance.encode("utf-8")) > limit:
        yield ValidationError(f"UTF-8 value exceeds {limit} bytes")


ObservationValidator = validators.extend(
    Draft202012Validator,
    {"x-fkst-maxUtf8Bytes": utf8_max_bytes},
)


def main() -> int:
    schema = load_json(SCHEMA)
    Draft202012Validator.check_schema(schema)
    validator = ObservationValidator(schema)

    assert schema["$schema"] == "https://json-schema.org/draft/2020-12/schema"
    assert schema["$id"] == (
        "https://chronoaiproject.github.io/fkst-packages-testing/"
        "schemas/testing-observation.v1.schema.json"
    )
    assert schema["additionalProperties"] is False
    assert set(schema["properties"]) == set(schema["required"])
    assert len(schema["required"]) == 7

    reference = schema["$defs"]["reference"]
    assert reference["additionalProperties"] is False
    assert set(reference["required"]) == {"kind", "ref"}
    assert set(reference["properties"]) == {"kind", "ref", "sha256"}

    valid_fixture_names = {"valid-with-digests", "valid-without-digests"}
    fixture_names = {path.stem for path in FIXTURES.glob("*.json")}
    assert fixture_names == {*valid_fixture_names, *INVALID_FIXTURES}, fixture_names

    for name in valid_fixture_names:
        validator.validate(load_json(FIXTURES / f"{name}.json"))

    for name, expected_validator in INVALID_FIXTURES.items():
        fixture = load_json(FIXTURES / f"{name}.json")
        errors = list(validator.iter_errors(fixture))
        assert errors, f"schema accepted invalid shared fixture: {name}"
        observed_validators = {error.validator for error in errors}
        assert expected_validator in observed_validators, (
            name,
            expected_validator,
            sorted(str(value) for value in observed_validators),
        )

    print("testing-observation-schema: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
