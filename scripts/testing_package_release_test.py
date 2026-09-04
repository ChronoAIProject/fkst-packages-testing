#!/usr/bin/env python3
from __future__ import annotations

import base64
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import generate_testing_package_release as generator
from json_schema_test_support import offline_registry, validator_for_schema_file


ROOT = Path(__file__).resolve().parents[1]
RELEASE = ROOT / "package-release/testing-package-release.v1.json"
AUTHORIZATION = ROOT / "package-release/testing-package-release.v1.key.json"
RELEASE_SHA256 = "fc34643f3837daa098e1d7be81c27b91d56a6d3be4d0d6f244fe20146f516b56"
AUTHORIZATION_SHA256 = "16ec5e60a1d95d86f3594f245c49abf5c59ef471b4629ba16c095e507a4734ab"
SUCCESS_STAGES = [
    "release-digest-matched",
    "trust-pin-matched",
    "public-key-imported",
    "dsse-verified",
    "release-verified",
    "manifest-verified",
    "bundle-verified",
    "materialized",
    "executed",
]
SOURCE_COMMIT = (
    ROOT / "package-release/testing-package-release.v1.source-commit"
).read_text(encoding="ascii").strip()
VERIFIER = ROOT / "scripts/verify_testing_package_release.mjs"


def run_verifier(
    authorization_pin: str = AUTHORIZATION_SHA256,
    *,
    expected_release_sha256: str | None = RELEASE_SHA256,
    authorization: Path = AUTHORIZATION,
    paths: dict[str, Path] | None = None,
    stage_log: Path | None = None,
    extra_arguments: tuple[str, ...] = (),
    success: bool,
) -> subprocess.CompletedProcess[str]:
    command = ["node", str(VERIFIER)]
    if expected_release_sha256 is not None:
        command.extend(["--expected-release-sha256", expected_release_sha256])
    command.extend([
        "--trusted-authorization-sha256",
        authorization_pin,
        "--authorization",
        str(authorization),
    ])
    for name, path in (paths or {}).items():
        command.extend([f"--{name}", str(path)])
    command.extend(extra_arguments)
    environment = os.environ.copy()
    if stage_log is not None:
        environment["FKST_TESTING_PACKAGE_RELEASE_STAGE_LOG"] = str(stage_log)
    result = subprocess.run(command, cwd=ROOT, env=environment, text=True, capture_output=True)
    assert (result.returncode == 0) is success, result.stdout + result.stderr
    return result


def assert_stages(stage_log: Path, expected: list[str]) -> None:
    actual = stage_log.read_text(encoding="utf-8").splitlines() if stage_log.exists() else []
    assert actual == expected, actual


def assert_bundle_uses_pinned_git_tree() -> None:
    with tempfile.TemporaryDirectory(prefix="testing-package-release-source-") as directory:
        root = Path(directory)
        relative = "libraries/testing_package_executor/executor.lua"
        source_path = root / relative
        source_path.parent.mkdir(parents=True)
        pinned_bytes = b"return { execute = function() return 'pinned' end }\n"
        substituted_bytes = b"return { execute = function() return 'substituted' end }\n"
        source_path.write_bytes(pinned_bytes)
        subprocess.run(["git", "init", "--quiet"], cwd=root, check=True)
        subprocess.run(["git", "add", relative], cwd=root, check=True)
        subprocess.run([
            "git", "-c", "user.name=Testing Package Release", "-c", "user.email=testing-package-release@example.invalid",
            "commit", "--quiet", "-m", "pin bundle source",
        ], cwd=root, check=True)
        source_commit = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=root, check=True, text=True, capture_output=True
        ).stdout.strip()
        source_path.write_bytes(substituted_bytes)

        original_root = generator.ROOT
        original_bundle_files = generator.BUNDLE_FILES
        try:
            generator.ROOT = root
            generator.BUNDLE_FILES = (relative,)
            bundle, _ = generator.bundle(generator.repository_commit(source_commit))
        finally:
            generator.ROOT = original_root
            generator.BUNDLE_FILES = original_bundle_files

        bundled_bytes = base64.b64decode(bundle["files"][0]["content_base64"], validate=True)
        assert bundled_bytes == pinned_bytes
        assert bundled_bytes != substituted_bytes


