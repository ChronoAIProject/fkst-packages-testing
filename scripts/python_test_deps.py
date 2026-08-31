#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.metadata
import json
import os
import shutil
import subprocess
import sys
import sysconfig
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TARGET = ROOT / ".fkst" / "run" / "python-test-deps"
LOCK = ROOT / "scripts" / "python-test-requirements.lock"
STAMP = ".fkst-python-test-deps.json"
EXPECTED = {
    "attrs": "26.1.0",
    "jsonschema": "4.26.0",
    "jsonschema-specifications": "2025.9.1",
    "referencing": "0.37.0",
    "rfc3986-validator": "0.1.1",
    "rpds-py": "2026.6.3",
    "typing-extensions": "4.16.0",
}
IMPORTS = (
    "attrs",
    "rfc3986_validator",
    "jsonschema",
    "jsonschema_specifications",
    "referencing",
    "rpds",
    "typing_extensions",
)


def cache_identity() -> dict[str, object]:
    return {
        "lock_sha256": hashlib.sha256(LOCK.read_bytes()).hexdigest(),
        "python": f"{sys.version_info.major}.{sys.version_info.minor}",
        "cache_tag": sys.implementation.cache_tag,
        "platform": sysconfig.get_platform(),
        "packages": EXPECTED,
    }


def fail(message: str) -> None:
    raise SystemExit(
        "error: "
        + message
        + "; run scripts/python_test_deps.sh provision"
    )


def verify(target: Path) -> None:
    target = target.resolve()
    if os.environ.get("PYTHONNOUSERSITE") != "1":
        fail("Python test dependency verification requires PYTHONNOUSERSITE=1")
    if os.environ.get("PYTHONPATH") != str(target):
        fail(f"Python test dependency verification requires exact PYTHONPATH={target}")
    if not sys.flags.no_site:
        fail("Python test dependency verification requires Python -S isolation")
    stamp_path = target / STAMP
    if not stamp_path.is_file():
        fail(f"Python test dependency cache is unprovisioned: {target}")
    try:
        observed_stamp = json.loads(stamp_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"Python test dependency cache stamp is unreadable: {error}")
    if observed_stamp != cache_identity():
        fail(f"Python test dependency cache is stale for this lock/interpreter: {target}")

    observed: dict[str, str] = {}
    for distribution in importlib.metadata.distributions(path=[str(target)]):
        name = distribution.metadata["Name"].lower().replace("_", "-")
        if name in observed:
            fail(f"Python test dependency cache contains duplicate distribution {name}")
        observed[name] = distribution.version
    if observed != EXPECTED:
        fail(f"Python test dependency versions differ: expected {EXPECTED}, observed {observed}")

    for module_name in IMPORTS:
        module = importlib.import_module(module_name)
        module_path = Path(module.__file__ or "").resolve()
        if not module_path.is_relative_to(target):
            fail(f"Python test dependency {module_name} resolved outside cache: {module_path}")
    format_checker = importlib.import_module("jsonschema").FormatChecker()
    if not (
        format_checker.conforms("https://example.test/schema.json", "uri")
        and not format_checker.conforms("relative/schema.json", "uri")
        and format_checker.conforms("relative/schema.json", "uri-reference")
        and not format_checker.conforms(
            "https://example.test:bad/schema.json",
            "uri-reference",
        )
    ):
        fail("jsonschema uri and uri-reference format checks are not active")
    print(
        "PASS python-test-deps "
        f"jsonschema={EXPECTED['jsonschema']} "
        f"rfc3986-validator={EXPECTED['rfc3986-validator']} "
        f"path={target} cache=verified formats=uri,uri-reference"
    )


def provision() -> None:
    target = TARGET.resolve()
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(f"{target.name}.tmp-{os.getpid()}")
    shutil.rmtree(temporary, ignore_errors=True)
    environment = os.environ.copy()
    environment["PYTHONNOUSERSITE"] = "1"
    environment.pop("PYTHONPATH", None)
    try:
        subprocess.run(
            [
                sys.executable,
                "-m",
                "pip",
                "install",
                "--disable-pip-version-check",
                "--no-deps",
                "--only-binary=:all:",
                "--require-hashes",
                "--target",
                str(temporary),
                "--requirement",
                str(LOCK),
            ],
            check=True,
            env=environment,
        )
        (temporary / STAMP).write_text(
            json.dumps(cache_identity(), indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        verify_environment = environment.copy()
        verify_environment["PYTHONPATH"] = str(temporary.resolve())
        subprocess.run(
            [sys.executable, "-S", "-B", str(Path(__file__).resolve()), "verify", str(temporary)],
            check=True,
            env=verify_environment,
        )
        shutil.rmtree(target, ignore_errors=True)
        temporary.replace(target)
    finally:
        shutil.rmtree(temporary, ignore_errors=True)
    print(f"provisioned Python test dependencies: {target}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("provision", "verify"))
    parser.add_argument("target", nargs="?", type=Path)
    arguments = parser.parse_args()
    if arguments.command == "provision":
        if arguments.target is not None:
            parser.error("provision does not accept a target")
        provision()
    else:
        verify(arguments.target or TARGET)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
