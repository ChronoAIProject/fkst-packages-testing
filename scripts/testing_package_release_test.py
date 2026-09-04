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
FKST_PACKAGES_COMMIT = next(
    line.strip()
    for line in reversed((ROOT / ".fkst/conformance/fkst-packages.pin").read_text(encoding="ascii").splitlines())
    if line.strip() and not line.lstrip().startswith("#")
)
FKST_SUBSTRATE_COMMIT = (ROOT / ".fkst/substrate-ref").read_text(encoding="ascii").strip()
VERIFIER = ROOT / "scripts/verify_testing_package_release.mjs"
TEST_ONLY_PUBLIC_SIGNING_SEED_BASE64 = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
MULTIBYTE_OVERFLOW_KEYID = "é" * 64 + "a"


def run_verifier(
    authorization_pin: str = AUTHORIZATION_SHA256,
    *,
    expected_release_sha256: str | None = RELEASE_SHA256,
    authorization: Path = AUTHORIZATION,
    paths: dict[str, Path] | None = None,
    stage_log: Path | None = None,
    extra_arguments: tuple[str, ...] = (),
    environment_overrides: dict[str, str] | None = None,
    success: bool,
) -> subprocess.CompletedProcess[str]:
    command = ["node", str(VERIFIER)]
    if expected_release_sha256 is not None:
        command.extend(["--expected-release-sha256", expected_release_sha256])
    command.extend([
        "--trusted-authorization-sha256",
        authorization_pin,
        "--verification-time",
        "2026-09-04T12:00:00Z",
        "--minimum-release-sequence",
        "2",
        "--authorization",
        str(authorization),
    ])
    for name, path in (paths or {}).items():
        command.extend([f"--{name}", str(path)])
    command.extend(extra_arguments)
    environment = os.environ.copy()
    environment.update(environment_overrides or {})
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
    policy = ["--verification-time", "2026-09-04T12:00:00Z", "--minimum-release-sequence", "2"]
    cli = [
        ([*expected, *policy, "--release", str(ARTIFACTS["release"])], "--trusted-authorization-sha256 is required exactly once"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin.upper(), *policy], "exactly 64 lowercase hexadecimal"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin[:-1], *policy], "exactly 64 lowercase hexadecimal"),
        ([*expected, "--trusted-authorization-sha256", "g" * 64, *policy], "exactly 64 lowercase hexadecimal"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, "--trusted-authorization-sha256", legitimate_pin, *policy], "arguments must be unique"),
        ([*expected, "--trusted-authorization-sha256", "--release", str(ARTIFACTS["release"]), *policy], "arguments must be unique"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, *policy, "--release", str(ARTIFACTS["release"]), "--release", str(ARTIFACTS["release"])], "arguments must be unique"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, *policy, "--unknown", "value"], "unknown argument"),
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
        invalid_envelope = json.loads(envelope_bytes)
        invalid_envelope["signatures"][0]["sig"] = (
            "A" if invalid_envelope["signatures"][0]["sig"][0] != "A" else "B"
        ) + invalid_envelope["signatures"][0]["sig"][1:]
        invalid_envelope_path = root / "invalid-signature-missing-dependencies.json"
        invalid_envelope_path.write_bytes(canonical(invalid_envelope))
        effect_sentinel = root / "executor-effect-sentinel"
        engine_sentinel = root / "sentinel-engine.sh"
        engine_sentinel.write_text(f'#!/bin/sh\n: > "{effect_sentinel}"\nexit 99\n', encoding="utf-8")
        engine_sentinel.chmod(0o755)
        missing_paths = {
            "envelope": invalid_envelope_path,
            "bundle": root / "missing-bundle.json",
            "manifest": root / "missing-manifest.json",
            "schema-catalog": root / "missing-schema-catalog.json",
            "schema-release": root / "missing-schema-release.json",
        }
        missing_log = root / "invalid-signature-missing-dependencies.log"
        result = run_verifier(
            envelope_pin, authorization=envelope_authorization, paths=missing_paths,
            stage_log=missing_log, environment_overrides={"FKST_TESTING_ENGINE_BIN": str(engine_sentinel)}, success=False,
        )
        assert_rejection(result, missing_log, "Ed25519 DSSE verification failed", ("trust-pin-matched", "public-key-imported"))
        assert "ENOENT" not in result.stderr and not effect_sentinel.exists()
        cases = [
            ("release", lambda value: value.update(schema="wrong"), "release profile is unsupported", ()),
            ("release", lambda value: value["mappings"].append(copy.deepcopy(value["mappings"][0])), "exactly one mapping", ()),
            ("release", lambda value: value["source"].update(fkst_packages_commit="1" * 40), "committed provenance pins", ("trust-pin-matched", "public-key-imported", "dsse-verified")),
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
    assert generator.valid_keyid("é" * 64)
    assert len(MULTIBYTE_OVERFLOW_KEYID.encode("utf-8")) == 129
    for invalid_keyid in ("bad\u0085key", MULTIBYTE_OVERFLOW_KEYID):
        assert not generator.valid_keyid(invalid_keyid)
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


def assert_successor_walking_skeleton(registry) -> None:
    tracked = tuple(sorted((ROOT / "package-release").glob("*"))) + tuple(sorted((ROOT / "schema-release").glob("*")))
    snapshots = {path: path.read_bytes() for path in tracked if path.is_file()}
    expected_paths = {
        "package-release/testing-package-bundle.v1.json",
        "package-release/testing-package-manifest.v1.json",
        "package-release/testing-package-release.v1.json",
        "package-release/testing-package-release.v1.dsse.json",
        "package-release/testing-package-release.v1.key.json",
        "package-release/testing-package-tool-catalog.v1.json",
    }
    with tempfile.TemporaryDirectory(prefix="testing-package-successor-") as directory:
        parent = Path(directory)
        seed_path = parent / "test-only-public-ed25519-seed.base64"
        seed_path.write_text(TEST_ONLY_PUBLIC_SIGNING_SEED_BASE64, encoding="ascii")
        roots = [parent / "first", parent / "second"]
        for output_root in roots:
            subprocess.run([
                sys.executable,
                str(ROOT / "scripts/generate_testing_package_release.py"),
                "--output-directory", str(output_root),
                "--seed-file", str(seed_path),
                "--source-commit", SOURCE_COMMIT,
                "--fkst-packages-commit", FKST_PACKAGES_COMMIT,
                "--fkst-substrate-commit", FKST_SUBSTRATE_COMMIT,
                "--authority-issuer", "https://releases.chronoaiproject.org/fkst-packages-testing",
                "--authority-keyid", "fkst-packages-testing-successor-test-v1",
                "--signature-profile", "dsse-ed25519.v1",
                "--valid-from", "2026-09-04T00:00:00Z",
                "--valid-until", "2026-09-05T00:00:00Z",
                "--revocation-authority", "https://releases.chronoaiproject.org/fkst-packages-testing/revocations/v1",
                "--release-sequence", "2",
                "--created-at", "2026-09-04T00:00:00Z",
            ], cwd=ROOT, check=True)
            actual_paths = {path.relative_to(output_root).as_posix() for path in output_root.rglob("*") if path.is_file()}
            assert actual_paths == expected_paths

        for relative in expected_paths:
            assert (roots[0] / relative).read_bytes() == (roots[1] / relative).read_bytes()

        release_path = roots[0] / "package-release/testing-package-release.v1.json"
        authorization_path = roots[0] / "package-release/testing-package-release.v1.key.json"
        tool_catalog_path = roots[0] / "package-release/testing-package-tool-catalog.v1.json"
        release = json.loads(release_path.read_bytes())
        catalog = json.loads(tool_catalog_path.read_bytes())
        successor_schema_paths = tuple(path for path in sorted((ROOT / "schemas").glob("*.schema.json")) if path.name != "testing-package-release.v1.schema.json") + (
            ROOT / "schemas-next-release/testing-package-release.v1.schema.json",
            ROOT / "schemas-next-release/testing-package-tool-catalog.v1.schema.json",
        )
        successor_registry = offline_registry(successor_schema_paths)
        _, release_validator = validator_for_schema_file(ROOT / "schemas-next-release/testing-package-release.v1.schema.json", registry=successor_registry)
        _, catalog_validator = validator_for_schema_file(ROOT / "schemas-next-release/testing-package-tool-catalog.v1.schema.json", registry=successor_registry)
        assert not tuple(release_validator.iter_errors(release))
        assert not tuple(catalog_validator.iter_errors(catalog))
        invalid_control_release = copy.deepcopy(release)
        invalid_control_release["authority"]["keyid"] = "bad\u0085key"
        assert tuple(release_validator.iter_errors(invalid_control_release))
        assert tool_catalog_path.read_bytes() == b'{"canonicalization":"fkst-testing-package-tool-catalog-canonical-json.v1","execution_profile":"browser-deterministic.v1","schema":"testing-package-tool-catalog.v1","tools":[{"capability":"browser.read-title.v1","port":"browser_read_title"}]}\n'
        assert release["authority"] == {
            "issuer": "https://releases.chronoaiproject.org/fkst-packages-testing",
            "keyid": "fkst-packages-testing-successor-test-v1",
            "release_sequence": 2,
            "revocation_authority": "https://releases.chronoaiproject.org/fkst-packages-testing/revocations/v1",
            "signature_profile": "dsse-ed25519.v1",
            "valid_from": "2026-09-04T00:00:00Z",
            "valid_until": "2026-09-05T00:00:00Z",
        }
        stage_log = parent / "successor-stages.log"
        result = run_verifier(
            hashlib.sha256(authorization_path.read_bytes()).hexdigest(),
            expected_release_sha256=hashlib.sha256(release_path.read_bytes()).hexdigest(),
            authorization=authorization_path,
            paths={
                "release": release_path,
                "envelope": roots[0] / "package-release/testing-package-release.v1.dsse.json",
                "bundle": roots[0] / "package-release/testing-package-bundle.v1.json",
                "manifest": roots[0] / "package-release/testing-package-manifest.v1.json",
                "tool-catalog": tool_catalog_path,
                "schema-catalog": ROOT / "schema-release/testing-schema-catalog.v1.json",
                "schema-release": ROOT / "schema-release/testing-package-schema-release.v1.json",
            },
            stage_log=stage_log,
            success=True,
        )
        assert "testing-package-release: VERIFIED AND EXECUTED" in result.stdout
        assert_stages(stage_log, SUCCESS_STAGES)
        substituted_root = parent / "publisher-coordinate-substitution"
        shutil.copytree(roots[0], substituted_root)
        substituted_release_path = substituted_root / "package-release/testing-package-release.v1.json"
        substituted_catalog_path = substituted_root / "package-release/testing-package-tool-catalog.v1.json"
        substituted_release = json.loads(substituted_release_path.read_bytes())
        substituted_catalog = json.loads(substituted_catalog_path.read_bytes())
        substituted_release["executor"].update(module="publisher.sentinel", function="sentinel_default")
        substituted_release["mappings"][0].update(module="publisher.sentinel", function="sentinel_default")
        substituted_catalog["tools"][0]["port"] = "publisher_sentinel_port"
        substituted_catalog_path.write_bytes(canonical(substituted_catalog))
        substituted_release["tool_catalog"].update(
            sha256=hashlib.sha256(substituted_catalog_path.read_bytes()).hexdigest(),
            size_bytes=substituted_catalog_path.stat().st_size,
        )
        substituted_release_path.write_bytes(canonical(substituted_release))
        substituted_envelope, substituted_authorization = generator.signed_artifacts(
            substituted_release_path.read_bytes(),
            base64.b64decode(TEST_ONLY_PUBLIC_SIGNING_SEED_BASE64),
            keyid=substituted_release["authority"]["keyid"],
        )
        substituted_envelope_path = substituted_root / "package-release/testing-package-release.v1.dsse.json"
        substituted_authorization_path = substituted_root / "package-release/testing-package-release.v1.key.json"
        substituted_envelope_path.write_bytes(substituted_envelope)
        substituted_authorization_path.write_bytes(substituted_authorization)
        substituted_log = parent / "publisher-coordinate-substitution.log"
        substituted_result = run_verifier(
            hashlib.sha256(substituted_authorization).hexdigest(),
            expected_release_sha256=hashlib.sha256(substituted_release_path.read_bytes()).hexdigest(),
            authorization=substituted_authorization_path,
            paths={
                "release": substituted_release_path,
                "envelope": substituted_envelope_path,
                "bundle": substituted_root / "package-release/testing-package-bundle.v1.json",
                "manifest": substituted_root / "package-release/testing-package-manifest.v1.json",
                "tool-catalog": substituted_catalog_path,
                "schema-catalog": ROOT / "schema-release/testing-schema-catalog.v1.json",
                "schema-release": ROOT / "schema-release/testing-package-schema-release.v1.json",
            },
            stage_log=substituted_log,
            success=True,
        )
        assert "testing-package-release: VERIFIED AND EXECUTED" in substituted_result.stdout
        assert_stages(substituted_log, SUCCESS_STAGES)
        for index, invalid_keyid in enumerate(("bad\u0085key", MULTIBYTE_OVERFLOW_KEYID)):
            invalid_log = parent / f"invalid-keyid-{index}.log"
            invalid_result = run_verifier(
                extra_arguments=("--revoked-keyid", invalid_keyid),
                stage_log=invalid_log,
                success=False,
            )
            assert "--revoked-keyid is invalid" in invalid_result.stderr
            assert_stages(invalid_log, [])

    for path, expected in snapshots.items():
        assert path.read_bytes() == expected, path


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
    assert_successor_walking_skeleton(registry)

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
