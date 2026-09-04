#!/usr/bin/env python3
"""Generate the deterministic signed testing-package release walking skeleton."""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUTPUT_ROOT = ROOT / "package-release"
BUNDLE_PATH = OUTPUT_ROOT / "testing-package-bundle.v1.json"
MANIFEST_PATH = OUTPUT_ROOT / "testing-package-manifest.v1.json"
RELEASE_PATH = OUTPUT_ROOT / "testing-package-release.v1.json"
ENVELOPE_PATH = OUTPUT_ROOT / "testing-package-release.v1.dsse.json"
AUTHORIZATION_PATH = OUTPUT_ROOT / "testing-package-release.v1.key.json"
CATALOG_PATH = ROOT / "schema-release/testing-schema-catalog.v1.json"
SCHEMA_RELEASE_PATH = ROOT / "schema-release/testing-package-schema-release.v1.json"
PAYLOAD_TYPE = "application/vnd.in-toto+json"
STATEMENT_TYPE = "https://in-toto.io/Statement/v1"
PREDICATE_TYPE = "https://chronoaiproject.github.io/fkst-packages-testing/attestations/testing-package-release/v1"
SUBJECT_NAME = "package-release/testing-package-release.v1.json"
KEY_ID = "fkst-packages-testing-release-v1-2026-09-04"
SEED_ENVIRONMENT_VARIABLE = "FKST_TESTING_PACKAGE_RELEASE_SIGNING_SEED"
CREATED_AT = "2026-09-04T00:00:00Z"
BUILD_ID = "testing-package-release-walking-skeleton-v1"
VERSION = "1.0.0"
COMMIT = re.compile(r"^[0-9a-f]{40}$")
BUNDLE_FILES = (
    "libraries/contract/canonical_json.lua",
    "libraries/contract/error_facts.lua",
    "libraries/contract/sha256.lua",
    "libraries/contract/strings.lua",
    "libraries/contract/testing_evidence_manifest.lua",
    "libraries/contract/testing_package_executor.lua",
    "libraries/contract/testing_result_authority.lua",
    "libraries/contract/testing_results.lua",
    "libraries/contract/time.lua",
    "libraries/testing_package_executor/executor.lua",
)


def compact(value: object, *, lf: bool = True) -> bytes:
    data = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return data + (b"\n" if lf else b"")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def binding(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    return {"path": path.relative_to(ROOT).as_posix(), "size_bytes": len(data), "sha256": sha256(data)}


def byte_binding(path: Path, data: bytes) -> dict[str, object]:
    return {"path": path.relative_to(ROOT).as_posix(), "size_bytes": len(data), "sha256": sha256(data)}


def exact_commit(value: str, field: str) -> str:
    if COMMIT.fullmatch(value) is None:
        raise ValueError(f"{field} must be an exact lowercase 40-hex commit")
    return value


def repository_commit() -> str:
    value = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=ROOT, check=True, text=True, capture_output=True
    ).stdout.strip()
    return exact_commit(value, "repository commit")


def pinned_commit(path: Path, field: str) -> str:
    for line in path.read_text(encoding="ascii").splitlines():
        value = line.strip()
        if COMMIT.fullmatch(value):
            return value
    raise ValueError(f"{field} pin is missing")


def load_manifest_generator():
    path = ROOT / "scripts/generate_testing_package_manifest.py"
    specification = importlib.util.spec_from_file_location("testing_package_manifest_generator", path)
    if specification is None or specification.loader is None:
        raise ValueError("unable to load the package manifest generator")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def bundle() -> tuple[dict[str, object], str]:
    records = []
    content_digest = hashlib.sha256()
    for relative in sorted(BUNDLE_FILES, key=lambda value: value.encode("utf-8")):
        path = ROOT / relative
        if not path.is_file() or path.is_symlink():
            raise ValueError(f"bundle input must be a regular non-symlink file: {relative}")
        data = path.read_bytes()
        records.append({
            "content_base64": base64.b64encode(data).decode("ascii"),
            "path": relative,
            "sha256": sha256(data),
            "size_bytes": len(data),
        })
        content_digest.update(relative.encode("utf-8"))
        content_digest.update(b"\0f")
        content_digest.update(data)
        content_digest.update(b"\0")
    return {"files": records, "schema": "testing-package-bundle.v1"}, content_digest.hexdigest()


