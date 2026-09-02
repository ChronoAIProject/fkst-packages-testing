#!/usr/bin/env python3
"""Generate the deterministic DSSE attestation for the testing schema release."""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import tempfile
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


ROOT = Path(__file__).resolve().parents[1]
RELEASE_PATH = ROOT / "schema-release" / "testing-package-schema-release.v1.json"
ENVELOPE_PATH = ROOT / "schema-release" / "testing-package-schema-release.v1.dsse.json"
AUTHORIZATION_PATH = ROOT / "schema-release" / "testing-package-schema-release.v1.key.json"
PAYLOAD_TYPE = "application/vnd.in-toto+json"
STATEMENT_TYPE = "https://in-toto.io/Statement/v1"
PREDICATE_TYPE = (
    "https://chronoaiproject.github.io/fkst-packages-testing/attestations/"
    "testing-package-schema-release/v1"
)
SUBJECT_NAME = "schema-release/testing-package-schema-release.v1.json"
KEY_ID = "fkst-packages-testing-schema-release-v1-2026-09-02"
SEED_ENVIRONMENT_VARIABLE = "FKST_TESTING_SCHEMA_RELEASE_SIGNING_SEED"


def compact_json(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def persisted_json(value: object) -> bytes:
    return compact_json(value) + b"\n"


def decode_base64(value: str, field: str, expected_length: int) -> bytes:
    try:
        encoded = value.encode("ascii")
    except UnicodeEncodeError as error:
        raise ValueError(f"{field} must be standard base64") from error
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except binascii.Error as error:
        raise ValueError(f"{field} must be standard base64") from error
    if base64.b64encode(decoded) != encoded:
        raise ValueError(f"{field} must use canonical standard base64")
    if len(decoded) != expected_length:
        raise ValueError(f"{field} must decode to exactly {expected_length} bytes")
    return decoded


def signing_seed(seed_file: Path | None) -> bytes:
    environment_value = os.environ.get(SEED_ENVIRONMENT_VARIABLE)
    if seed_file is not None and environment_value is not None:
        raise ValueError(
            f"use either --seed-file or {SEED_ENVIRONMENT_VARIABLE}, not both"
        )
    if seed_file is not None:
        try:
            value = seed_file.read_text(encoding="ascii").strip()
        except (OSError, UnicodeError) as error:
            raise ValueError("signing seed file is unreadable") from error
    elif environment_value is not None:
        value = environment_value
    else:
        raise ValueError(
            f"signing seed is required through --seed-file or {SEED_ENVIRONMENT_VARIABLE}"
        )
    return decode_base64(value, "signing seed", 32)


def statement_bytes(release_bytes: bytes) -> bytes:
    statement = {
        "_type": STATEMENT_TYPE,
        "predicate": {},
        "predicateType": PREDICATE_TYPE,
        "subject": [
            {
                "digest": {"sha256": hashlib.sha256(release_bytes).hexdigest()},
                "name": SUBJECT_NAME,
            }
        ],
    }
    return compact_json(statement)


def pae(payload: bytes) -> bytes:
    payload_type = PAYLOAD_TYPE.encode("utf-8")
    return b"DSSEv1 " + str(len(payload_type)).encode("ascii") + b" " + payload_type + b" " + str(len(payload)).encode("ascii") + b" " + payload


def build(release_bytes: bytes, seed: bytes) -> tuple[bytes, bytes]:
    private_key = Ed25519PrivateKey.from_private_bytes(seed)
    public_key = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    payload = statement_bytes(release_bytes)
    signature = private_key.sign(pae(payload))
    envelope = {
        "payloadType": PAYLOAD_TYPE,
        "payload": base64.b64encode(payload).decode("ascii"),
        "signatures": [
            {
                "keyid": KEY_ID,
                "sig": base64.b64encode(signature).decode("ascii"),
            }
        ],
    }
    authorization = {
        "algorithm": "ed25519",
        "authorization": {
            "payloadType": PAYLOAD_TYPE,
            "predicateType": PREDICATE_TYPE,
            "subject": SUBJECT_NAME,
        },
        "keyid": KEY_ID,
        "publicKey": base64.b64encode(public_key).decode("ascii"),
        "schema": "testing-package-schema-release-key-authorization.v1",
    }
    return persisted_json(envelope), persisted_json(authorization)


def write_atomic(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    file_descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(file_descriptor, "wb") as handle:
            os.fchmod(handle.fileno(), 0o644)
            handle.write(data)
        temporary_path.replace(path)
    finally:
        temporary_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--release", type=Path, default=RELEASE_PATH)
    parser.add_argument("--output", type=Path, default=ENVELOPE_PATH)
    parser.add_argument("--authorization-output", type=Path, default=AUTHORIZATION_PATH)
    parser.add_argument("--seed-file", type=Path)
    parser.add_argument("--check", action="store_true")
    arguments = parser.parse_args()
    try:
        seed = signing_seed(arguments.seed_file)
        release_bytes = arguments.release.read_bytes()
        envelope_bytes, authorization_bytes = build(release_bytes, seed)
        if arguments.check:
            if not arguments.output.is_file() or arguments.output.read_bytes() != envelope_bytes:
                raise ValueError(f"generated attestation drift: {arguments.output}")
            if not arguments.authorization_output.is_file() or arguments.authorization_output.read_bytes() != authorization_bytes:
                raise ValueError(f"generated key authorization drift: {arguments.authorization_output}")
        else:
            write_atomic(arguments.output, envelope_bytes)
            write_atomic(arguments.authorization_output, authorization_bytes)
    except (OSError, ValueError) as error:
        parser.exit(1, f"error: {error}\n")
    print("testing-schema-release-attestation: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
