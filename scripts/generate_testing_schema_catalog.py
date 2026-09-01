#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

from schema_artifact_policy import DRAFT, validate_schema_file


ROOT = Path(__file__).resolve().parents[1]
FIXTURE_INDEX = ROOT / "schema-fixtures" / "testing-schema-fixtures.v1.json"
RELEASE_ROOT = ROOT / "schema-release"
FIXTURE_SET_ROOT = RELEASE_ROOT / "fixture-sets"
CATALOG_PATH = RELEASE_ROOT / "testing-schema-catalog.v1.json"
CATALOG_DIGEST_PATH = RELEASE_ROOT / "testing-schema-catalog.v1.sha256"
PACKAGE_MANIFEST_PATH = RELEASE_ROOT / "testing-package-manifest.v1.json"
RELEASE_PATH = RELEASE_ROOT / "testing-package-schema-release.v1.json"
VERSION = re.compile(r"\.v([1-9][0-9]*)\.schema\.json$")


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def persisted(value: object) -> bytes:
    return canonical(value) + b"\n"


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def load_object(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"unable to load {path.relative_to(ROOT)}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path.relative_to(ROOT)}")
    return value


def safe_repository_path(value: object, field: str, *, directory: bool = False) -> Path:
    if not isinstance(value, str) or not value or value.startswith("/"):
        raise ValueError(f"{field} must be a non-empty repository-relative path")
    relative = Path(value)
    if relative.as_posix() != value or ".." in relative.parts or "." in relative.parts:
        raise ValueError(f"{field} must be normalized and repository-contained")
    path = (ROOT / relative).resolve()
    try:
        path.relative_to(ROOT.resolve())
    except ValueError as error:
        raise ValueError(f"{field} escapes the repository") from error
    if directory and not path.is_dir():
        raise ValueError(f"{field} is not a directory: {value}")
    if not directory and not path.is_file():
        raise ValueError(f"{field} is not a regular file: {value}")
    return path


def fixture_entries() -> list[dict[str, object]]:
    document = load_object(FIXTURE_INDEX)
    if set(document) != {"schema", "fixture_sets"} or document["schema"] != "testing-schema-fixtures.v1":
        raise ValueError("global fixture index has the wrong closed root")
    entries = document["fixture_sets"]
    if not isinstance(entries, list) or not entries:
        raise ValueError("global fixture index must declare fixture sets")
    if any(not isinstance(entry, dict) for entry in entries):
        raise ValueError("global fixture entries must be objects")
    schema_ids = [entry.get("schema_id") for entry in entries]
    if schema_ids != sorted(schema_ids, key=lambda value: str(value).encode("utf-8")):
        raise ValueError("global fixture entries must be sorted by schema_id bytes")
    if len(schema_ids) != len(set(schema_ids)):
        raise ValueError("global fixture schema IDs must be unique")
    return entries


def fixture_manifest(entry: dict[str, object]) -> tuple[str, dict[str, object]]:
    schema_id = entry.get("schema_id")
    if not isinstance(schema_id, str):
        raise ValueError("fixture schema_id must be a string")
    root = safe_repository_path(entry.get("fixture_root"), "fixture_root", directory=True)
    index_path = safe_repository_path(entry.get("index_path"), "index_path")
    classification_value = entry.get("classification_path")
    classification_path = None if classification_value is None else safe_repository_path(classification_value, "classification_path")
    index = load_object(index_path)
    cases = index.get("cases")
    support_files = index.get("support_files", [])
    if not isinstance(cases, list) or not isinstance(support_files, list):
        raise ValueError(f"fixture index must declare cases/support_files: {index_path.relative_to(ROOT)}")
    listed = set()
    for case in cases:
        if not isinstance(case, dict) or not isinstance(case.get("file"), str):
            raise ValueError(f"fixture index case is malformed: {index_path.relative_to(ROOT)}")
        listed.add(case["file"])
    if not all(isinstance(value, str) for value in support_files):
        raise ValueError(f"fixture support_files must be strings: {index_path.relative_to(ROOT)}")
    listed.update(support_files)
    actual = {path.relative_to(root).as_posix() for path in root.rglob("*.json") if path.is_file()}
    if listed != actual:
        raise ValueError(
            f"fixture inventory drift for {schema_id}: unlisted={sorted(actual - listed)!r} missing={sorted(listed - actual)!r}"
        )
    files = {index_path}
    files.update(root / relative for relative in listed)
    if classification_path is not None:
        files.add(classification_path)
    records = []
    for path in sorted(files, key=lambda candidate: candidate.relative_to(ROOT).as_posix().encode("utf-8")):
        data = path.read_bytes()
        records.append({"path": path.relative_to(ROOT).as_posix(), "sha256": sha256(data), "size_bytes": len(data)})
    value = {"schema": "testing-schema-fixture-set.v1", "schema_id": schema_id, "files": records}
    value["fixture_set_sha256"] = sha256(canonical(value))
    filename = Path(str(entry["schema_path"])).name.removesuffix(".schema.json") + ".json"
    return filename, value


