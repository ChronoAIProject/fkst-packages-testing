#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import generate_testing_schema_fixture_index as fixture_generator


ROOT = Path(__file__).resolve().parents[1]
SOURCE_COMMIT = "317cd38bd0e3f193e8732454063c6ae8f9c6ba1d"
GENERATION_SCHEMAS = fixture_generator.GENERATION_SCHEMA_NAMES
GENERATION_FIXTURES = Path("packages/testing-design/tests/fixtures/generation/v1")
CLASSIFICATION = Path("schema-fixtures/classifications/testing-design-generation.v1.json")
SNAPSHOT_PATHS = (
    Path("schemas"),
    Path("schema-fixtures"),
    Path("schema-release"),
    Path("package-release"),
    Path(".fkst/conformance/fkst-packages.pin"),
    Path(".fkst/substrate-ref"),
)


def bytes_by_path(root: Path, paths: tuple[Path, ...]) -> dict[str, tuple[bytes, str]]:
    snapshot = {}
    for relative in paths:
        path = root / relative
        candidates = (path,) if path.is_file() else tuple(candidate for candidate in path.rglob("*") if candidate.is_file())
        for candidate in candidates:
            data = candidate.read_bytes()
            snapshot[candidate.relative_to(root).as_posix()] = (data, hashlib.sha256(data).hexdigest())
    return snapshot


def copy_tree(source: Path, destination: Path) -> None:
    shutil.copytree(source, destination, dirs_exist_ok=True)


def prepare_stage(root: Path) -> None:
    copy_tree(ROOT / "schemas", root / "schemas")
    for schema_name in GENERATION_SCHEMAS:
        shutil.copy2(ROOT / "schemas-next-release" / f"{schema_name}.schema.json", root / "schemas" / f"{schema_name}.schema.json")
    copy_tree(ROOT / "packages/testing-runner/tests/fixtures", root / "packages/testing-runner/tests/fixtures")
    copy_tree(ROOT / "schema-fixtures/publication-meta", root / "schema-fixtures/publication-meta")
    copy_tree(ROOT / "schema-fixtures/testing-result-reason.v1", root / "schema-fixtures/testing-result-reason.v1")
    copy_tree(ROOT / GENERATION_FIXTURES, root / GENERATION_FIXTURES)
    (root / CLASSIFICATION).parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / CLASSIFICATION, root / CLASSIFICATION)
    (root / "schema-release").mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / "schema-release/testing-package-manifest.v1.json", root / "schema-release/testing-package-manifest.v1.json")


def pinned_value(path: Path) -> str:
    return next(line.strip() for line in reversed(path.read_text(encoding="ascii").splitlines()) if line.strip() and not line.startswith("#"))


