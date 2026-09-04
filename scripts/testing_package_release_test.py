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
from json_schema_test_support import validator_for_schema_file


ROOT = Path(__file__).resolve().parents[1]
AUTHORIZATION = ROOT / "package-release/testing-package-release.v1.key.json"
SOURCE_COMMIT = (
    ROOT / "package-release/testing-package-release.v1.source-commit"
).read_text(encoding="ascii").strip()
VERIFIER = ROOT / "scripts/verify_testing_package_release.mjs"


def run_verifier(pin: str, *, authorization: Path = AUTHORIZATION, paths: dict[str, Path] | None = None, stage_log: Path | None = None, success: bool) -> subprocess.CompletedProcess[str]:
    command = ["node", str(VERIFIER), "--trusted-authorization-sha256", pin, "--authorization", str(authorization)]
    for name, path in (paths or {}).items():
        command.extend([f"--{name}", str(path)])
    environment = os.environ.copy()
    if stage_log is not None:
        environment["FKST_TESTING_PACKAGE_RELEASE_STAGE_LOG"] = str(stage_log)
    result = subprocess.run(command, cwd=ROOT, env=environment, text=True, capture_output=True)
    assert (result.returncode == 0) is success, result.stdout + result.stderr
    return result


def main() -> int:
    subprocess.run([
        sys.executable,
        str(ROOT / "scripts/generate_testing_package_release.py"),
        "--check",
        "--source-commit",
        SOURCE_COMMIT,
    ], cwd=ROOT, check=True)
    _, validator = validator_for_schema_file(ROOT / "schemas/testing-package-release.v1.schema.json")
    valid = generator.json.loads((ROOT / "packages/testing-runner/tests/fixtures/testing-package-release.v1/valid.json").read_text())
    invalid = generator.json.loads((ROOT / "packages/testing-runner/tests/fixtures/testing-package-release.v1/invalid-unknown-field.json").read_text())
    assert not tuple(validator.iter_errors(valid))
    assert tuple(validator.iter_errors(invalid))

    legitimate_pin = hashlib.sha256(AUTHORIZATION.read_bytes()).hexdigest()
    run_verifier(legitimate_pin, success=True)

    with tempfile.TemporaryDirectory(prefix="testing-package-release-attacker-") as directory:
        root = Path(directory)
        attacker_release = root / "release.json"
        attacker_envelope = root / "envelope.json"
        attacker_authorization = root / "authorization.json"
        attacker_bundle = root / "bundle.json"
        attacker_manifest = root / "manifest.json"
        attacker_catalog = root / "catalog.json"
        attacker_schema_release = root / "schema-release.json"
        shutil.copy2(ROOT / "package-release/testing-package-release.v1.json", attacker_release)
        shutil.copy2(ROOT / "package-release/testing-package-bundle.v1.json", attacker_bundle)
        shutil.copy2(ROOT / "package-release/testing-package-manifest.v1.json", attacker_manifest)
        shutil.copy2(ROOT / "schema-release/testing-schema-catalog.v1.json", attacker_catalog)
        shutil.copy2(ROOT / "schema-release/testing-package-schema-release.v1.json", attacker_schema_release)
        seed = hashlib.sha256(b"attacker-controlled-testing-package-release-key").digest()
        envelope, authorization = generator.signed_artifacts(attacker_release.read_bytes(), seed)
        attacker_envelope.write_bytes(envelope)
        attacker_authorization.write_bytes(authorization)
        stage_log = root / "stages.log"
        paths = {"release": attacker_release, "envelope": attacker_envelope, "bundle": attacker_bundle, "manifest": attacker_manifest, "schema-catalog": attacker_catalog, "schema-release": attacker_schema_release}
        run_verifier(legitimate_pin, authorization=attacker_authorization, paths=paths, stage_log=stage_log, success=False)
        assert not stage_log.exists(), "trust-pin rejection must precede all later stages"
        mismatched_pin = ("0" if legitimate_pin[0] != "0" else "1") + legitimate_pin[1:]
        for bad_pin in ("", legitimate_pin.upper(), mismatched_pin):
            stage_log.unlink(missing_ok=True)
            run_verifier(bad_pin, authorization=attacker_authorization, paths=paths, stage_log=stage_log, success=False)
            assert not stage_log.exists(), "malformed or mismatched pins must have zero later-stage activity"

    seed = base64.b64encode(hashlib.sha256(b"reproducible-generator-test-seed").digest()).decode("ascii")
    first = generator.signed_artifacts((ROOT / "package-release/testing-package-release.v1.json").read_bytes(), base64.b64decode(seed))
    second = generator.signed_artifacts((ROOT / "package-release/testing-package-release.v1.json").read_bytes(), base64.b64decode(seed))
    assert first == second
    print("testing-package-release: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
