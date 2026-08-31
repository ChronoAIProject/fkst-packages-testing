from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Sequence
from urllib.parse import urljoin

from jsonschema import Draft202012Validator, FormatChecker, ValidationError, validators
from referencing import Registry, Resource
from referencing.exceptions import Unresolvable


def load_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def utf8_max_bytes(validator, limit, instance, schema):
    if isinstance(instance, str) and len(instance.encode("utf-8")) > limit:
        yield ValidationError(f"UTF-8 value exceeds {limit} bytes")


JsonSchemaValidator = validators.extend(
    Draft202012Validator,
    {"x-fkst-maxUtf8Bytes": utf8_max_bytes},
)
FORMAT_CHECKER = FormatChecker()


def register_utf8_format(limit: int) -> None:
    @FORMAT_CHECKER.checks(f"fkst-utf8-max-{limit}")
    def utf8_format(value: object) -> bool:
        return not isinstance(value, str) or len(value.encode("utf-8")) <= limit


for byte_limit in (32, 64, 80, 96, 120, 180, 512, 4096):
    register_utf8_format(byte_limit)


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


def validator_for_schema(schema: dict[str, object], **kwargs) -> JsonSchemaValidator:
    Draft202012Validator.check_schema(schema)
    return JsonSchemaValidator(schema, format_checker=FORMAT_CHECKER, **kwargs)


def offline_registry(schema_paths: Sequence[Path]) -> Registry:
    resources = []
    schema_ids = set()
    for path in schema_paths:
        schema = load_json(path)
        Draft202012Validator.check_schema(schema)
        schema_id = schema.get("$id")
        if not isinstance(schema_id, str) or not schema_id:
            raise AssertionError(f"schema is missing a non-empty $id: {path}")
        if schema_id in schema_ids:
            raise AssertionError(f"duplicate schema $id: {schema_id}")
        schema_ids.add(schema_id)
        resources.append((schema_id, Resource.from_contents(schema)))
    return Registry().with_resources(resources).crawl()


def assert_all_refs_resolve(
    schema: dict[str, object],
    *,
    registry: Registry,
) -> None:
    schema_id = schema.get("$id")
    if not isinstance(schema_id, str) or not schema_id:
        raise AssertionError("schema is missing a non-empty $id")

    def visit(value: object, base_uri: str) -> None:
        if isinstance(value, dict):
            nested_id = value.get("$id")
            if isinstance(nested_id, str):
                base_uri = urljoin(base_uri, nested_id)
            reference = value.get("$ref")
            if isinstance(reference, str):
                try:
                    registry.resolver(base_uri).lookup(reference)
                except Unresolvable as error:
                    raise AssertionError(
                        f"unresolved $ref {reference!r} from {base_uri!r}"
                    ) from error
            for child in value.values():
                visit(child, base_uri)
        elif isinstance(value, list):
            for child in value:
                visit(child, base_uri)

    visit(schema, schema_id)


def validator_for_schema_file(
    path: Path,
    *,
    registry: Registry,
) -> tuple[dict[str, object], JsonSchemaValidator]:
    schema = load_json(path)
    return schema, validator_for_schema(schema, registry=registry)
