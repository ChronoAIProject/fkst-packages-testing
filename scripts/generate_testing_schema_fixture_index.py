#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
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
GENERATION_SCHEMA_NAMES = (
    "testing-design.generate-request.v1",
    "testing-design.candidate-test-case-set.v1",
    "testing-design.generation-receipt.v1",
)


@dataclass(frozen=True)
class FixtureConfiguration:
    root: Path
    instance_field: str | None = None
    classification_path: Path | None = None
    index_name: str | None = None


def schema_id(path: Path) -> str:
    return json.loads(path.read_text(encoding="utf-8"))["$id"]


def classified_cases(root: Path, classification_path: Path) -> tuple[list[dict[str, object]], list[str]]:
    classification = json.loads(classification_path.read_text(encoding="utf-8"))
    if not isinstance(classification, dict) or set(classification) != {"schema", "cases", "support_files"}:
        raise ValueError("fixture classification must have a closed root")
    if classification["schema"] != "testing-schema-fixture-classification.v1":
        raise ValueError("fixture classification schema is unsupported")
    cases = classification["cases"]
    support = classification["support_files"]
    if not isinstance(cases, list) or not isinstance(support, list):
        raise ValueError("fixture classification cases/support_files must be arrays")
    normalized = []
    listed = set()
    for case in cases:
        if not isinstance(case, dict) or set(case) != {"name", "file", "schema", "portable_valid"}:
            raise ValueError("fixture classification case is malformed")
        if not all(isinstance(case[field], str) and case[field] for field in ("name", "file", "schema")):
            raise ValueError("fixture classification case strings must be non-empty")
        if not isinstance(case["portable_valid"], bool):
            raise ValueError("fixture classification portable_valid must be boolean")
        if case["file"] in listed:
            raise ValueError(f"duplicate classified fixture: {case['file']}")
        listed.add(case["file"])
        document = json.loads((root / case["file"]).read_text(encoding="utf-8"))
        if not isinstance(document, dict) or document.get("schema") != case["schema"]:
            raise ValueError(f"fixture schema discriminator mismatch: {case['file']}")
        normalized.append({**case, "instance_field": None})
    if not all(isinstance(value, str) and value for value in support) or len(support) != len(set(support)):
        raise ValueError("fixture classification support_files must be unique non-empty strings")
    listed.update(support)
    actual = {path.name for path in root.glob("*.json") if path.is_file()}
    if listed != actual:
        raise ValueError(f"fixture classification inventory drift: unlisted={sorted(actual - listed)!r} missing={sorted(listed - actual)!r}")
    return normalized, support


def cases_for(root: Path, schema_name: str, instance_field: str | None, classification_path: Path | None = None) -> tuple[list[dict[str, object]], list[str]]:
    if classification_path is not None:
        return classified_cases(root, classification_path)
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


def default_configurations(repository_root: Path) -> dict[str, FixtureConfiguration]:
    runner_fixtures = repository_root / "packages" / "testing-runner" / "tests" / "fixtures"
    return {
        "testing-assertion-reducer-identity.v1": FixtureConfiguration(runner_fixtures / "testing-assertion-reducer-identity.v1"),
        "testing-package-manifest.v1": FixtureConfiguration(runner_fixtures / "testing-package-manifest.v1"),
        "testing-package-release.v1": FixtureConfiguration(runner_fixtures / "testing-package-release.v1"),
        "testing-evidence-manifest.v1": FixtureConfiguration(runner_fixtures / "testing-evidence-manifest.v1"),
        "testing-observation.v1": FixtureConfiguration(runner_fixtures / "testing-results"),
        "testing-assertion-result.v1": FixtureConfiguration(runner_fixtures / "testing-results"),
        "testing-case-result.v2": FixtureConfiguration(runner_fixtures / "testing-results"),
        "testing-case-result-set.v2": FixtureConfiguration(runner_fixtures / "testing-results"),
        "testing-runner.ai-browser-control.action.v1": FixtureConfiguration(runner_fixtures / "testing-browser-action.v1", "action"),
        "testing-package-executor.request.v1": FixtureConfiguration(runner_fixtures / "testing-package-executor.request.v1", "request"),
        "testing-runner-invocation.v1": FixtureConfiguration(runner_fixtures / "testing-runner-invocation.v1", "request"),
        "testing-result-reason.v1": FixtureConfiguration(repository_root / "schema-fixtures" / "testing-result-reason.v1", "reason"),
        "testing-result-authority-receipt.v1": FixtureConfiguration(runner_fixtures / "testing-result-authority-receipt.v1"),
        "testing-schema-fixtures.v1": FixtureConfiguration(repository_root / "schema-fixtures" / "publication-meta", "instance"),
        "testing-schema-fixture-set.v1": FixtureConfiguration(repository_root / "schema-fixtures" / "publication-meta", "instance"),
        "testing-schema-catalog.v1": FixtureConfiguration(repository_root / "schema-fixtures" / "publication-meta", "instance"),
        "testing-package-schema-release.v1": FixtureConfiguration(repository_root / "schema-fixtures" / "publication-meta", "instance"),
    }


