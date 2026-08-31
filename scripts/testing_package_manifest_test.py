#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

import generate_testing_package_manifest as generator
from schema_fixture_runner import CaseResult, DeclaredCase, DeclaredFixtureSource, SchemaSuiteSpec, run_schema_fixture_suite


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "scripts" / "fixtures" / "testing-package-manifest.v1"
SCHEMA = ROOT / "schemas" / "testing-package-manifest.v1.schema.json"
SHARED_FIXTURES = (
    ROOT
    / "packages"
    / "testing-runner"
    / "tests"
    / "fixtures"
    / "testing-package-manifest.v1"
)
INVALID_SHARED_FIXTURES = (
    "invalid-package-id-u0000",
    "invalid-package-id-u001f",
    "invalid-package-id-slash",
    "invalid-package-id-backslash",
    "invalid-package-id-dot-dot",
    "invalid-unknown-top-level-field",
    "invalid-malformed-digest",
    "invalid-unsupported-major",
)


def base_arguments(root: Path, output: Path) -> list[str]:
    return [
        sys.executable,
        str(ROOT / "scripts" / "generate_testing_package_manifest.py"),
        "--package-root", str(root), "--output", str(output),
        "--package-id", "testing-runner", "--package-version", "1.0.0",
        "--source-commit", "0123456789abcdef0123456789abcdef01234567",
        "--entrypoint", "testing-runner.run", "--entrypoint-contract-major", "testing-runner.v1",
        "--contract-major", "testing-runner.v1",
        "--canonicalization-profile", generator.CANONICALIZATION, "--capability", "semantic-runner",
        "--platform", "linux-amd64", "--lua-runtime", "5.4.0",
        "--fkst-packages-commit", "abcdef0123456789abcdef0123456789abcdef01",
        "--fkst-substrate-commit", "fedcba9876543210fedcba9876543210fedcba98",
        "--producer", "fkst-packages-testing", "--producer-version", "1.0.0",
        "--toolchain", "python-3.11", "--created-at", "2026-08-21T00:00:00Z",
        "--build-id", "fixture-build",
    ]


def run_generator(root: Path, output: Path) -> dict[str, object]:
    subprocess.run(base_arguments(root, output), check=True)
    return json.loads(output.read_text())


def assert_rejected(arguments: list[str], expected: str) -> None:
    result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    assert result.returncode != 0, expected
    assert expected in result.stderr, (expected, result.stderr)


def load_json(path: Path) -> dict[str, object]:
    return json.loads(path.read_text(encoding="utf-8"))


def assert_shared_schema(path: Path, schema: dict[str, object]) -> None:
    assert path == SCHEMA
    assert set(schema["properties"]) == set(schema["required"])
    assert len(schema["required"]) == 14


def assert_shared_case(result: CaseResult) -> None:
    if result.name == "valid":
        assert result.fixture["package_id"] == "QA_RUNNER@V1"
        for codepoint in range(0x20):
            mutated = dict(result.instance)
            mutated["package_id"] = f"QA{chr(codepoint)}RUNNER@V1"
            assert result.validation_errors(mutated), (
                f"schema accepted package_id control U+{codepoint:04X}"
            )


def validate_shared_schema_fixtures() -> None:
    cases = (DeclaredCase("valid", "valid.json", SCHEMA, True),) + tuple(
        DeclaredCase(name, f"{name}.json", SCHEMA, False)
        for name in INVALID_SHARED_FIXTURES
    )
    run_schema_fixture_suite(
        SchemaSuiteSpec(
            schemas=(SCHEMA,),
            dependencies=(),
            fixtures=DeclaredFixtureSource(SHARED_FIXTURES, cases),
        ),
        assert_schema=assert_shared_schema,
        assert_case=assert_shared_case,
    )


def main() -> int:
    validate_shared_schema_fixtures()
    vector = json.loads((FIXTURES / "canonical-vector.json").read_text(encoding="utf-8"))
    canonical_bytes = generator.canonical(vector["input"])
    assert canonical_bytes == vector["canonical"].encode("utf-8")
    assert hashlib.sha256(canonical_bytes).hexdigest() == vector["sha256"]
    manifest_vector = json.loads((FIXTURES / "manifest-vector.json").read_text(encoding="utf-8"))
    assert hashlib.sha256(generator.canonical(manifest_vector["input"])).hexdigest() == manifest_vector["sha256"]

    for invalid in (1.5, generator.MAX_INTEGER + 1, generator.MIN_INTEGER - 1, {1: "value"}):
        try:
            generator.canonical(invalid)
        except ValueError:
            pass
        else:
            raise AssertionError(f"canonicalization accepted invalid value: {invalid!r}")
    cyclic: list[object] = []
    cyclic.append(cyclic)
    try:
        generator.canonical(cyclic)
    except ValueError:
        pass
    else:
        raise AssertionError("canonicalization accepted a cyclic container")
    try:
        generator.canonical("\ud800")
    except ValueError:
        pass
    else:
        raise AssertionError("canonicalization accepted an invalid Unicode scalar value")

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory) / "package"
        root.mkdir()
        (root / "core.lua").write_text("return 'stable'\n")
        output = root / generator.MANIFEST_NAME
        first = run_generator(root, output)
        replay = run_generator(root, output)
        assert first == replay
        original_digest = first["package_content_sha256"]
        (root / "core.lua").write_text("return 'changed'\n")
        changed = run_generator(root, output)
        assert changed["package_content_sha256"] != original_digest

        fields = dict(first)
        fields["manifest_digest"] = "0" * 64
        assert hashlib.sha256(generator.canonical({key: value for key, value in fields.items() if key != "manifest_digest"})).hexdigest() != fields["manifest_digest"]

        floating = base_arguments(root, output)
        floating[floating.index("--source-commit") + 1] = "main"
        assert_rejected(floating, "source_commit must be exact")
        unknown = base_arguments(root, output)
        unknown[unknown.index("--entrypoint") + 1] = "testing-runner.unknown"
        assert_rejected(unknown, "unknown entrypoint")
        unsupported = base_arguments(root, output)
        unsupported[unsupported.index("--entrypoint-contract-major") + 1] = "testing-runner.v2"
        assert_rejected(unsupported, "entrypoint contract major must be supported")

    valid_fixture = json.loads((FIXTURES / "valid.json").read_text())
    assert valid_fixture["schema"] == generator.SCHEMA
    for name in ("missing", "floating", "mismatched", "unsupported-major", "unknown-entrypoint"):
        fixture = json.loads((FIXTURES / f"{name}.json").read_text())
        assert fixture["case"] == name
    print("testing-package-manifest: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
