#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCHEMA_ROOT = ROOT / "schemas"
INDEX_ROOT = ROOT / "schema-fixtures" / "indexes"
GLOBAL_PATH = ROOT / "schema-fixtures" / "testing-schema-fixtures.v1.json"
RUNNER_FIXTURES = ROOT / "packages" / "testing-runner" / "tests" / "fixtures"
META_SCHEMA_BY_CASE = {
    "valid-fixtures": "testing-schema-fixtures.v1",
    "valid-fixture-set": "testing-schema-fixture-set.v1",
    "valid-catalog": "testing-schema-catalog.v1",
    "valid-release": "testing-package-schema-release.v1",
    "invalid-unknown-field": "testing-schema-fixtures.v1",
}
RESULT_SCHEMA_BY_CASE = {
    "valid-observation": "testing-observation.v1", "invalid-unknown-field": "testing-observation.v1",
    "invalid-overlong-reference-kind": "testing-observation.v1", "invalid-multibyte-over-byte-limit": "testing-observation.v1",
    "valid-assertion": "testing-assertion-result.v1", "invalid-missing-required-field": "testing-assertion-result.v1",
    "invalid-assertion-truth-table": "testing-assertion-result.v1", "valid-result-set": "testing-case-result-set.v2",
    "invalid-set-digest-presence": "testing-case-result-set.v2",
}


def schema_id(path: Path) -> str:
    return json.loads(path.read_text(encoding="utf-8"))["$id"]


def cases_for(root: Path, schema_name: str, instance_field: str | None) -> tuple[list[dict[str, object]], list[str]]:
    cases, support = [], []
    for path in sorted(root.glob("*.json"), key=lambda candidate: candidate.name.encode("utf-8")):
        value = json.loads(path.read_text(encoding="utf-8"))
        name = path.stem
        if path.name in {"index.json", "runtime-outcomes.json"} or (root.name == "testing-results" and name == "valid-result-set-evidence-manifest"):
            support.append(path.name)
            continue
        portable_valid = value.get("portable_valid") if isinstance(value, dict) else None
        if not isinstance(portable_valid, bool):
            portable_valid = name.startswith("valid-") or name == "valid"
        case_schema = RESULT_SCHEMA_BY_CASE.get(name, "testing-case-result.v2") if root.name == "testing-results" else (META_SCHEMA_BY_CASE.get(name, schema_name) if root.name == "publication-meta" else schema_name)
        cases.append({"name": value.get("case", name), "file": path.name, "schema": case_schema,
                      "instance_field": instance_field, "portable_valid": portable_valid})
    return cases, support


def build() -> dict[Path, object]:
    configurations = {
        "testing-package-manifest.v1": (RUNNER_FIXTURES / "testing-package-manifest.v1", None),
        "testing-evidence-manifest.v1": (RUNNER_FIXTURES / "testing-evidence-manifest.v1", None),
        "testing-observation.v1": (RUNNER_FIXTURES / "testing-results", None),
        "testing-assertion-result.v1": (RUNNER_FIXTURES / "testing-results", None),
        "testing-case-result.v2": (RUNNER_FIXTURES / "testing-results", None),
        "testing-case-result-set.v2": (RUNNER_FIXTURES / "testing-results", None),
        "testing-runner.ai-browser-control.action.v1": (RUNNER_FIXTURES / "testing-browser-action.v1", "action"),
        "testing-package-executor.request.v1": (RUNNER_FIXTURES / "testing-package-executor.request.v1", "request"),
        "testing-runner-invocation.v1": (RUNNER_FIXTURES / "testing-runner-invocation.v1", "request"),
        "testing-result-reason.v1": (ROOT / "schema-fixtures" / "testing-result-reason.v1", "reason"),
        "testing-schema-fixtures.v1": (ROOT / "schema-fixtures" / "publication-meta", "instance"),
        "testing-schema-fixture-set.v1": (ROOT / "schema-fixtures" / "publication-meta", "instance"),
        "testing-schema-catalog.v1": (ROOT / "schema-fixtures" / "publication-meta", "instance"),
        "testing-package-schema-release.v1": (ROOT / "schema-fixtures" / "publication-meta", "instance"),
    }
    outputs, global_entries, shared_indexes = {}, [], {}
    for name, (root, instance_field) in configurations.items():
        key = (root, instance_field)
        index_path = shared_indexes.get(key)
        if index_path is None:
            index_path = INDEX_ROOT / (root.name + ".json")
            cases, support = cases_for(root, name, instance_field)
            outputs[index_path] = {"schema": "testing-schema-fixture-index.v1", "cases": cases, "support_files": support}
            shared_indexes[key] = index_path
        schema_path = SCHEMA_ROOT / f"{name}.schema.json"
        global_entries.append({"schema_id": schema_id(schema_path), "schema_path": schema_path.relative_to(ROOT).as_posix(),
                               "fixture_root": root.relative_to(ROOT).as_posix(), "index_path": index_path.relative_to(ROOT).as_posix(),
                               "classification_path": None})
    global_entries.sort(key=lambda entry: entry["schema_id"].encode("utf-8"))
    outputs[GLOBAL_PATH] = {"schema": "testing-schema-fixtures.v1", "fixture_sets": global_entries}
    return outputs


def main() -> int:
    parser = argparse.ArgumentParser(); parser.add_argument("--check", action="store_true"); args = parser.parse_args()
    outputs = build()
    for path, value in outputs.items():
        expected = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
        if args.check:
            if not path.is_file() or path.read_text(encoding="utf-8") != expected:
                raise SystemExit(f"fixture metadata drift: {path.relative_to(ROOT)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text(expected, encoding="utf-8")
    print(f"testing-schema-fixtures: PASS ({len(outputs)} indexes)"); return 0


if __name__ == "__main__": raise SystemExit(main())