def manifest(package_content_sha256: str, source: str, packages: str, substrate: str) -> dict[str, object]:
    generator = load_manifest_generator()
    value = {
        "schema": generator.SCHEMA,
        "canonicalization": generator.CANONICALIZATION,
        "package_id": "testing-runner",
        "package_version": VERSION,
        "source_commit": source,
        "package_content_sha256": package_content_sha256,
        "supported_contracts": {
            "majors": ["testing-runner.v1"],
            "canonicalization_profiles": [generator.CANONICALIZATION],
        },
        "entrypoints": [{
            "name": "testing-runner.run",
            "contract_major": "testing-runner.v1",
            "capabilities": ["browser.read-title.v1"],
        }],
        "semantic_capabilities": ["browser.read-title.v1"],
        "runtime_requirements": {"lua": "5.4.0", "platforms": ["linux-amd64"]},
        "dependencies": {
            "fkst_packages": {"id": "fkst-packages", "commit": packages},
            "fkst_substrate": {"id": "fkst-substrate", "commit": substrate},
        },
        "producer": {"name": "fkst-packages-testing", "version": VERSION, "toolchain": "testing-package-release-v1"},
        "creation_metadata": {"created_at": CREATED_AT, "build_id": BUILD_ID},
    }
    value["manifest_digest"] = sha256(generator.canonical(value))
    return value


def reducer_identity() -> dict[str, object]:
    value = {
        "schema": "testing-assertion-reducer-identity.v1",
        "reducer_id": "testing.assertion-reducer.browser-title-equals",
        "reducer_version": "1.0.0",
        "policy_profile": "browser-title-equals.v1",
        "supported_result_contract_majors": ["testing-case-result-set.v2"],
    }
    value["reducer_sha256"] = sha256(compact(value, lf=False))
    return value


def release_value(package_content_sha256: str, bundle_bytes: bytes, manifest_bytes: bytes, manifest_value: dict[str, object], source: str, packages: str, substrate: str) -> dict[str, object]:
    manifest_binding = byte_binding(MANIFEST_PATH, manifest_bytes)
    manifest_binding["manifest_digest"] = manifest_value["manifest_digest"]
    return {
        "schema": "testing-package-release.v1",
        "canonicalization": "fkst-testing-package-release-canonical-json.v1",
        "package": {
            "package_id": "testing-runner", "package_version": VERSION,
            "package_content_sha256": package_content_sha256,
            "supported_profile": "browser-deterministic.v1", "capability": "browser.read-title.v1",
        },
        "bundle": byte_binding(BUNDLE_PATH, bundle_bytes),
        "manifest": manifest_binding,
        "schema_catalog": binding(CATALOG_PATH),
        "schema_release": binding(SCHEMA_RELEASE_PATH),
        "source": {"repository_commit": source, "fkst_packages_commit": packages, "fkst_substrate_commit": substrate},
        "producer": {"name": "fkst-packages-testing", "version": VERSION, "generator": "scripts/generate_testing_package_release.py", "generator_version": VERSION},
        "runtime": {"lua": "5.4.0", "platform": "linux-amd64"},
        "executor": {"module": "testing_package_executor.executor", "function": "execute", "executor_id": "testing-package-executor.browser-title.v1"},
        "reducer": reducer_identity(),
        "result_authority": {"receipt_schema": "testing-result-authority-receipt.v1"},
        "mappings": [{"entrypoint": "testing-runner.run", "contract_major": "testing-runner.v1", "module": "testing_package_executor.executor", "function": "execute"}],
        "creation_metadata": {"created_at": CREATED_AT, "build_id": BUILD_ID},
    }


