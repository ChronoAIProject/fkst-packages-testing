#!/usr/bin/env python3
"""Generate a deterministic testing-package-manifest.v1 release identity."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
from pathlib import Path


SCHEMA = "testing-package-manifest.v1"
CANONICALIZATION = "fkst-testing-package-manifest-canonical-json.v1"
MANIFEST_NAME = "testing-package-manifest.json"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
SEMVER = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
ENTRYPOINTS = {"testing-runner.run", "testing-runner.supervise"}
CONTRACT_MAJORS = {"testing-runner.v1"}


def exact(value: str, pattern: re.Pattern[str], field: str) -> str:
    if not pattern.fullmatch(value):
        raise ValueError(f"{field} must be exact")
    return value


def canonical(value: object) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def package_digest(root: Path, excluded: str) -> str:
    digest = hashlib.sha256()
    if not root.is_dir():
        raise ValueError(f"package root is not a directory: {root}")
    for item in sorted(root.rglob("*"), key=lambda path: path.relative_to(root).as_posix().encode("utf-8")):
        relative = item.relative_to(root).as_posix()
        if relative == excluded or relative == ".git" or relative.startswith(".git/"):
            continue
        if item.is_dir() and not item.is_symlink():
            continue
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        if item.is_symlink():
            digest.update(b"l")
            digest.update(os.fsencode(os.readlink(item)))
        elif item.is_file():
            digest.update(b"f")
            digest.update(item.read_bytes())
        else:
            raise ValueError(f"unsupported package tree entry: {relative}")
        digest.update(b"\0")
    return digest.hexdigest()


def build_manifest(args: argparse.Namespace) -> dict[str, object]:
    package_id = args.package_id
    version = exact(args.package_version, SEMVER, "package_version")
    source_commit = exact(args.source_commit, COMMIT, "source_commit")
    fkst_packages = exact(args.fkst_packages_commit, COMMIT, "fkst_packages_commit")
    fkst_substrate = exact(args.fkst_substrate_commit, COMMIT, "fkst_substrate_commit")
    producer_version = exact(args.producer_version, SEMVER, "producer_version")
    exact(args.lua_runtime, SEMVER, "lua_runtime")
    if not args.entrypoint:
        raise ValueError("at least one entrypoint is required")
    if any(entrypoint not in ENTRYPOINTS for entrypoint in args.entrypoint):
        raise ValueError("unknown entrypoint")
    capabilities = sorted(set(args.capability))
    contracts = sorted(set(args.contract_major))
    if not contracts:
        raise ValueError("at least one contract major is required")
    if not set(contracts).issubset(CONTRACT_MAJORS):
        raise ValueError("unsupported contract major")
    if args.entrypoint_contract_major not in contracts:
        raise ValueError("entrypoint contract major must be supported")
    if set(args.canonicalization_profile) != {CANONICALIZATION}:
        raise ValueError("unsupported canonicalization profile")
    if not args.platform:
        raise ValueError("at least one platform is required")
    root = Path(args.package_root).resolve()
    output = Path(args.output)
    excluded = output.resolve().relative_to(root).as_posix() if output.resolve().is_relative_to(root) else MANIFEST_NAME
    manifest = {
        "schema": SCHEMA,
        "canonicalization": CANONICALIZATION,
        "package_id": package_id,
        "package_version": version,
        "source_commit": source_commit,
        "package_content_sha256": package_digest(root, excluded),
        "supported_contracts": {
            "majors": contracts,
            "canonicalization_profiles": sorted(set(args.canonicalization_profile)),
        },
        "entrypoints": [
            {"name": entrypoint, "contract_major": args.entrypoint_contract_major, "capabilities": capabilities}
            for entrypoint in args.entrypoint
        ],
        "semantic_capabilities": capabilities,
        "runtime_requirements": {"lua": args.lua_runtime, "platforms": sorted(set(args.platform))},
        "dependencies": {
            "fkst_packages": {"id": "fkst-packages", "commit": fkst_packages},
            "fkst_substrate": {"id": "fkst-substrate", "commit": fkst_substrate},
        },
        "producer": {"name": args.producer, "version": producer_version, "toolchain": args.toolchain},
        "creation_metadata": {"created_at": args.created_at, "build_id": args.build_id},
    }
    manifest["manifest_digest"] = hashlib.sha256(canonical(manifest)).hexdigest()
    return manifest


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--package-root", required=True)
    result.add_argument("--output", required=True)
    result.add_argument("--package-id", required=True)
    result.add_argument("--package-version", required=True)
    result.add_argument("--source-commit", required=True)
    result.add_argument("--entrypoint", action="append", required=True)
    result.add_argument("--entrypoint-contract-major", default="testing-runner.v1")
    result.add_argument("--contract-major", action="append", required=True)
    result.add_argument("--canonicalization-profile", action="append", required=True)
    result.add_argument("--capability", action="append", default=[])
    result.add_argument("--platform", action="append", required=True)
    result.add_argument("--lua-runtime", required=True)
    result.add_argument("--fkst-packages-commit", required=True)
    result.add_argument("--fkst-substrate-commit", required=True)
    result.add_argument("--producer", required=True)
    result.add_argument("--producer-version", required=True)
    result.add_argument("--toolchain", required=True)
    result.add_argument("--created-at", required=True)
    result.add_argument("--build-id", required=True)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        manifest = build_manifest(args)
    except ValueError as error:
        raise SystemExit(f"error: {error}") from error
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(canonical(manifest))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
