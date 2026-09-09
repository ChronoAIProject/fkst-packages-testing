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


def apply_case(document: object, case: dict[str, object]) -> object:
    current = document
    path = case["path"]
    assert isinstance(path, list) and path
    for segment in path[:-1]:
        current = current[segment]  # type: ignore[index]
    leaf = path[-1]
    if case["operation"] == "remove":
        del current[leaf]  # type: ignore[index]
    else:
        current[leaf] = case["value"]  # type: ignore[index]
    return document


def object_locations(schema: dict[str, object], instance: object, path: tuple[object, ...] = ()):
    if schema.get("type") == "object" and isinstance(instance, dict):
        yield path, schema
        properties = schema.get("properties", {})
        assert isinstance(properties, dict)
        for key, child_schema in properties.items():
            if key in instance and isinstance(child_schema, dict):
                yield from object_locations(child_schema, instance[key], (*path, key))
    elif schema.get("type") == "array" and isinstance(instance, list) and instance:
        items = schema.get("items")
        if isinstance(items, dict):
            yield from object_locations(items, instance[0], (*path, 0))


def at_path(document: object, path: tuple[object, ...]) -> object:
    current = document
    for segment in path:
        current = current[segment]  # type: ignore[index]
    return current


def main() -> int:
    pairs = (
        ("testing-design.generate-request.v1", "valid-request.json"),
        ("testing-design.candidate-test-case-set.v1", "valid-candidate-set.json"),
        ("testing-design.generation-receipt.v1", "valid-receipt.json"),
    )
    schema_paths = tuple(SCHEMA_ROOT / f"{identity}.schema.json" for identity, _ in pairs)
    registry = offline_registry(schema_paths)
    validators = {}
    documents = {}
    schemas = {}
    for identity, fixture_name in pairs:
        schema = load_json(SCHEMA_ROOT / f"{identity}.schema.json")
        assert schema["$id"] == f"https://chronoaiproject.github.io/fkst-packages-testing/schemas/{identity}.schema.json"
        assert_closed_objects(schema)
        validator = validator_for_schema(schema, registry=registry)
        document = load_json(FIXTURE_ROOT / fixture_name)
        validator.validate(document)
        validators[identity] = validator
        documents[identity] = document
        schemas[identity] = schema

    for identity, document in documents.items():
        validator = validators[identity]
        for path, object_schema in object_locations(schemas[identity], document):
            unknown = copy.deepcopy(document)
            at_path(unknown, path)["unknown"] = True  # type: ignore[index]
            if validator.is_valid(unknown):
                raise AssertionError(f"unknown field unexpectedly validated at {identity}{path!r}")
            for field in object_schema.get("required", []):
                missing = copy.deepcopy(document)
                del at_path(missing, path)[field]  # type: ignore[index]
                if validator.is_valid(missing):
                    raise AssertionError(f"missing field unexpectedly validated at {identity}{path!r}/{field}")

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

    identity_by_document = {
        "request": "testing-design.generate-request.v1",
        "candidate_set": "testing-design.candidate-test-case-set.v1",
        "receipt": "testing-design.generation-receipt.v1",
    }
    corpus = load_json(FIXTURE_ROOT / "rejection-cases.json")
    for case in corpus["cases"]:
        identity = identity_by_document[case["document"]]
        mutated = apply_case(copy.deepcopy(documents[identity]), case)
        actual = validators[identity].is_valid(mutated)
        if actual is not case["schema_valid"]:
            raise AssertionError(f"shared case {case['name']!r} validity was {actual}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
