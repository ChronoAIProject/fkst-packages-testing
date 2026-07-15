#!/usr/bin/env python3
"""Validate the single pinned, read-only fkst-packages platform source."""

from __future__ import annotations

import hashlib
import re
import subprocess
import sys
import tomllib
from pathlib import Path
from urllib.parse import urlparse


ROOT = Path(__file__).resolve().parents[1]
PIN_FILE = ROOT / ".fkst" / "conformance" / "fkst-packages.pin"
WORKSPACE_FILE = ROOT / "fkst.workspace.toml"
LOCK_FILE = ROOT / "fkst.lock"
SUBSTRATE_PIN_FILE = ROOT / ".fkst" / "substrate-ref"
LEGACY_SUBSTRATE_PIN_FILE = ROOT / ".fkst-substrate-ref"
CHECKOUT = ROOT / ".fkst" / "run" / "fkst-packages-conformance"
EXPECTED_SOURCE_ID = "fkst-packages-platform"
EXPECTED_GIT_URL = "https://github.com/ChronoAIProject/fkst-packages.git"
EXPECTED_PACKAGES = {
    "github-proxy",
    "consensus",
    "github-devloop-intake",
    "github-devloop-workflow",
    "github-devloop",
    "github-devloop-pr",
    "github-devloop-decompose",
    "github-devloop-integration",
}
EXPECTED_EXTERNAL_LIBRARIES = {"forge", "devloop"}
SHA_RE = re.compile(r"[0-9a-f]{40}")


def fail(message: str) -> None:
    print(f"FAIL single-platform-pin {message}", file=sys.stderr)
    raise SystemExit(1)


def load_toml(path: Path) -> dict:
    try:
        with path.open("rb") as handle:
            return tomllib.load(handle)
    except FileNotFoundError:
        fail(f"missing TOML file path={path}")
    except tomllib.TOMLDecodeError as exc:
        fail(f"invalid TOML path={path} error={exc}")


def read_sha(path: Path, label: str) -> str:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError:
        fail(f"missing {label} path={path}")
    for line in lines:
        candidate = line.strip()
        if not candidate or candidate.startswith("#"):
            continue
        if not SHA_RE.fullmatch(candidate):
            fail(f"{label} first non-comment line is not a full git SHA path={path} line={candidate!r}")
        return candidate
    fail(f"{label} has no full git SHA path={path}")


def normalized_git_url(value: str) -> str:
    text = str(value or "").strip()
    if text.startswith("git@github.com:"):
        text = "https://github.com/" + text.removeprefix("git@github.com:")
    elif text.startswith("ssh://git@github.com/"):
        text = "https://github.com/" + text.removeprefix("ssh://git@github.com/")
    parsed = urlparse(text)
    if parsed.scheme != "https" or parsed.netloc.lower() != "github.com":
        fail(f"unsupported fkst-packages git URL value={value!r}")
    path = parsed.path.rstrip("/")
    if not path.endswith(".git"):
        path += ".git"
    return f"https://github.com{path}"


def one_table(document: dict, key: str, path: Path) -> dict:
    values = document.get(key)
    if not isinstance(values, list) or len(values) != 1 or not isinstance(values[0], dict):
        fail(f"expected exactly one [[{key}]] table path={path}")
    return values[0]


