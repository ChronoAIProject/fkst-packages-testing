#!/usr/bin/env python3
from __future__ import annotations

import base64
import copy
import hashlib
import json
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


STAGES = ("trust-pin-matched", "public-key-imported", "dsse-verified", "release-verified", "manifest-verified", "bundle-verified", "materialized", "executed")
ARTIFACTS = {
    "release": ROOT / "package-release/testing-package-release.v1.json",
    "envelope": ROOT / "package-release/testing-package-release.v1.dsse.json",
    "bundle": ROOT / "package-release/testing-package-bundle.v1.json",
    "manifest": ROOT / "package-release/testing-package-manifest.v1.json",
    "schema-catalog": ROOT / "schema-release/testing-schema-catalog.v1.json",
    "schema-release": ROOT / "schema-release/testing-package-schema-release.v1.json",
}

def canonical(value: object, *, lf: bool = True) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode() + (b"\n" if lf else b"")

def stages(path: Path) -> tuple[str, ...]:
    return tuple(path.read_text().splitlines()) if path.exists() else ()

def assert_rejection(result: subprocess.CompletedProcess[str], stage_log: Path, message: str, allowed: tuple[str, ...]) -> None:
    assert message in result.stderr, result.stderr
    observed = stages(stage_log)
    assert observed == ("release-digest-matched", *allowed), (message, observed)
    assert "materialized" not in observed and "executed" not in observed

def signed_case(root: Path, mutate, *, target: str, message: str, allowed: tuple[str, ...]) -> None:
    paths = {}
    for name, source in ARTIFACTS.items():
        target_path = root / source.name
        target_path.write_bytes(source.read_bytes())
        paths[name] = target_path
    authorization = root / "authorization.json"
    release = json.loads(paths["release"].read_bytes())
    for binding, artifact in (("bundle", "bundle"), ("manifest", "manifest"), ("schema_catalog", "schema-catalog"), ("schema_release", "schema-release")):
        release[binding]["path"] = paths[artifact].relative_to(ROOT).as_posix()
    value = json.loads(paths[target].read_bytes())
    mutate(value)
    if target == "manifest":
        value["manifest_digest"] = hashlib.sha256(canonical({key: item for key, item in value.items() if key != "manifest_digest"}, lf=False)).hexdigest()
    paths[target].write_bytes(canonical(value, lf=target != "manifest"))
    if target == "manifest":
        release["manifest"].update(size_bytes=paths[target].stat().st_size, sha256=hashlib.sha256(paths[target].read_bytes()).hexdigest(), manifest_digest=value.get("manifest_digest", "0" * 64))
    elif target == "bundle":
        release["bundle"].update(size_bytes=paths[target].stat().st_size, sha256=hashlib.sha256(paths[target].read_bytes()).hexdigest())
    if target != "release":
        paths["release"].write_bytes(canonical(release))
    seed = hashlib.sha256((target + message).encode()).digest()
    envelope, authorization_bytes = generator.signed_artifacts(paths["release"].read_bytes(), seed)
    paths["envelope"].write_bytes(envelope); authorization.write_bytes(authorization_bytes)
    pin = hashlib.sha256(authorization_bytes).hexdigest(); log = root / "stages.log"
    release_sha256 = hashlib.sha256(paths["release"].read_bytes()).hexdigest()
    result = run_verifier(pin, expected_release_sha256=release_sha256,
                          authorization=authorization, paths=paths, stage_log=log, success=False)
    assert_rejection(result, log, message, allowed)

