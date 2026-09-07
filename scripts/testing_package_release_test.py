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
MULTIBYTE_OVERFLOW_METADATA = "é" * 90 + "a"


def run_verifier(
    authorization_pin: str = AUTHORIZATION_SHA256,
    *,
    expected_release_sha256: str | None = RELEASE_SHA256,
    authorization: Path = AUTHORIZATION,
    paths: dict[str, Path] | None = None,
    stage_log: Path | None = None,
    extra_arguments: tuple[str, ...] = (),
    environment_overrides: dict[str, str] | None = None,
    verification_time: str = "2026-09-04T12:00:00Z",
    minimum_release_sequence: str = "2",
    success: bool,
) -> subprocess.CompletedProcess[str]:
    command = ["node", str(VERIFIER)]
    if expected_release_sha256 is not None:
        command.extend(["--expected-release-sha256", expected_release_sha256])
    command.extend([
        "--trusted-authorization-sha256",
        authorization_pin,
        "--verification-time",
        verification_time,
        "--minimum-release-sequence",
        minimum_release_sequence,
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


def canonical_with_escaped_scalars(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":")).encode() + b"\n"


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
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, "--minimum-release-sequence", "2"], "--verification-time is required exactly once"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, "--verification-time", "2026-09-04T12:00:00Z"], "--minimum-release-sequence is required exactly once"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, *policy, "--verification-time", "2026-09-04T12:00:00Z"], "arguments must be unique"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, *policy, "--minimum-release-sequence", "2"], "arguments must be unique"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, "--verification-time", "2026-02-30T00:00:00Z", "--minimum-release-sequence", "2"], "canonical UTC timestamp"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, "--verification-time", "2026-09-04T12:00:00+00:00", "--minimum-release-sequence", "2"], "canonical UTC timestamp"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, "--verification-time", "2026-09-04T12:00:00.000Z", "--minimum-release-sequence", "2"], "canonical UTC timestamp"),
    ]
    for invalid_sequence in ("0", "-1", "01", "1.0", "9007199254740992"):
        cli.append(([*expected, "--trusted-authorization-sha256", legitimate_pin, "--verification-time", "2026-09-04T12:00:00Z", "--minimum-release-sequence", invalid_sequence], "positive safe decimal integer"))
    cli.extend([
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, *policy, "--revoked-keyid", "bad\u0085key"], "--revoked-keyid is invalid"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, *policy, "--revoked-keyid", MULTIBYTE_OVERFLOW_KEYID], "--revoked-keyid is invalid"),
        ([*expected, "--trusted-authorization-sha256", legitimate_pin, *policy, "--revoked-keyid", "duplicate", "--revoked-keyid", "duplicate"], "--revoked-keyid values must be unique"),
    ])
    with tempfile.TemporaryDirectory(prefix="testing-package-release-cli-") as directory:
        root = Path(directory)
        for index, (arguments, message) in enumerate(cli):
            stage_log = root / f"{index}.stages.log"
            temporary_root = root / f"{index}.tmp"
            temporary_root.mkdir()
            effect_sentinel = root / f"{index}.effect"
            engine = root / f"{index}.sh"
            engine.write_text(f'#!/bin/sh\n: > "{effect_sentinel}"\nexit 99\n', encoding="utf-8")
            engine.chmod(0o755)
            environment = os.environ.copy()
            environment.update({
                "FKST_TESTING_ENGINE_BIN": str(engine),
                "FKST_TESTING_PACKAGE_RELEASE_STAGE_LOG": str(stage_log),
                "TMPDIR": str(temporary_root),
            })
            result = subprocess.run(
                ["node", str(VERIFIER), *arguments],
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
            )
            assert result.returncode != 0 and message in result.stderr
            assert_stages(stage_log, [])
            assert not effect_sentinel.exists()
            assert tuple(temporary_root.iterdir()) == ()
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