def check_workspace_and_lock(expected_rev: str) -> tuple[dict, set[str]]:
    workspace_doc = load_toml(WORKSPACE_FILE)
    lock_doc = load_toml(LOCK_FILE)
    workspace_source = one_table(workspace_doc, "external_sources", WORKSPACE_FILE)
    lock_source = one_table(lock_doc, "external_source", LOCK_FILE)

    for label, source in (("workspace", workspace_source), ("lock", lock_source)):
        if source.get("id") != EXPECTED_SOURCE_ID:
            fail(f"{label} source id={source.get('id')!r} expected={EXPECTED_SOURCE_ID!r}")
        if normalized_git_url(source.get("git", "")) != EXPECTED_GIT_URL:
            fail(f"{label} git URL does not resolve to {EXPECTED_GIT_URL}")

    if workspace_source.get("rev") != expected_rev:
        fail(f"workspace rev={workspace_source.get('rev')!r} pin_rev={expected_rev}")
    intent = lock_source.get("intent") or {}
    resolved = lock_source.get("resolved") or {}
    if intent.get("rev") != expected_rev or resolved.get("rev") != expected_rev:
        fail(
            "lock revisions do not match pin "
            f"intent={intent.get('rev')!r} resolved={resolved.get('rev')!r} pin_rev={expected_rev}"
        )

    packages = workspace_source.get("packages")
    if not isinstance(packages, list) or set(packages) != EXPECTED_PACKAGES or len(packages) != len(EXPECTED_PACKAGES):
        fail(
            "workspace platform packages must match the minimal allowlist "
            f"actual={sorted(packages or [])} expected={sorted(EXPECTED_PACKAGES)}"
        )

    workspace_libraries = workspace_source.get("libraries")
    if not isinstance(workspace_libraries, list) or set(workspace_libraries) != EXPECTED_EXTERNAL_LIBRARIES:
        fail(
            "workspace external libraries must be forge and devloop "
            f"actual={sorted(workspace_libraries or [])}"
        )
    locked_libraries = {
        item.get("name")
        for item in lock_source.get("libraries", [])
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    if locked_libraries != EXPECTED_EXTERNAL_LIBRARIES:
        fail(f"lock external libraries={sorted(locked_libraries)} expected={sorted(EXPECTED_EXTERNAL_LIBRARIES)}")
    return workspace_doc, locked_libraries


def active_local_library_names(workspace_doc: dict) -> set[str]:
    workspace = workspace_doc.get("workspace") or {}
    roots = workspace.get("libraries")
    if not isinstance(roots, list) or not roots:
        fail("workspace.libraries must be an explicit non-empty list")
    names: set[str] = set()
    for relative in roots:
        if not isinstance(relative, str) or "*" in relative:
            fail(f"workspace library roots must be explicit paths value={relative!r}")
        manifest = ROOT / relative / "fkst.toml"
        document = load_toml(manifest)
        library = document.get("library") or {}
        name = library.get("name") or document.get("name")
        if not isinstance(name, str) or not name:
            fail(f"workspace library manifest has no name path={manifest}")
        if name in names:
            fail(f"duplicate active local library name={name}")
        names.add(name)
    return names


def tree_digest(root: Path) -> tuple[str, list[str]]:
    digest = hashlib.sha256()
    paths: list[str] = []
    if not root.is_dir():
        fail(f"missing mirrored library root path={root}")
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix()
        if relative == ".DS_Store" or "__pycache__" in path.parts:
            continue
        paths.append(relative)
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest(), paths


def check_forge_mirror() -> None:
    local_digest, local_paths = tree_digest(ROOT / ".fkst" / "local-libraries" / "forge")
    platform_digest, platform_paths = tree_digest(CHECKOUT / "libraries" / "forge")
    if local_paths != platform_paths or local_digest != platform_digest:
        fail("local forge mirror differs from the pinned platform export")


def git_output(*args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(CHECKOUT), *args],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        fail(f"git {' '.join(args)} failed path={CHECKOUT} stderr={result.stderr.strip()}")
    return result.stdout.strip()


def check_checkout(expected_rev: str) -> None:
    if not (CHECKOUT / ".git").exists():
        fail(f"missing hydrated checkout path={CHECKOUT}")
    head = git_output("rev-parse", "HEAD")
    if head != expected_rev:
        fail(f"checkout_head={head} pin_rev={expected_rev}")
    if git_output("status", "--porcelain=v1"):
        fail("hydrated fkst-packages checkout must remain clean and read-only")
    remote = normalized_git_url(git_output("remote", "get-url", "origin"))
    if remote != EXPECTED_GIT_URL:
        fail(f"checkout origin={remote!r} expected={EXPECTED_GIT_URL!r}")


def check_substrate_pin() -> None:
    local_pin = read_sha(SUBSTRATE_PIN_FILE, "host substrate pin")
    platform_pin = read_sha(CHECKOUT / ".fkst" / "substrate-ref", "platform substrate pin")
    if local_pin != platform_pin:
        fail(f"host substrate pin={local_pin} platform substrate pin={platform_pin}")
    if LEGACY_SUBSTRATE_PIN_FILE.exists():
        fail(f"legacy root substrate pin must be removed path={LEGACY_SUBSTRATE_PIN_FILE}")


def main() -> int:
    expected_rev = read_sha(PIN_FILE, "platform pin")
    workspace_doc, external_libraries = check_workspace_and_lock(expected_rev)
    local_libraries = active_local_library_names(workspace_doc)
    overlap = local_libraries & external_libraries
    if overlap != {"forge"}:
        fail(
            "local/external library overlap must be the source-scoped forge mirror only "
            f"names={','.join(sorted(overlap)) or '<none>'}"
        )
    check_checkout(expected_rev)
    check_forge_mirror()
    check_substrate_pin()
    print(
        "PASS single-platform-pin "
        f"pin_rev={expected_rev} checkout=clean source={EXPECTED_SOURCE_ID} "
        f"packages={len(EXPECTED_PACKAGES)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
