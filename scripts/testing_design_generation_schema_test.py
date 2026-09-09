#!/usr/bin/env python3
from __future__ import annotations

import copy
import json

from jsonschema import ValidationError
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


def seeded_document(document: object) -> object:
    document = copy.deepcopy(document)
    if document["schema"] == "testing-design.candidate-test-case-set.v1":
        trace = document["candidates"][0]["traceability"]
        for key in ("journey_refs", "risk_refs"):
            trace[key] = copy.deepcopy(trace["requirement_refs"])
        trace["existing_test_refs"] = [{
            "kind": "artifact", "ref": ".testing/runs/design/existing-test-inventory.v1.json",
            "sha256": "d" * 64,
        }]
    elif document["schema"] == "testing-design.generation-receipt.v1":
        document["rejected_candidates"] = {"total": 1, "reasons": [{"code": "duplicate-candidate", "count": 1}]}
    return document


def string_samples(spec, controls):
    prefix, maximum = spec.get("prefix", ""), spec["max"]
    yield spec.get("minimum", prefix + "x"), True
    yield prefix + "x" * (maximum - len(prefix)), True
    yield "", False
    yield prefix + "x" * (maximum + 1 - len(prefix)), False
    yield prefix + "界" * ((maximum - len(prefix)) // 3 + 1), False
    if not spec.get("ascii_only"):
        count, remainder = divmod(maximum - len(prefix), 3)
        yield prefix + "界" * count + "x" * remainder, True
    for control in controls:
        for value in (chr(control) + prefix + "x", prefix + "x" + chr(control) + "x", prefix + "x" + chr(control)):
            yield value, False


def fixed_string_samples(spec, controls):
    yield ""
    for code in controls:
        control, value = chr(code), spec["value"]
        yield control + value
        yield value[:1] + control + value[1:]
        yield value + control
    if spec.get("hex"):
        for value in ("a" * (spec["hex"] - 1), "a" * (spec["hex"] + 1), "A" * spec["hex"], "g" * spec["hex"]):
            yield value


def scalar_value(sample):
    return "".join(chr(code) for code in sample["codepoints"])


def check_utf8_owner(matrix):
    for schema in ({"x-fkst-maxUtf8Bytes": 4}, {"format": "fkst-utf8-max-32"}):
        validator = validator_for_schema(schema)
        for sample in matrix["unicode_scalars"]:
            value = scalar_value(sample)
            errors = list(validator.iter_errors(value))
            assert (not errors) is sample["valid"], sample
            assert all(isinstance(error, ValidationError) for error in errors)
            assert validator.is_valid(value) is sample["valid"], sample
        assert validator.is_valid(json.loads('"\\ud83d\\ude00"'))
    assert not validator_for_schema({"x-fkst-maxUtf8Bytes": 3}).is_valid("😀")
    print("generation UTF-8 owner: 17 representative cases passed")


def boundary_documents(matrix, documents, identities):
    for spec in matrix["strings"]:
        identity = identities[spec["document"]]
        for sample in matrix["unicode_scalars"]:
            value = spec.get("prefix", "") + scalar_value(sample)
            document = seeded_document(documents[identity])
            apply_case(document, {"path": spec["path"], "operation": "set", "value": value})
            yield identity, document, sample["valid"] and not spec.get("ascii_only", False), f"scalar {spec['path']} {sample['codepoints']}"
    for spec in matrix["formats"]:
        identity = identities[spec["document"]]
        for sample in spec["values"]:
            document = seeded_document(documents[identity])
            apply_case(document, {"path": spec["path"], "operation": "set", "value": sample["value"]})
            yield identity, document, sample["valid"], f"format {spec['path']} {sample['value']!r}"
    for spec in matrix["fixed_strings"]:
        identity = identities[spec["document"]]
        for index, value in enumerate(fixed_string_samples(spec, matrix["controls"])):
            document = seeded_document(documents[identity])
            apply_case(document, {"path": spec["path"], "operation": "set", "value": value})
            yield identity, document, False, f"fixed string {spec['path']} sample {index}"
    for spec in matrix["strings"]:
        identity = identities[spec["document"]]
        for index, (value, valid) in enumerate(string_samples(spec, matrix["controls"])):
            document = seeded_document(documents[identity])
            apply_case(document, {"path": spec["path"], "operation": "set", "value": value})
            yield identity, document, valid, f"string {spec['path']} sample {index}"
    for spec in matrix["integers"]:
        identity = identities[spec["document"]]
        for value, valid in ((spec["min"], True), (spec["max"], True), (spec["min"] - 1, False),
                             (spec["max"] + 1, bool(spec.get("schema_unbounded"))), (1.5, False), ("1", False), (True, False)):
            document = seeded_document(documents[identity])
            apply_case(document, {"path": spec["path"], "operation": "set", "value": value})
            yield identity, document, valid, f"integer {spec['path']} {value!r}"
    for spec in matrix["unsafe"]:
        identity = identities[spec["document"]]
        for value in spec["values"]:
            document = seeded_document(documents[identity])
            apply_case(document, {"path": spec["path"], "operation": "set", "value": value})
            yield identity, document, False, f"unsafe {spec['path']} {value!r}"
    identity = identities["candidate_set"]
    for spec in matrix["arrays"]:
        for size in (0, 1, spec["maximum"], spec["maximum"] + 1):
            document = seeded_document(documents[identity])
            item = at_path(document, tuple(spec["path"]))[0]
            values = [copy.deepcopy(item) for _ in range(size)]
            apply_case(document, {"path": spec["path"], "operation": "set", "value": values})
            yield identity, document, 1 <= size <= spec["maximum"], f"array {spec['path']} size {size}"


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

    for identity, base in documents.items():
        document = seeded_document(base)
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
    matrix = load_json(FIXTURE_ROOT / "boundary-matrix.json")
    check_utf8_owner(matrix)
    count = 0
    for identity, document, expected, label in boundary_documents(matrix, documents, identity_by_document):
        assert validators[identity].is_valid(document) is expected, label
        count += 1
    print(f"generation boundary matrix: {count} shared cases passed")
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