def statement(release_bytes: bytes) -> bytes:
    return compact({
        "_type": STATEMENT_TYPE,
        "predicate": {},
        "predicateType": PREDICATE_TYPE,
        "subject": [{"digest": {"sha256": sha256(release_bytes)}, "name": SUBJECT_NAME}],
    }, lf=False)


def pae(payload: bytes) -> bytes:
    payload_type = PAYLOAD_TYPE.encode("utf-8")
    return b"DSSEv1 " + str(len(payload_type)).encode("ascii") + b" " + payload_type + b" " + str(len(payload)).encode("ascii") + b" " + payload


def decode_seed(value: str) -> bytes:
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("signing seed must be canonical standard base64") from error
    if base64.b64encode(decoded).decode("ascii") != value or len(decoded) != 32:
        raise ValueError("signing seed must be canonical standard base64 for exactly 32 bytes")
    return decoded


def signing_seed(seed_file: Path | None) -> bytes:
    environment_value = os.environ.get(SEED_ENVIRONMENT_VARIABLE)
    if seed_file is not None and environment_value is not None:
        raise ValueError(f"use either --seed-file or {SEED_ENVIRONMENT_VARIABLE}, not both")
    if seed_file is not None:
        value = seed_file.read_text(encoding="ascii").strip()
    elif environment_value is not None:
        value = environment_value
    else:
        raise ValueError(f"signing seed is required through --seed-file or {SEED_ENVIRONMENT_VARIABLE}")
    return decode_seed(value)


def signed_artifacts(release_bytes: bytes, seed: bytes) -> tuple[bytes, bytes]:
    payload = statement(release_bytes)
    with tempfile.TemporaryDirectory(prefix="testing-package-release-sign-") as directory:
        root = Path(directory)
        private_path, public_path, payload_path, signature_path = root / "private.der", root / "public.der", root / "payload", root / "signature"
        private_path.write_bytes(bytes.fromhex("302e020100300506032b657004220420") + seed)
        payload_path.write_bytes(pae(payload))
        subprocess.run(["openssl", "pkey", "-inform", "DER", "-in", private_path, "-pubout", "-outform", "DER", "-out", public_path], check=True, capture_output=True)
        subprocess.run(["openssl", "pkeyutl", "-sign", "-rawin", "-inkey", private_path, "-keyform", "DER", "-in", payload_path, "-out", signature_path], check=True, capture_output=True)
        public_der = public_path.read_bytes()
        if not public_der.startswith(bytes.fromhex("302a300506032b6570032100")) or len(public_der) != 44:
            raise ValueError("OpenSSL returned a malformed Ed25519 public key")
        public_key = public_der[-32:]
        signature = signature_path.read_bytes()
        if len(signature) != 64:
            raise ValueError("OpenSSL returned a malformed Ed25519 signature")
    envelope = {
        "payload": base64.b64encode(payload).decode("ascii"), "payloadType": PAYLOAD_TYPE,
        "signatures": [{"keyid": KEY_ID, "sig": base64.b64encode(signature).decode("ascii")}],
    }
    authorization = {
        "algorithm": "ed25519",
        "authorization": {"payloadType": PAYLOAD_TYPE, "predicateType": PREDICATE_TYPE, "subject": SUBJECT_NAME},
        "keyid": KEY_ID, "publicKey": base64.b64encode(public_key).decode("ascii"),
        "schema": "testing-package-release-key-authorization.v1",
    }
    return compact(envelope), compact(authorization)