def assert_expected_release_first_gate() -> None:
    with tempfile.TemporaryDirectory(prefix="testing-package-release-first-gate-") as directory:
        root = Path(directory)
        release = root / "release.json"
        release.write_bytes(b"{not-json")
        stage_log = root / "stages.log"
        temporary_root = root / "tmp"
        temporary_root.mkdir()
        effect_sentinel = root / "effect-sentinel"
        engine = root / "engine.sh"
        engine.write_text(f'#!/bin/sh\n: > "{effect_sentinel}"\nexit 99\n', encoding="utf-8")
        engine.chmod(0o755)
        result = run_verifier(
            expected_release_sha256="0" * 64,
            authorization=root / "missing-authorization.json",
            paths={"release": release, **{
                name: root / f"missing-{name}.json"
                for name in ("envelope", "bundle", "manifest", "tool-catalog", "schema-catalog", "schema-release")
            }},
            stage_log=stage_log,
            environment_overrides={"FKST_TESTING_ENGINE_BIN": str(engine), "TMPDIR": str(temporary_root)},
            success=False,
        )
        assert "release descriptor SHA-256 does not match the independently provisioned expected digest" in result.stderr
        assert "not valid JSON" not in result.stderr and "ENOENT" not in result.stderr
        assert_stages(stage_log, [])
        assert not effect_sentinel.exists()
        assert tuple(temporary_root.iterdir()) == ()