def assert_rejection_matrix() -> None:
    legitimate_pin = hashlib.sha256(AUTHORIZATION.read_bytes()).hexdigest()
    expected = ["--expected-release-sha256", RELEASE_SHA256]
    cli = [
        ([*expected, "--release", str(ARTIFACTS["release"])], "--trusted-authorization-sha256 is required exactly once"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin.upper()], "exactly 64 lowercase hexadecimal"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin[:-1]], "exactly 64 lowercase hexadecimal"),
        ([*expected, "--trusted-authorization-sha256", "g" * 64], "exactly 64 lowercase hexadecimal"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, "--trusted-authorization-sha256", legitimate_pin], "arguments must be unique"),
        ([*expected, "--trusted-authorization-sha256", "--release", str(ARTIFACTS["release"])], "arguments must be unique"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, "--release", str(ARTIFACTS["release"]), "--release", str(ARTIFACTS["release"])], "arguments must be unique"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, "--unknown", "value"], "unknown argument"),
    ]
    for arguments, message in cli:
        result = subprocess.run(["node", str(VERIFIER), *arguments], cwd=ROOT, text=True, capture_output=True)
        assert result.returncode != 0 and message in result.stderr
    with tempfile.TemporaryDirectory(prefix=".testing-package-release-matrix-", dir=ROOT) as directory:
        root = Path(directory)
        authorization_cases = [
            (lambda value: value.update(unexpected=True), "authorization record fields"),
            (lambda value: value.update(algorithm="rsa"), "authorization record profile is unsupported"),
            (lambda value: value.update(schema="wrong"), "authorization record profile is unsupported"),
            (lambda value: value.update(keyid="wrong"), "authorization record profile is unsupported"),
            (lambda value: value["authorization"].update(subject="wrong"), "authorization record profile is unsupported"),
            (lambda value: value["authorization"].update(unexpected=True), "authorization scope fields"),
            (lambda value: value.update(publicKey=value["publicKey"].rstrip("=")), "canonical standard base64"),
            (lambda value: value.update(publicKey="AA=="), "decode to exactly 32 bytes"),
        ]
        for index, (mutate, message) in enumerate(authorization_cases):
            authorization = json.loads(AUTHORIZATION.read_bytes()); mutate(authorization)
            auth_path = root / f"authorization-{index}.json"; auth_path.write_bytes(canonical(authorization)); log = root / f"authorization-{index}.log"
            result = run_verifier(hashlib.sha256(auth_path.read_bytes()).hexdigest(), authorization=auth_path, stage_log=log, success=False)
            assert_rejection(result, log, message, ("trust-pin-matched",))
        noncanonical = root / "authorization-noncanonical.json"; noncanonical.write_bytes(AUTHORIZATION.read_bytes()[:-1])
        log = root / "authorization-noncanonical.log"
        result = run_verifier(hashlib.sha256(noncanonical.read_bytes()).hexdigest(), authorization=noncanonical, stage_log=log, success=False)
        assert_rejection(result, log, "authorization record bytes are not canonical", ("trust-pin-matched",))
        seed = hashlib.sha256(b"envelope-matrix").digest()
        envelope_bytes, authorization_bytes = generator.signed_artifacts(ARTIFACTS["release"].read_bytes(), seed)
        envelope_authorization = root / "envelope-authorization.json"; envelope_authorization.write_bytes(authorization_bytes)
        envelope_pin = hashlib.sha256(authorization_bytes).hexdigest()
        envelope_cases = [
            (lambda value: value.update(unexpected=True), "DSSE envelope fields"),
            (lambda value: value.update(payloadType="wrong"), "DSSE envelope profile is unsupported"),
            (lambda value: value.update(signatures=[]), "DSSE envelope profile is unsupported"),
            (lambda value: value.update(signatures=value["signatures"] * 2), "DSSE envelope profile is unsupported"),
            (lambda value: value["signatures"][0].update(unexpected=True), "DSSE signature fields"),
            (lambda value: value["signatures"][0].update(keyid="wrong"), "DSSE keyid is unsupported"),
            (lambda value: value["signatures"][0].update(sig="AA=="), "decode to exactly 64 bytes"),
            (lambda value: value["signatures"][0].update(sig=("A" if value["signatures"][0]["sig"][0] != "A" else "B") + value["signatures"][0]["sig"][1:]), "Ed25519 DSSE verification failed"),
            (lambda value: value.update(payload=value["payload"] + " "), "canonical standard base64"),
        ]
        for index, (mutate, message) in enumerate(envelope_cases):
            envelope = json.loads(envelope_bytes); mutate(envelope)
            envelope_path = root / f"envelope-{index}.json"; envelope_path.write_bytes(canonical(envelope)); log = root / f"envelope-{index}.log"
            result = run_verifier(envelope_pin, authorization=envelope_authorization, paths={"envelope": envelope_path}, stage_log=log, success=False)
            assert_rejection(result, log, message, ("trust-pin-matched", "public-key-imported"))
        envelope_path = root / "envelope-noncanonical.json"; envelope_path.write_bytes(envelope_bytes[:-1]); log = root / "envelope-noncanonical.log"
        result = run_verifier(envelope_pin, authorization=envelope_authorization, paths={"envelope": envelope_path}, stage_log=log, success=False)
        assert_rejection(result, log, "DSSE envelope bytes are not canonical", ("trust-pin-matched", "public-key-imported"))
        cases = [
            ("release", lambda value: value.update(schema="wrong"), "release profile is unsupported", ("trust-pin-matched", "public-key-imported", "dsse-verified")),
            ("release", lambda value: value["mappings"].append(copy.deepcopy(value["mappings"][0])), "exactly one mapping", ("trust-pin-matched", "public-key-imported", "dsse-verified")),
            ("manifest", lambda value: value["runtime_requirements"].update(lua="5.3.0"), "manifest runtime requirements are unsupported", ("trust-pin-matched", "public-key-imported", "dsse-verified", "release-verified")),
            ("manifest", lambda value: value["entrypoints"].append(copy.deepcopy(value["entrypoints"][0])), "manifest must expose exactly testing-runner.run", ("trust-pin-matched", "public-key-imported", "dsse-verified", "release-verified")),
            ("bundle", lambda value: value["files"].append({**value["files"][-1], "path": "libraries/unexpected.lua"}), "bundle files do not match the release allowlist", ("trust-pin-matched", "public-key-imported", "dsse-verified", "release-verified", "manifest-verified")),
            ("bundle", lambda value: value["files"].reverse(), "bundle paths must be unique and sorted", ("trust-pin-matched", "public-key-imported", "dsse-verified", "release-verified", "manifest-verified")),
            ("bundle", lambda value: value["files"][0].update(path="../escape.lua"), "bundle file path is unsafe", ("trust-pin-matched", "public-key-imported", "dsse-verified", "release-verified", "manifest-verified")),
        ]
        for index, case in enumerate(cases):
            case_root = root / str(index); case_root.mkdir(); signed_case(case_root, case[1], target=case[0], message=case[2], allowed=case[3])
        publication = root / "publication"; publication.mkdir()
        paths = {name: publication / source.name for name, source in ARTIFACTS.items()}
        for name, source in ARTIFACTS.items(): paths[name].write_bytes(source.read_bytes())
        release = json.loads(paths["release"].read_bytes())
        for binding, artifact in (("bundle", "bundle"), ("manifest", "manifest"), ("schema_catalog", "schema-catalog"), ("schema_release", "schema-release")):
            release[binding]["path"] = paths[artifact].relative_to(ROOT).as_posix()
        paths["release"].write_bytes(canonical(release))
        envelope, authorization_bytes = generator.signed_artifacts(paths["release"].read_bytes(), hashlib.sha256(b"publication").digest())
        paths["envelope"].write_bytes(envelope); auth_path = publication / "authorization.json"; auth_path.write_bytes(authorization_bytes)
        paths["schema-catalog"].write_bytes(paths["schema-catalog"].read_bytes()[:-1] + b" ")
        log = root / "publication.log"
        release_sha256 = hashlib.sha256(paths["release"].read_bytes()).hexdigest()
        result = run_verifier(hashlib.sha256(authorization_bytes).hexdigest(),
                              expected_release_sha256=release_sha256,
                              authorization=auth_path, paths=paths, stage_log=log, success=False)
        assert_rejection(result, log, "schema publication binding mismatch", ("trust-pin-matched", "public-key-imported", "dsse-verified"))