def generation_configurations(fixture_root: Path, classification_path: Path) -> dict[str, FixtureConfiguration]:
    configuration = FixtureConfiguration(fixture_root, classification_path=classification_path, index_name="testing-design-generation.v1.json")
    return {name: configuration for name in GENERATION_SCHEMA_NAMES}


def repository_relative(path: Path, repository_root: Path) -> str:
    try:
        return path.resolve().relative_to(repository_root.resolve()).as_posix()
    except ValueError as error:
        raise ValueError(f"path escapes repository root: {path}") from error


def build(*, repository_root: Path = ROOT, schema_root: Path | None = None, index_root: Path | None = None,
          global_path: Path | None = None, configurations: dict[str, FixtureConfiguration] | None = None) -> dict[Path, object]:
    schema_root = schema_root or repository_root / "schemas"
    index_root = index_root or repository_root / "schema-fixtures" / "indexes"
    global_path = global_path or repository_root / "schema-fixtures" / "testing-schema-fixtures.v1.json"
    configurations = configurations or default_configurations(repository_root)
    outputs, global_entries, shared_indexes = {}, [], {}
    for name, configuration in configurations.items():
        key = (configuration.root, configuration.instance_field, configuration.classification_path)
        index_path = shared_indexes.get(key)
        if index_path is None:
            index_path = index_root / (configuration.index_name or (configuration.root.name + ".json"))
            cases, support = cases_for(configuration.root, name, configuration.instance_field, configuration.classification_path)
            outputs[index_path] = {"schema": "testing-schema-fixture-index.v1", "cases": cases, "support_files": support}
            shared_indexes[key] = index_path
        schema_path = schema_root / f"{name}.schema.json"
        global_entries.append({"schema_id": schema_id(schema_path), "schema_path": repository_relative(schema_path, repository_root),
                               "fixture_root": repository_relative(configuration.root, repository_root),
                               "index_path": repository_relative(index_path, repository_root),
                               "classification_path": None if configuration.classification_path is None else repository_relative(configuration.classification_path, repository_root)})
    global_entries.sort(key=lambda entry: entry["schema_id"].encode("utf-8"))
    outputs[global_path] = {"schema": "testing-schema-fixtures.v1", "fixture_sets": global_entries}
    return outputs


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--repository-root", type=Path, default=ROOT, help="repository-shaped input and output root")
    parser.add_argument("--generation-fixture-root", type=Path, help="shared generation fixture input directory")
    parser.add_argument("--generation-classification", type=Path, help="explicit generation fixture classification input")
    args = parser.parse_args()
    repository_root = args.repository_root.resolve()
    if (args.generation_fixture_root is None) != (args.generation_classification is None):
        parser.error("--generation-fixture-root and --generation-classification must be used together")
    configurations = default_configurations(repository_root)
    if args.generation_fixture_root is not None:
        configurations.update(generation_configurations(args.generation_fixture_root.resolve(), args.generation_classification.resolve()))
    outputs = build(repository_root=repository_root, configurations=configurations)
    for path, value in outputs.items():
        expected = json.dumps(value, ensure_ascii=False, indent=2) + "\n"
        if args.check:
            if not path.is_file() or path.read_text(encoding="utf-8") != expected:
                raise SystemExit(f"fixture metadata drift: {repository_relative(path, repository_root)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True); path.write_text(expected, encoding="utf-8")
    print(f"testing-schema-fixtures: PASS ({len(outputs)} indexes)"); return 0


if __name__ == "__main__": raise SystemExit(main())