def assert_successor_walking_skeleton(registry) -> None:
    tracked = tuple(sorted((ROOT / "package-release").rglob("*"))) + tuple(sorted((ROOT / "schema-release").rglob("*")))
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
        for invalid_keyid in ("bad\u0085key", MULTIBYTE_OVERFLOW_KEYID):
            invalid_release = copy.deepcopy(release)
            invalid_release["authority"]["keyid"] = invalid_keyid
            assert tuple(release_validator.iter_errors(invalid_release))
        invalid_scalar_release = copy.deepcopy(release)
        invalid_scalar_release["authority"]["keyid"] = "bad\ud800key"
        assert next(release_validator.iter_errors(invalid_scalar_release), None) is not None
        invalid_release = copy.deepcopy(release)
        invalid_release["authority"]["valid_from"] = "2026-02-30T00:00:00Z"
        assert tuple(release_validator.iter_errors(invalid_release))
        for missing in ("authority", "tool_catalog"):
            invalid_release = copy.deepcopy(release)
            del invalid_release[missing]
            assert tuple(release_validator.iter_errors(invalid_release))
        for missing in release["authority"]:
            invalid_release = copy.deepcopy(release)
            del invalid_release["authority"][missing]
            assert tuple(release_validator.iter_errors(invalid_release))
        invalid_release = copy.deepcopy(release)
        invalid_release["authority"]["unexpected"] = True
        assert tuple(release_validator.iter_errors(invalid_release))
        invalid_release = copy.deepcopy(release)
        invalid_release["tool_catalog"]["path"] = "publisher/tool-catalog.json"
        assert tuple(release_validator.iter_errors(invalid_release))
        metadata_release = copy.deepcopy(release)
        metadata_release["executor"].update(module="publisher.module", function="publisher_function", executor_id="publisher.executor")
        metadata_release["mappings"][0].update(module="publisher.mapping", function="publisher_mapping")
        assert not tuple(release_validator.iter_errors(metadata_release))
        legacy_release = json.loads(RELEASE.read_bytes())
        legacy_release["executor"]["module"] = "publisher.module"
        assert tuple(release_validator.iter_errors(legacy_release))
        metadata_catalog = copy.deepcopy(catalog)
        metadata_catalog["tools"][0]["port"] = "publisher_port"
        assert not tuple(catalog_validator.iter_errors(metadata_catalog))
        for invalid_port in ("bad\u0085port", MULTIBYTE_OVERFLOW_METADATA):
            invalid_catalog = copy.deepcopy(catalog)
            invalid_catalog["tools"][0]["port"] = invalid_port
            assert tuple(catalog_validator.iter_errors(invalid_catalog))
        invalid_scalar_catalog = copy.deepcopy(catalog)
        invalid_scalar_catalog["tools"][0]["port"] = "bad\ud800port"
        assert next(catalog_validator.iter_errors(invalid_scalar_catalog), None) is not None
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

        def run_successor_rejection(
            name: str, message: str, *, mutate_release=None, mutate_catalog=None, serialize_release=None, serialize_catalog=None,
            extra_arguments: tuple[str, ...] = (), environment_overrides: dict[str, str] | None = None,
            expected_stages: list[str] | None = None, verification_time: str = "2026-09-04T12:00:00Z",
            minimum_release_sequence: str = "2",
        ) -> None:
            case_root = parent / f"successor-rejection-{name}"
            shutil.copytree(roots[0], case_root)
            case_release_path = case_root / "package-release/testing-package-release.v1.json"
            case_catalog_path = case_root / "package-release/testing-package-tool-catalog.v1.json"
            case_release = json.loads(case_release_path.read_bytes())
            if mutate_catalog is not None:
                case_catalog = json.loads(case_catalog_path.read_bytes())
                mutate_catalog(case_catalog)
                case_catalog_path.write_bytes(
                    serialize_catalog(case_catalog) if serialize_catalog is not None else canonical(case_catalog)
                )
                case_release["tool_catalog"].update(
                    sha256=hashlib.sha256(case_catalog_path.read_bytes()).hexdigest(),
                    size_bytes=case_catalog_path.stat().st_size,
                )
            if mutate_release is not None:
                mutate_release(case_release)
            case_release_path.write_bytes(
                serialize_release(case_release) if serialize_release is not None else canonical(case_release)
            )
            keyid = case_release.get("authority", {}).get("keyid", "fkst-packages-testing-successor-test-v1")
            envelope, authorization = generator.signed_artifacts(
                case_release_path.read_bytes(),
                base64.b64decode(TEST_ONLY_PUBLIC_SIGNING_SEED_BASE64),
                keyid=keyid,
            )
            envelope_path = case_root / "package-release/testing-package-release.v1.dsse.json"
            authorization_path = case_root / "package-release/testing-package-release.v1.key.json"
            envelope_path.write_bytes(envelope)
            authorization_path.write_bytes(authorization)
            log = parent / f"successor-rejection-{name}.log"
            effect_sentinel = parent / f"successor-rejection-{name}.effect"
            engine = parent / f"successor-rejection-{name}.sh"
            engine.write_text(f'#!/bin/sh\n: > "{effect_sentinel}"\nexit 99\n', encoding="utf-8")
            engine.chmod(0o755)
            result = run_verifier(
                hashlib.sha256(authorization).hexdigest(),
                expected_release_sha256=hashlib.sha256(case_release_path.read_bytes()).hexdigest(),
                authorization=authorization_path,
                paths={
                    "release": case_release_path,
                    "envelope": envelope_path,
                    "bundle": case_root / "package-release/testing-package-bundle.v1.json",
                    "manifest": case_root / "package-release/testing-package-manifest.v1.json",
                    "tool-catalog": case_catalog_path,
                    "schema-catalog": ROOT / "schema-release/testing-schema-catalog.v1.json",
                    "schema-release": ROOT / "schema-release/testing-package-schema-release.v1.json",
                },
                stage_log=log,
                extra_arguments=extra_arguments,
                environment_overrides={"FKST_TESTING_ENGINE_BIN": str(engine), **(environment_overrides or {})},
                verification_time=verification_time,
                minimum_release_sequence=minimum_release_sequence,
                success=False,
            )
            assert message in result.stderr, result.stderr
            assert_stages(log, expected_stages if expected_stages is not None else ["release-digest-matched"])
            assert not effect_sentinel.exists()

        missing_option_root = roots[0]
        missing_option_release = missing_option_root / "package-release/testing-package-release.v1.json"
        missing_option_authorization = missing_option_root / "package-release/testing-package-release.v1.key.json"
        missing_option_log = parent / "successor-missing-tool-option-order.log"
        missing_authorization = parent / "does-not-exist-authorization.json"
        missing_tool_option = run_verifier(
            hashlib.sha256(missing_option_authorization.read_bytes()).hexdigest(),
            expected_release_sha256=hashlib.sha256(missing_option_release.read_bytes()).hexdigest(),
            authorization=missing_authorization,
            paths={"release": missing_option_release},
            stage_log=missing_option_log,
            success=False,
        )
        assert "--tool-catalog is required for successor releases" in missing_tool_option.stderr
        assert "ENOENT" not in missing_tool_option.stderr
        assert_stages(missing_option_log, ["release-digest-matched"])

        run_successor_rejection("not-yet-valid", "outside its authorized validity interval", verification_time="2026-09-03T23:59:59Z")
        run_successor_rejection("expired", "outside its authorized validity interval", verification_time="2026-09-05T00:00:00Z")
        run_successor_rejection("revoked", "release signing key is revoked", extra_arguments=("--revoked-keyid", release["authority"]["keyid"]))
        run_successor_rejection("sequence-floor", "release sequence is below the consumer minimum", minimum_release_sequence="3")

        authority_cases = (
            ("authority-issuer", lambda value: value["authority"].update(issuer="https://publisher.invalid"), "release authority profile is unsupported"),
            ("authority-profile", lambda value: value["authority"].update(signature_profile="wrong"), "release authority profile is unsupported"),
            ("authority-revocation", lambda value: value["authority"].update(revocation_authority="https://publisher.invalid/revocations"), "release authority profile is unsupported"),
            ("authority-sequence-zero", lambda value: value["authority"].update(release_sequence=0), "release authority profile is unsupported"),
            ("authority-sequence-negative", lambda value: value["authority"].update(release_sequence=-1), "release authority profile is unsupported"),
            ("authority-sequence-fraction", lambda value: value["authority"].update(release_sequence=1.5), "release authority profile is unsupported"),
            ("authority-sequence-overflow", lambda value: value["authority"].update(release_sequence=9007199254740992), "release authority profile is unsupported"),
            ("authority-date", lambda value: value["authority"].update(valid_from="2026-02-30T00:00:00Z"), "canonical UTC timestamp"),
            ("authority-equal", lambda value: value["authority"].update(valid_until=value["authority"]["valid_from"]), "validity interval is empty"),
            ("authority-reversed", lambda value: value["authority"].update(valid_from="2026-09-06T00:00:00Z"), "validity interval is empty"),
            ("authority-keyid-control", lambda value: value["authority"].update(keyid="bad\u0085key"), "release.authority.keyid is invalid"),
            ("authority-keyid-overflow", lambda value: value["authority"].update(keyid=MULTIBYTE_OVERFLOW_KEYID), "release.authority.keyid is invalid"),
            ("tool-path", lambda value: value["tool_catalog"].update(path="publisher/tool-catalog.json"), "release.tool_catalog.path is unsupported"),
            ("missing-authority", lambda value: value.pop("authority"), "release fields do not match the closed profile"),
            ("missing-tool-binding", lambda value: value.pop("tool_catalog"), "release fields do not match the closed profile"),
        )
        for name, mutate, message in authority_cases:
            run_successor_rejection(name, message, mutate_release=mutate)
        for member in release["authority"]:
            run_successor_rejection(
                f"authority-missing-{member}",
                "release.authority fields do not match the closed profile",
                mutate_release=lambda value, member=member: value["authority"].pop(member),
            )
        run_successor_rejection(
            "authority-unknown",
            "release.authority fields do not match the closed profile",
            mutate_release=lambda value: value["authority"].update(unexpected=True),
        )

        semantic_cases = (
            ("package-id", lambda value: value["package"].update(package_id="publisher-runner"), "release package identity is unsupported"),
            ("package-profile", lambda value: value["package"].update(supported_profile="publisher-profile"), "release package identity is unsupported"),
            ("package-capability", lambda value: value["package"].update(capability="publisher.capability"), "release package identity is unsupported"),
            ("mapping-empty", lambda value: value.update(mappings=[]), "exactly one mapping"),
            ("mapping-multiple", lambda value: value["mappings"].append(copy.deepcopy(value["mappings"][0])), "exactly one mapping"),
            ("mapping-entrypoint", lambda value: value["mappings"][0].update(entrypoint="publisher.run"), "release mapping is unsupported"),
            ("mapping-contract", lambda value: value["mappings"][0].update(contract_major="publisher.v1"), "release mapping is unsupported"),
            ("executor-module-empty", lambda value: value["executor"].update(module=""), "release.executor.module is invalid"),
            ("executor-function-control", lambda value: value["executor"].update(function="bad\u0085function"), "release.executor.function is invalid"),
            ("executor-id-overflow", lambda value: value["executor"].update(executor_id=MULTIBYTE_OVERFLOW_METADATA), "release.executor.executor_id is invalid"),
            ("mapping-module-empty", lambda value: value["mappings"][0].update(module=""), "release.mapping.module is invalid"),
            ("mapping-function-overflow", lambda value: value["mappings"][0].update(function=MULTIBYTE_OVERFLOW_METADATA), "release.mapping.function is invalid"),
            ("reducer-schema", lambda value: value["reducer"].update(schema="wrong"), "release reducer identity is unsupported"),
            ("reducer-id", lambda value: value["reducer"].update(reducer_id="wrong"), "release reducer identity is unsupported"),
            ("reducer-version", lambda value: value["reducer"].update(reducer_version="2.0.0"), "release reducer identity is unsupported"),
            ("reducer-digest", lambda value: value["reducer"].update(reducer_sha256="0" * 64), "release reducer identity is unsupported"),
            ("reducer-profile", lambda value: value["reducer"].update(policy_profile="wrong"), "release reducer identity is unsupported"),
            ("reducer-contract", lambda value: value["reducer"].update(supported_result_contract_majors=["wrong"]), "release reducer identity is unsupported"),
            ("result-authority", lambda value: value["result_authority"].update(receipt_schema="wrong"), "release result authority identity is unsupported"),
        )
        for name, mutate, message in semantic_cases:
            run_successor_rejection(name, message, mutate_release=mutate)
        for name, field, message in (
            ("executor-module-surrogate", ("executor", "module"), "release.executor.module is invalid"),
            ("mapping-module-surrogate", ("mappings", "module"), "release.mapping.module is invalid"),
        ):
            run_successor_rejection(
                name,
                message,
                mutate_release=(
                    (lambda value: value["executor"].update(module="bad\ud800module"))
                    if field[0] == "executor"
                    else (lambda value: value["mappings"][0].update(module="bad\ud800module"))
                ),
                serialize_release=canonical_with_escaped_scalars,
            )

        for source_field in ("repository_commit", "fkst_packages_commit", "fkst_substrate_commit"):
            run_successor_rejection(
                f"source-{source_field}",
                "release source identities do not match committed provenance pins",
                mutate_release=lambda value, source_field=source_field: value["source"].update({source_field: "1" * 40}),
                expected_stages=["release-digest-matched", "trust-pin-matched", "public-key-imported", "dsse-verified"],
            )

        catalog_cases = (
            ("catalog-schema", lambda value: value.update(schema="wrong"), "tool catalog profile is unsupported"),
            ("catalog-canonicalization", lambda value: value.update(canonicalization="wrong"), "tool catalog profile is unsupported"),
            ("catalog-profile", lambda value: value.update(execution_profile="wrong"), "tool catalog profile is unsupported"),
            ("catalog-capability", lambda value: value["tools"][0].update(capability="wrong"), "tool catalog capability is unsupported"),
            ("catalog-empty", lambda value: value.update(tools=[]), "tool catalog profile is unsupported"),
            ("catalog-multiple", lambda value: value["tools"].append(copy.deepcopy(value["tools"][0])), "tool catalog profile is unsupported"),
            ("catalog-port-control", lambda value: value["tools"][0].update(port="bad\u0085port"), "tool catalog port is invalid"),
            ("catalog-port-overflow", lambda value: value["tools"][0].update(port=MULTIBYTE_OVERFLOW_METADATA), "tool catalog port is invalid"),
            ("catalog-missing-schema", lambda value: value.pop("schema"), "tool catalog fields do not match the closed profile"),
            ("catalog-extra", lambda value: value.update(unexpected=True), "tool catalog fields do not match the closed profile"),
            ("catalog-entry-missing-port", lambda value: value["tools"][0].pop("port"), "tool catalog entry fields do not match the closed profile"),
            ("catalog-entry-extra", lambda value: value["tools"][0].update(module="publisher.module"), "tool catalog entry fields do not match the closed profile"),
        )
        for name, mutate, message in catalog_cases:
            run_successor_rejection(name, message, mutate_catalog=mutate, expected_stages=["release-digest-matched", "trust-pin-matched", "public-key-imported", "dsse-verified"])
        run_successor_rejection(
            "catalog-port-surrogate",
            "tool catalog port is invalid",
            mutate_catalog=lambda value: value["tools"][0].update(port="bad\ud800port"),
            serialize_catalog=canonical_with_escaped_scalars,
            expected_stages=["release-digest-matched", "trust-pin-matched", "public-key-imported", "dsse-verified"],
        )
        run_successor_rejection(
            "catalog-wrong-digest",
            "tool catalog persisted binding mismatch",
            mutate_release=lambda value: value["tool_catalog"].update(sha256="0" * 64),
            expected_stages=["release-digest-matched", "trust-pin-matched", "public-key-imported", "dsse-verified"],
        )
        run_successor_rejection(
            "catalog-wrong-size",
            "tool catalog persisted binding mismatch",
            mutate_release=lambda value: value["tool_catalog"].update(size_bytes=value["tool_catalog"]["size_bytes"] + 1),
            expected_stages=["release-digest-matched", "trust-pin-matched", "public-key-imported", "dsse-verified"],
        )
        run_successor_rejection(
            "catalog-noncanonical-persisted-bytes",
            "tool catalog bytes are not canonical",
            mutate_catalog=lambda value: None,
            serialize_catalog=lambda value: json.dumps(value, indent=2, ensure_ascii=False).encode("utf-8"),
            expected_stages=["release-digest-matched", "trust-pin-matched", "public-key-imported", "dsse-verified"],
        )

        invalid_envelope = json.loads((roots[0] / "package-release/testing-package-release.v1.dsse.json").read_bytes())
        invalid_envelope["signatures"][0]["sig"] = (
            "A" if invalid_envelope["signatures"][0]["sig"][0] != "A" else "B"
        ) + invalid_envelope["signatures"][0]["sig"][1:]
        invalid_envelope_path = parent / "successor-invalid-signature.json"
        invalid_envelope_path.write_bytes(canonical(invalid_envelope))
        invalid_signature_log = parent / "successor-invalid-signature.log"
        invalid_signature_tmp = parent / "successor-invalid-signature.tmp"
        invalid_signature_tmp.mkdir()
        invalid_signature_effect = parent / "successor-invalid-signature.effect"
        invalid_signature_engine = parent / "successor-invalid-signature.sh"
        invalid_signature_engine.write_text(f'#!/bin/sh\n: > "{invalid_signature_effect}"\nexit 99\n', encoding="utf-8")
        invalid_signature_engine.chmod(0o755)
        invalid_signature_result = run_verifier(
            hashlib.sha256(authorization_path.read_bytes()).hexdigest(),
            expected_release_sha256=hashlib.sha256(release_path.read_bytes()).hexdigest(),
            authorization=authorization_path,
            paths={
                "release": release_path,
                "envelope": invalid_envelope_path,
                "bundle": parent / "missing-successor-bundle.json",
                "manifest": parent / "missing-successor-manifest.json",
                "tool-catalog": parent / "missing-successor-tool-catalog.json",
                "schema-catalog": parent / "missing-successor-schema-catalog.json",
                "schema-release": parent / "missing-successor-schema-release.json",
            },
            stage_log=invalid_signature_log,
            environment_overrides={
                "FKST_TESTING_ENGINE_BIN": str(invalid_signature_engine),
                "TMPDIR": str(invalid_signature_tmp),
            },
            success=False,
        )
        assert "Ed25519 DSSE verification failed" in invalid_signature_result.stderr
        assert "ENOENT" not in invalid_signature_result.stderr
        assert_stages(invalid_signature_log, ["release-digest-matched", "trust-pin-matched", "public-key-imported"])
        assert not invalid_signature_effect.exists()
        assert tuple(invalid_signature_tmp.iterdir()) == ()
        substituted_root = parent / "publisher-coordinate-substitution"
        shutil.copytree(roots[0], substituted_root)
        substituted_release_path = substituted_root / "package-release/testing-package-release.v1.json"
        substituted_bundle_path = substituted_root / "package-release/testing-package-bundle.v1.json"
        substituted_manifest_path = substituted_root / "package-release/testing-package-manifest.v1.json"
        substituted_catalog_path = substituted_root / "package-release/testing-package-tool-catalog.v1.json"
        substituted_release = json.loads(substituted_release_path.read_bytes())
        substituted_bundle = json.loads(substituted_bundle_path.read_bytes())
        substituted_manifest = json.loads(substituted_manifest_path.read_bytes())
        substituted_catalog = json.loads(substituted_catalog_path.read_bytes())
        substituted_release["executor"].update(module="publisher.sentinel", function="sentinel_default")
        substituted_release["mappings"][0].update(module="publisher.sentinel", function="sentinel_default")
        substituted_catalog["tools"][0]["port"] = "publisher_sentinel_port"
        mapping_record = next(
            record
            for record in substituted_bundle["files"]
            if record["path"] == "libraries/contract/testing_package_executor.lua"
        )
        mapping_bytes = base64.b64decode(mapping_record["content_base64"])
        assert b"M.semantic_mappings = { {" in mapping_bytes
        mapping_bytes = mapping_bytes.replace(b"M.semantic_mappings = { {", b"M.semantic_mappings = { }")
        mapping_record.update(
            content_base64=base64.b64encode(mapping_bytes).decode("ascii"),
            sha256=hashlib.sha256(mapping_bytes).hexdigest(),
            size_bytes=len(mapping_bytes),
        )
        package_content = b"".join(
            record["path"].encode() + b"\0f" + base64.b64decode(record["content_base64"]) + b"\0"
            for record in substituted_bundle["files"]
        )
        substituted_bundle_path.write_bytes(canonical(substituted_bundle))
        substituted_manifest["package_content_sha256"] = hashlib.sha256(package_content).hexdigest()
        substituted_manifest["manifest_digest"] = hashlib.sha256(canonical(
            {key: value for key, value in substituted_manifest.items() if key != "manifest_digest"},
            lf=False,
        )).hexdigest()
        substituted_manifest_path.write_bytes(canonical(substituted_manifest, lf=False))
        substituted_catalog_path.write_bytes(canonical(substituted_catalog))
        substituted_release["package"]["package_content_sha256"] = substituted_manifest["package_content_sha256"]
        substituted_release["bundle"].update(
            sha256=hashlib.sha256(substituted_bundle_path.read_bytes()).hexdigest(),
            size_bytes=substituted_bundle_path.stat().st_size,
        )
        substituted_release["manifest"].update(
            manifest_digest=substituted_manifest["manifest_digest"],
            sha256=hashlib.sha256(substituted_manifest_path.read_bytes()).hexdigest(),
            size_bytes=substituted_manifest_path.stat().st_size,
        )
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
                "bundle": substituted_bundle_path,
                "manifest": substituted_manifest_path,
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
    assert_expected_release_first_gate()
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
