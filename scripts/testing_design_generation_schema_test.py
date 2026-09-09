#!/usr/bin/env python3
from __future__ import annotations

import copy
from pathlib import Path

from json_schema_test_support import load_json, offline_registry, validator_for_schema


ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = ROOT / "schemas-next-release"
FIXTURE_ROOT = ROOT / "packages/testing-design/tests/fixtures/generation/v1"


def assert_closed_objects(schema: object, location: str = "#") -> None:
    if isinstance(schema, dict):
        if schema.get("type") == "object" and schema.get("additionalProperties") is not False:
            raise AssertionError(f"object schema is not closed at {location}")
        for key, value in schema.items():
            assert_closed_objects(value, f"{location}/{key}")
    elif isinstance(schema, list):
        for index, value in enumerate(schema):
            assert_closed_objects(value, f"{location}/{index}")


def main() -> int:
    pairs = (
        ("testing-design.generate-request.v1", "valid-request.json"),
        ("testing-design.candidate-test-case-set.v1", "valid-candidate-set.json"),
        ("testing-design.generation-receipt.v1", "valid-receipt.json"),
    )
    schema_paths = tuple(SCHEMA_ROOT / f"{identity}.schema.json" for identity, _ in pairs)
    registry = offline_registry(schema_paths)
    validators = {}
    for identity, fixture_name in pairs:
        schema = load_json(SCHEMA_ROOT / f"{identity}.schema.json")
        assert schema["$id"] == f"https://chronoaiproject.github.io/fkst-packages-testing/schemas/{identity}.schema.json"
        assert_closed_objects(schema)
        validator = validator_for_schema(schema, registry=registry)
        validator.validate(load_json(FIXTURE_ROOT / fixture_name))
        validators[identity] = validator

    candidate_validator = validators["testing-design.candidate-test-case-set.v1"]
    for fixture_name in (
        "invalid-candidate-script.json",
        "invalid-candidate-set-status.json",
        "invalid-candidate-status.json",
    ):
        if candidate_validator.is_valid(load_json(FIXTURE_ROOT / fixture_name)):
            raise AssertionError(f"candidate fixture unexpectedly validated: {fixture_name}")

    receipt_validator = validators["testing-design.generation-receipt.v1"]
    for outcome in ("partial", "rejected", "budget-exhausted", "provider-error"):
        fixture_name = f"invalid-receipt-outcome-{outcome}.json"
        if receipt_validator.is_valid(load_json(FIXTURE_ROOT / fixture_name)):
            raise AssertionError(f"receipt fixture unexpectedly validated: {fixture_name}")

    candidate = load_json(FIXTURE_ROOT / "valid-candidate-set.json")
    nested_unknowns = (
        ("candidate", lambda value: value["candidates"][0].update({"unknown": True})),
        ("step", lambda value: value["candidates"][0]["steps"][0].update({"unknown": True})),
        ("target", lambda value: value["candidates"][0]["steps"][0]["action"]["target"].update({"unknown": True})),
        ("trace-reference", lambda value: value["candidates"][0]["traceability"]["source_refs"][0].update({"unknown": True})),
    )
    for name, mutate in nested_unknowns:
        invalid = copy.deepcopy(candidate)
        mutate(invalid)
        if candidate_validator.is_valid(invalid):
            raise AssertionError(f"unknown {name} field unexpectedly validated")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