def build() -> dict[Path, bytes]:
    entries = fixture_entries()
    by_id = {entry["schema_id"]: entry for entry in entries}
    schemas = []
    outputs: dict[Path, bytes] = {}
    for path in sorted((ROOT / "schemas").glob("*.schema.json"), key=lambda candidate: candidate.name.encode("utf-8")):
        schema = validate_schema_file(path)
        schema_id = schema.get("$id")
        if not isinstance(schema_id, str) or not schema_id:
            raise ValueError(f"schema is missing $id: {path.relative_to(ROOT)}")
        if schema.get("$schema") != DRAFT:
            raise ValueError(f"schema draft mismatch: {path.relative_to(ROOT)}")
        entry = by_id.pop(schema_id, None)
        if entry is None:
            raise ValueError(f"schema has no fixture set: {schema_id}")
        expected_path = path.relative_to(ROOT).as_posix()
        if entry.get("schema_path") != expected_path:
            raise ValueError(f"fixture schema path mismatch: {schema_id}")
        fixture_filename, fixture_value = fixture_manifest(entry)
        fixture_path = FIXTURE_SET_ROOT / fixture_filename
        outputs[fixture_path] = persisted(fixture_value)
        match = VERSION.search(path.name)
        if match is None:
            raise ValueError(f"schema filename has no unambiguous contract major: {path.name}")
        schemas.append({
            "schema_id": schema_id,
            "path": expected_path,
            "draft": DRAFT,
            "canonicalization_profile": schema.get("x-fkst-canonicalization"),
            "schema_sha256": sha256(path.read_bytes()),
            "contract_major": int(match.group(1)),
            "status": "stable",
            "fixture_set_path": fixture_path.relative_to(ROOT).as_posix(),
            "fixture_set_sha256": fixture_value["fixture_set_sha256"],
        })
    if by_id:
        raise ValueError(f"fixture index contains unknown schema IDs: {sorted(by_id)}")
    schemas.sort(key=lambda entry: entry["schema_id"].encode("utf-8"))
    catalog = {"schema": "testing-schema-catalog.v1", "canonicalization": "fkst-testing-schema-catalog-canonical-json.v1", "schemas": schemas}
    catalog["catalog_sha256"] = sha256(canonical(catalog))
    catalog_bytes = persisted(catalog)
    outputs[CATALOG_PATH] = catalog_bytes
    outputs[CATALOG_DIGEST_PATH] = f"{sha256(catalog_bytes)}  {CATALOG_PATH.name}\n".encode()
    package_manifest_bytes = PACKAGE_MANIFEST_PATH.read_bytes()
    release = {
        "schema": "testing-package-schema-release.v1",
        "canonicalization": "fkst-testing-package-schema-release-canonical-json.v1",
        "package_manifest": {
            "kind": "testing-package-manifest",
            "ref": "immutable://fkst-packages-testing/1.0.0/testing-package-manifest.v1.json",
            "sha256": sha256(package_manifest_bytes),
        },
        "schema_catalog": {
            "kind": "testing-schema-catalog",
            "ref": "immutable://fkst-packages-testing/1.0.0/testing-schema-catalog.v1.json",
            "sha256": sha256(catalog_bytes),
        },
        "producer": {"name": "fkst-packages-testing", "version": "1.0.0"},
    }
    release["release_sha256"] = sha256(canonical(release))
    outputs[RELEASE_PATH] = persisted(release)
    return outputs


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    outputs = build()
    if args.check:
        for path, expected in outputs.items():
            if not path.is_file() or path.read_bytes() != expected:
                raise SystemExit(f"generated schema release drift: {path.relative_to(ROOT)}")
        actual = {path for path in FIXTURE_SET_ROOT.glob("*.json") if path.is_file()}
        expected = {path for path in outputs if path.parent == FIXTURE_SET_ROOT}
        if actual != expected:
            raise SystemExit("generated fixture-set artifact inventory drift")
    else:
        for path, data in outputs.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    print(f"testing-schema-catalog: PASS ({len(outputs)} artifacts)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