def assert_generator_rejections() -> None:
    variable = generator.SEED_ENVIRONMENT_VARIABLE
    original = os.environ.get(variable)
    seed = base64.b64encode(hashlib.sha256(b"generator-matrix").digest()).decode()
    try:
        os.environ.pop(variable, None)
        try:
            generator.signing_seed(None)
        except ValueError as error:
            assert "signing seed is required" in str(error)
        else:
            raise AssertionError("missing signing seed was accepted")
        with tempfile.TemporaryDirectory(prefix="testing-package-release-seed-") as directory:
            seed_path = Path(directory) / "seed"; seed_path.write_text(seed)
            os.environ[variable] = seed
            try:
                generator.signing_seed(seed_path)
            except ValueError as error:
                assert "use either --seed-file" in str(error)
            else:
                raise AssertionError("duplicate signing seed sources were accepted")
            os.environ.pop(variable)
            seed_path.write_text(seed + "\n")
            try:
                generator.signing_seed(seed_path)
            except ValueError as error:
                assert seed not in str(error) and "canonical standard base64" in str(error)
            else:
                raise AssertionError("noncanonical signing seed was accepted")
    finally:
        if original is None:
            os.environ.pop(variable, None)
        else:
            os.environ[variable] = original


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
    assert_generator_rejections()
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

    assert_rejection_matrix()

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