def verify_signed_artifacts(release_bytes: bytes) -> None:
    envelope_bytes = ENVELOPE_PATH.read_bytes()
    authorization_bytes = AUTHORIZATION_PATH.read_bytes()
    envelope = json.loads(envelope_bytes)
    authorization = json.loads(authorization_bytes)
    if envelope_bytes != compact(envelope) or authorization_bytes != compact(authorization):
        raise ValueError("signed release artifacts are not canonical")
    if set(envelope) != {"payload", "payloadType", "signatures"} or envelope["payloadType"] != PAYLOAD_TYPE or len(envelope["signatures"]) != 1:
        raise ValueError("signed release envelope profile drift")
    signature_entry = envelope["signatures"][0]
    if set(signature_entry) != {"keyid", "sig"} or signature_entry["keyid"] != KEY_ID:
        raise ValueError("signed release key identity drift")
    if set(authorization) != {"algorithm", "authorization", "keyid", "publicKey", "schema"} or authorization["algorithm"] != "ed25519" or authorization["keyid"] != KEY_ID or authorization["schema"] != "testing-package-release-key-authorization.v1":
        raise ValueError("signed release authorization profile drift")
    if authorization["authorization"] != {"payloadType": PAYLOAD_TYPE, "predicateType": PREDICATE_TYPE, "subject": SUBJECT_NAME}:
        raise ValueError("signed release authorization scope drift")
    payload = base64.b64decode(envelope["payload"], validate=True)
    signature = base64.b64decode(signature_entry["sig"], validate=True)
    public_key = base64.b64decode(authorization["publicKey"], validate=True)
    if base64.b64encode(payload).decode("ascii") != envelope["payload"] or base64.b64encode(signature).decode("ascii") != signature_entry["sig"] or base64.b64encode(public_key).decode("ascii") != authorization["publicKey"] or len(signature) != 64 or len(public_key) != 32:
        raise ValueError("signed release base64 drift")
    if payload != statement(release_bytes):
        raise ValueError("signed release statement drift")
    with tempfile.TemporaryDirectory(prefix="testing-package-release-verify-") as directory:
        root = Path(directory)
        public_path, payload_path, signature_path = root / "public.der", root / "payload", root / "signature"
        public_path.write_bytes(bytes.fromhex("302a300506032b6570032100") + public_key)
        payload_path.write_bytes(pae(payload))
        signature_path.write_bytes(signature)
        result = subprocess.run(["openssl", "pkeyutl", "-verify", "-rawin", "-pubin", "-inkey", public_path, "-keyform", "DER", "-in", payload_path, "-sigfile", signature_path], capture_output=True)
        if result.returncode != 0:
            raise ValueError("committed Ed25519 signature verification failed")


def unsigned_outputs() -> dict[Path, bytes]:
    source = repository_commit()
    packages = pinned_commit(ROOT / ".fkst/conformance/fkst-packages.pin", "fkst-packages")
    substrate = pinned_commit(ROOT / ".fkst/substrate-ref", "fkst-substrate")
    bundle_value, package_content_sha256 = bundle()
    bundle_bytes = compact(bundle_value)
    manifest_value = manifest(package_content_sha256, source, packages, substrate)
    manifest_bytes = load_manifest_generator().canonical(manifest_value)
    release_bytes = compact(release_value(package_content_sha256, bundle_bytes, manifest_bytes, manifest_value, source, packages, substrate))
    return {BUNDLE_PATH: bundle_bytes, MANIFEST_PATH: manifest_bytes, RELEASE_PATH: release_bytes}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--seed-file", type=Path)
    arguments = parser.parse_args()
    try:
        expected = unsigned_outputs()
        if arguments.check:
            for path, data in expected.items():
                if not path.is_file() or path.read_bytes() != data:
                    raise ValueError(f"generated release drift: {path.relative_to(ROOT)}")
            if not ENVELOPE_PATH.is_file() or not AUTHORIZATION_PATH.is_file():
                raise ValueError("signed release artifacts are missing")
            verify_signed_artifacts(expected[RELEASE_PATH])
        else:
            for path, data in expected.items():
                path.write_bytes(data)
            envelope, authorization = signed_artifacts(expected[RELEASE_PATH], signing_seed(arguments.seed_file))
            ENVELOPE_PATH.write_bytes(envelope)
            AUTHORIZATION_PATH.write_bytes(authorization)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"error: {error}\n")
    print("testing-package-release-generation: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