def command(*arguments: str, success: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(arguments, cwd=ROOT, text=True, capture_output=True)
    assert (result.returncode == 0) is success, result.stdout + result.stderr
    return result


def generate_stage(root: Path) -> None:
    command(
        sys.executable, str(ROOT / "scripts/generate_testing_schema_fixture_index.py"),
        "--repository-root", str(root),
        "--generation-fixture-root", str(root / GENERATION_FIXTURES),
        "--generation-classification", str(root / CLASSIFICATION),
    )
    command(sys.executable, str(ROOT / "scripts/generate_testing_schema_catalog.py"), "--repository-root", str(root))
    seed_path = root / "test-signing-seed.base64"
    seed_path.write_text("AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=", encoding="ascii")
    command(
        sys.executable, str(ROOT / "scripts/generate_testing_package_release.py"),
        "--output-directory", str(root),
        "--schema-catalog", str(root / "schema-release/testing-schema-catalog.v1.json"),
        "--schema-release", str(root / "schema-release/testing-package-schema-release.v1.json"),
        "--seed-file", str(seed_path),
        "--source-commit", SOURCE_COMMIT,
        "--fkst-packages-commit", pinned_value(ROOT / ".fkst/conformance/fkst-packages.pin"),
        "--fkst-substrate-commit", pinned_value(ROOT / ".fkst/substrate-ref"),
        "--authority-issuer", "https://releases.chronoaiproject.org/fkst-packages-testing",
        "--authority-keyid", "testing-generation-schema-staging-v1",
        "--signature-profile", "dsse-ed25519.v1",
        "--valid-from", "2026-09-04T00:00:00Z",
        "--valid-until", "2027-09-04T00:00:00Z",
        "--revocation-authority", "https://releases.chronoaiproject.org/fkst-packages-testing/revocations/v1",
        "--release-sequence", "1",
    )


def generated_snapshot(root: Path) -> dict[str, tuple[bytes, str]]:
    return bytes_by_path(root, (Path("schema-fixtures"), Path("schema-release"), Path("package-release")))


def load(path: Path) -> dict[str, object]:
    value = json.loads(path.read_text(encoding="utf-8"))
    assert isinstance(value, dict)
    return value


def assert_generation_inventory(root: Path) -> None:
    fixture_index = load(root / "schema-fixtures/testing-schema-fixtures.v1.json")
    entries = fixture_index["fixture_sets"]
    assert isinstance(entries, list)
    generation_entries = [entry for entry in entries if Path(entry["schema_path"]).stem.removesuffix(".schema") in GENERATION_SCHEMAS]
    assert len(generation_entries) == 3
    assert {entry["fixture_root"] for entry in generation_entries} == {GENERATION_FIXTURES.as_posix()}
    assert {entry["classification_path"] for entry in generation_entries} == {CLASSIFICATION.as_posix()}
    assert not any("testing-package-tool-catalog" in entry["schema_path"] for entry in entries)
    index = load(root / generation_entries[0]["index_path"])
    assert index["support_files"] == ["boundary-matrix.json", "rejection-cases.json"]
    cases = index["cases"]
    assert isinstance(cases, list) and len(cases) == 10
    assert {case["schema"] for case in cases} == set(GENERATION_SCHEMAS)
    assert next(case for case in cases if case["file"] == "invalid-candidate-script.json")["portable_valid"] is False
    fixture_set = load(root / "schema-release/fixture-sets/testing-design.generate-request.v1.json")
    bound_paths = {record["path"] for record in fixture_set["files"]}
    assert (root / CLASSIFICATION).relative_to(root).as_posix() in bound_paths
    assert {str(GENERATION_FIXTURES / name) for name in index["support_files"]}.issubset(bound_paths)
    package_release = load(root / "package-release/testing-package-release.v1.json")
    assert package_release["schema_catalog"]["path"] == "schema-release/testing-schema-catalog.v1.json"
    assert package_release["schema_release"]["path"] == "schema-release/testing-package-schema-release.v1.json"


def downstream_digests(root: Path) -> tuple[str, str, str, str]:
    catalog = load(root / "schema-release/testing-schema-catalog.v1.json")
    schema_release = load(root / "schema-release/testing-package-schema-release.v1.json")
    package_release = load(root / "package-release/testing-package-release.v1.json")
    generation = next(entry for entry in catalog["schemas"] if entry["schema_id"].endswith("/testing-design.generate-request.v1.schema.json"))
    return (
        generation["fixture_set_sha256"],
        catalog["catalog_sha256"],
        schema_release["release_sha256"],
        package_release["schema_release"]["sha256"],
    )


def assert_mutation_propagates(relative: Path, baseline: tuple[str, str, str, str]) -> None:
    with tempfile.TemporaryDirectory(prefix="testing-generation-schema-mutation-") as directory:
        root = Path(directory)
        prepare_stage(root)
        path = root / relative
        path.write_bytes(path.read_bytes() + b" ")
        generate_stage(root)
        assert downstream_digests(root) != baseline


def assert_rejections() -> None:
    with tempfile.TemporaryDirectory(prefix="testing-generation-schema-rejections-") as directory:
        root = Path(directory)
        prepare_stage(root)
        classification_path = root / CLASSIFICATION
        classification_path.write_text("{", encoding="utf-8")
        command(sys.executable, str(ROOT / "scripts/generate_testing_schema_fixture_index.py"), "--repository-root", str(root), "--generation-fixture-root", str(root / GENERATION_FIXTURES), "--generation-classification", str(classification_path), success=False)
    with tempfile.TemporaryDirectory(prefix="testing-generation-schema-rejections-") as directory:
        root = Path(directory)
        prepare_stage(root)
        (root / GENERATION_FIXTURES / "valid-request.json").unlink()
        command(sys.executable, str(ROOT / "scripts/generate_testing_schema_fixture_index.py"), "--repository-root", str(root), "--generation-fixture-root", str(root / GENERATION_FIXTURES), "--generation-classification", str(root / CLASSIFICATION), success=False)
    with tempfile.TemporaryDirectory(prefix="testing-generation-schema-rejections-") as directory:
        root = Path(directory)
        prepare_stage(root)
        classification = load(root / CLASSIFICATION)
        classification["cases"].append(classification["cases"][0])
        (root / CLASSIFICATION).write_text(json.dumps(classification), encoding="utf-8")
        command(sys.executable, str(ROOT / "scripts/generate_testing_schema_fixture_index.py"), "--repository-root", str(root), "--generation-fixture-root", str(root / GENERATION_FIXTURES), "--generation-classification", str(root / CLASSIFICATION), success=False)
    with tempfile.TemporaryDirectory(prefix="testing-generation-schema-rejections-") as directory:
        root = Path(directory)
        prepare_stage(root)
        classification = load(root / CLASSIFICATION)
        classification["cases"][0]["schema"] = "testing-design.unknown.v1"
        fixture_path = root / GENERATION_FIXTURES / classification["cases"][0]["file"]
        fixture = load(fixture_path)
        fixture["schema"] = "testing-design.unknown.v1"
        fixture_path.write_text(json.dumps(fixture), encoding="utf-8")
        (root / CLASSIFICATION).write_text(json.dumps(classification), encoding="utf-8")
        result = command(sys.executable, str(ROOT / "scripts/generate_testing_schema_fixture_index.py"), "--repository-root", str(root), "--generation-fixture-root", str(root / GENERATION_FIXTURES), "--generation-classification", str(root / CLASSIFICATION), success=False)
        assert "fixture classification schema is not configured: testing-design.unknown.v1" in result.stderr
    with tempfile.TemporaryDirectory(prefix="testing-generation-schema-containment-") as directory:
        root = Path(directory)
        prepare_stage(root)
        outside = root.parent / f"{root.name}-classification.json"
        shutil.copy2(root / CLASSIFICATION, outside)
        configurations = fixture_generator.default_configurations(root)
        configurations.update(fixture_generator.generation_configurations(root / GENERATION_FIXTURES, outside))
        try:
            fixture_generator.build(repository_root=root, configurations=configurations)
        except ValueError as error:
            assert "escapes repository root" in str(error)
        else:
            raise AssertionError("classification path outside the staging root was accepted")
        outside.unlink()


def main() -> int:
    committed_before = bytes_by_path(ROOT, SNAPSHOT_PATHS)
    subprocess.run(["git", "cat-file", "-e", f"{SOURCE_COMMIT}^{{commit}}"], cwd=ROOT, check=True)
    with tempfile.TemporaryDirectory(prefix="testing-generation-schema-stage-a-") as first_directory, tempfile.TemporaryDirectory(prefix="testing-generation-schema-stage-b-") as second_directory:
        first = Path(first_directory)
        second = Path(second_directory)
        prepare_stage(first)
        prepare_stage(second)
        generate_stage(first)
        generate_stage(second)
        assert_generation_inventory(first)
        assert generated_snapshot(first) == generated_snapshot(second)
        baseline = downstream_digests(first)
    assert_mutation_propagates(Path("schemas/testing-design.generate-request.v1.schema.json"), baseline)
    assert_mutation_propagates(GENERATION_FIXTURES / "valid-request.json", baseline)
    assert_mutation_propagates(GENERATION_FIXTURES / "boundary-matrix.json", baseline)
    assert_rejections()
    assert bytes_by_path(ROOT, SNAPSHOT_PATHS) == committed_before
    for command_arguments in (
        (sys.executable, str(ROOT / "scripts/generate_testing_schema_fixture_index.py"), "--check"),
        (sys.executable, str(ROOT / "scripts/generate_testing_schema_catalog.py"), "--check"),
    ):
        command(*command_arguments)
    print("testing-generation-schema-staging: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
