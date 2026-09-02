#!/usr/bin/env python3
from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import generate_testing_schema_release_attestation as generator


ROOT = Path(__file__).resolve().parents[1]
FIXTURE_SEED = ROOT / "scripts/fixtures/testing-schema-release-attestation/non-production-test-seed.base64"
GENERATOR = ROOT / "scripts/generate_testing_schema_release_attestation.py"
VERIFIER = ROOT / "scripts/verify_testing_schema_release_attestation.mjs"
RELEASE = ROOT / "schema-release/testing-package-schema-release.v1.json"
ENVELOPE = ROOT / "schema-release/testing-package-schema-release.v1.dsse.json"
AUTHORIZATION = ROOT / "schema-release/testing-package-schema-release.v1.key.json"


def run_generator(output: Path, authorization: Path, *, seed_file: Path | None = FIXTURE_SEED, environment: dict[str, str] | None = None, check: bool = False) -> subprocess.CompletedProcess[str]:
    command = [sys.executable, str(GENERATOR), "--release", str(RELEASE), "--output", str(output), "--authorization-output", str(authorization)]
    if seed_file is not None:
        command.extend(("--seed-file", str(seed_file)))
    if check:
        command.append("--check")
    return subprocess.run(command, cwd=ROOT, env=environment, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def verify(envelope: Path, authorization: Path = AUTHORIZATION) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["node", str(VERIFIER), "--release", str(RELEASE), "--envelope", str(envelope), "--authorization", str(authorization)], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def mutated_envelope(source: dict[str, object], destination: Path, mutate) -> None:
    value = json.loads(json.dumps(source))
    mutate(value)
    destination.write_text(json.dumps(value, separators=(",", ":")) + "\n", encoding="utf-8")


def main() -> int:
    if shutil.which("node") is None:
        raise AssertionError("Node is required for testing schema release attestation tests")
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        first = root / "first.dsse.json"
        first_key = root / "first.key.json"
        second = root / "second.dsse.json"
        second_key = root / "second.key.json"
        assert run_generator(first, first_key).returncode == 0
        assert run_generator(second, second_key).returncode == 0
        assert first.read_bytes() == second.read_bytes()
        assert first_key.read_bytes() == second_key.read_bytes()
        assert run_generator(first, first_key, check=True).returncode == 0
        envelope = json.loads(first.read_text(encoding="utf-8"))
        assert list(envelope) == ["payload", "payloadType", "signatures"]
        assert len(envelope["signatures"]) == 1
        assert list(envelope["signatures"][0]) == ["keyid", "sig"]
        assert verify(ENVELOPE).returncode == 0

        committed_envelope = json.loads(ENVELOPE.read_text(encoding="utf-8"))
        assert base64.b64decode(committed_envelope["payload"], validate=True) == RELEASE.read_bytes()

        payload = base64.b64decode(envelope["payload"], validate=True)
        assert payload == RELEASE.read_bytes()
        payload_mutation = root / "payload-mutated.json"
        mutated_envelope(envelope, payload_mutation, lambda value: value.__setitem__("payload", base64.b64encode(payload[:-1] + bytes([payload[-1] ^ 1])).decode("ascii")))
        assert verify(payload_mutation, first_key).returncode != 0
        signature_mutation = root / "signature-mutated.json"
        signature = base64.b64decode(envelope["signatures"][0]["sig"], validate=True)
        mutated_envelope(envelope, signature_mutation, lambda value: value["signatures"][0].__setitem__("sig", base64.b64encode(bytes([signature[0] ^ 1]) + signature[1:]).decode("ascii")))
        assert verify(signature_mutation, first_key).returncode != 0
        wrong_type = root / "wrong-type.json"
        mutated_envelope(envelope, wrong_type, lambda value: value.__setitem__("payloadType", "application/json"))
        assert verify(wrong_type, first_key).returncode != 0
        top_extension = root / "top-extension.json"
        mutated_envelope(envelope, top_extension, lambda value: value.__setitem__("ignored", True))
        assert verify(top_extension, first_key).returncode == 0
        signature_extension = root / "signature-extension.json"
        mutated_envelope(envelope, signature_extension, lambda value: value["signatures"][0].__setitem__("ignored", True))
        assert verify(signature_extension, first_key).returncode == 0
        both_extensions = root / "both-extensions.json"
        def add_both_extensions(value: dict[str, object]) -> None:
            value["ignored"] = True
            value["signatures"][0]["ignored"] = True
        mutated_envelope(envelope, both_extensions, add_both_extensions)
        assert verify(both_extensions, first_key).returncode == 0

        missing_output = root / "missing.dsse.json"
        missing_key = root / "missing.key.json"
        environment = os.environ.copy()
        environment.pop(generator.SEED_ENVIRONMENT_VARIABLE, None)
        result = run_generator(missing_output, missing_key, seed_file=None, environment=environment)
        assert result.returncode != 0 and not missing_output.exists() and not missing_key.exists()
        invalid_seed = root / "invalid-seed.base64"
        invalid_seed.write_text(base64.b64encode(b"short").decode("ascii") + "\n", encoding="ascii")
        invalid_output = root / "invalid.dsse.json"
        invalid_key = root / "invalid.key.json"
        result = run_generator(invalid_output, invalid_key, seed_file=invalid_seed)
        assert result.returncode != 0 and not invalid_output.exists() and not invalid_key.exists()
    print("testing-schema-release-attestation: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