def main() -> int:
    assert hashlib.sha256(RELEASE.read_bytes()).hexdigest() == RELEASE_SHA256
    assert hashlib.sha256(AUTHORIZATION.read_bytes()).hexdigest() == AUTHORIZATION_SHA256
    subprocess.run([
        sys.executable,
        str(ROOT / "scripts/generate_testing_package_release.py"),
        "--check",
        "--source-commit",
        SOURCE_COMMIT,
    ], cwd=ROOT, check=True)
    assert_bundle_uses_pinned_git_tree()
    schema_paths = tuple(sorted((ROOT / "schemas").glob("*.schema.json")))
    registry = offline_registry(schema_paths)
    _, validator = validator_for_schema_file(
        ROOT / "schemas/testing-package-release.v1.schema.json",
        registry=registry,
    )
    valid = generator.json.loads((ROOT / "packages/testing-runner/tests/fixtures/testing-package-release.v1/valid.json").read_text())
    invalid = generator.json.loads((ROOT / "packages/testing-runner/tests/fixtures/testing-package-release.v1/invalid-unknown-field.json").read_text())
    assert not tuple(validator.iter_errors(valid))
    assert tuple(validator.iter_errors(invalid))

    with tempfile.TemporaryDirectory(prefix="testing-package-release-positive-") as directory:
        stage_log = Path(directory) / "stages.log"
        result = run_verifier(stage_log=stage_log, success=True)
        assert "testing-package-release: VERIFIED AND EXECUTED" in result.stdout
        assert_stages(stage_log, SUCCESS_STAGES)

    with tempfile.TemporaryDirectory(prefix="testing-package-release-policy-") as directory:
        root = Path(directory)
        stage_log = root / "stages.log"
        mismatched_release_sha256 = ("0" if RELEASE_SHA256[0] != "0" else "1") + RELEASE_SHA256[1:]
        run_verifier(expected_release_sha256=mismatched_release_sha256, stage_log=stage_log, success=False)
        assert_stages(stage_log, [])

        altered_release = root / "same-version-release.json"
        altered = generator.json.loads(RELEASE.read_text(encoding="utf-8"))
        assert altered["package"]["package_id"] == "testing-runner"
        assert altered["package"]["package_version"] == "1.0.0"
        altered["creation_metadata"]["build_id"] = "testing-package-release-same-version-substitution"
        altered_release.write_text(
            generator.json.dumps(altered, sort_keys=True, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        run_verifier(paths={"release": altered_release}, stage_log=stage_log, success=False)
        assert_stages(stage_log, [])

        malformed_expected_digests = (
            None,
            RELEASE_SHA256.upper(),
            f"sha256:{RELEASE_SHA256}",
            f" {RELEASE_SHA256}",
            f"{RELEASE_SHA256[:-1]} ",
            f"g{RELEASE_SHA256[1:]}",
            RELEASE_SHA256[:-1],
            f"{RELEASE_SHA256}0",
        )
        for malformed in malformed_expected_digests:
            stage_log.unlink(missing_ok=True)
            result = run_verifier(
                expected_release_sha256=malformed,
                stage_log=stage_log,
                success=False,
            )
            assert "--expected-release-sha256" in result.stderr
            assert_stages(stage_log, [])

        stage_log.unlink(missing_ok=True)
        duplicate = run_verifier(
            stage_log=stage_log,
            extra_arguments=("--expected-release-sha256", RELEASE_SHA256),
            success=False,
        )
        assert "arguments must be unique --name value pairs" in duplicate.stderr
        assert_stages(stage_log, [])

    with tempfile.TemporaryDirectory(prefix="testing-package-release-attacker-") as directory:
        root = Path(directory)
        attacker_release = root / "release.json"
        attacker_envelope = root / "envelope.json"
        attacker_authorization = root / "authorization.json"
        attacker_bundle = root / "bundle.json"
        attacker_manifest = root / "manifest.json"
        attacker_catalog = root / "catalog.json"
        attacker_schema_release = root / "schema-release.json"
        shutil.copy2(RELEASE, attacker_release)
        shutil.copy2(ROOT / "package-release/testing-package-bundle.v1.json", attacker_bundle)
        shutil.copy2(ROOT / "package-release/testing-package-manifest.v1.json", attacker_manifest)
        shutil.copy2(ROOT / "schema-release/testing-schema-catalog.v1.json", attacker_catalog)
        shutil.copy2(ROOT / "schema-release/testing-package-schema-release.v1.json", attacker_schema_release)
        seed = hashlib.sha256(b"attacker-controlled-testing-package-release-key").digest()
        envelope, authorization = generator.signed_artifacts(attacker_release.read_bytes(), seed)
        attacker_envelope.write_bytes(envelope)
        attacker_authorization.write_bytes(authorization)
        legitimate_authorization = generator.json.loads(AUTHORIZATION.read_text(encoding="utf-8"))
        substituted_authorization = generator.json.loads(attacker_authorization.read_text(encoding="utf-8"))
        assert substituted_authorization["keyid"] == legitimate_authorization["keyid"]
        stage_log = root / "stages.log"
        paths = {"release": attacker_release, "envelope": attacker_envelope, "bundle": attacker_bundle, "manifest": attacker_manifest, "schema-catalog": attacker_catalog, "schema-release": attacker_schema_release}
        run_verifier(authorization=attacker_authorization, paths=paths, stage_log=stage_log, success=False)
        assert_stages(stage_log, ["release-digest-matched"])

        mismatched_authorization_pin = ("0" if AUTHORIZATION_SHA256[0] != "0" else "1") + AUTHORIZATION_SHA256[1:]
        for bad_pin, expected_stages in (
            ("", []),
            (AUTHORIZATION_SHA256.upper(), []),
            (mismatched_authorization_pin, ["release-digest-matched"]),
        ):
            stage_log.unlink(missing_ok=True)
            run_verifier(bad_pin, authorization=attacker_authorization, paths=paths, stage_log=stage_log, success=False)
            assert_stages(stage_log, expected_stages)

    seed = base64.b64encode(hashlib.sha256(b"reproducible-generator-test-seed").digest()).decode("ascii")
    first = generator.signed_artifacts(RELEASE.read_bytes(), base64.b64decode(seed))
    second = generator.signed_artifacts(RELEASE.read_bytes(), base64.b64decode(seed))
    assert first == second
    print("testing-package-release: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
