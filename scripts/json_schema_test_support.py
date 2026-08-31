from __future__ import annotations

import json
import re
from pathlib import Path

from jsonschema import Draft202012Validator, FormatChecker, ValidationError, validators


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
