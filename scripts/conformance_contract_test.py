#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
import tomllib
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUN_SH = ROOT / "scripts" / "run.sh"
COMPOSED_ROOTS = ROOT / ".fkst" / "conformance" / "composed-roots"


@dataclass(frozen=True)
class RuleFixture:
    relative_path: str
    sentinel: str


def joined(*parts: str) -> str:
    return "".join(parts)


RULE_FIXTURES = {
    "browser-observation-no-fixed-host-config": RuleFixture(
        "departments/contract_fixture/main.lua", joined("APP", "_FIXED_ENDPOINT")
    ),
    "environment-factory-shell-free": RuleFixture(
        "contract_fixture.lua", joined("os", ".execute")
    ),
    "environment-factory-js-shell-free": RuleFixture(
        "bin/contract_fixture.js", joined("shell", ": true")
    ),
    "environment-factory-pointer-only-events": RuleFixture(
        "departments/contract_fixture/main.lua", joined("std", "out")
    ),
    "environment-factory-does-not-own-testing": RuleFixture(
        "departments/contract_fixture/main.lua", joined("module-testing", "-pipeline")
    ),
    "browser-observation-no-legacy-runner": RuleFixture(
        "departments/contract_fixture/main.lua", joined("agentic", "_testing")
    ),
    "browser-observation-no-browser-automation-deps": RuleFixture(
        "lib/contract_fixture.js", joined("play", "wright")
    ),
    "no-browser-secret-fields": RuleFixture(
        "departments/contract_fixture/main.lua", joined("pass", "word")
    ),
    "module-test-loop-no-fixed-host-config": RuleFixture(
        "departments/contract_fixture/main.lua", joined("http", "://localhost:", "4312")
    ),
    "online-regression-no-fixed-host-config": RuleFixture(
        "departments/contract_fixture/main.lua",
        joined("https", "://", "service", ".invalid", "/health"),
    ),
    "platform-test-loop-no-fixed-host-config": RuleFixture(
        "departments/contract_fixture/main.lua", joined("APP", "_FIXED_ENDPOINT")
    ),
    "artifact-summary-pointer-only": RuleFixture(
        "departments/contract_fixture/main.lua", joined("raw_", "stdout")
    ),
    "publication-pointer-only": RuleFixture(
        "departments/contract_fixture/main.lua", joined("full_", "report")
    ),
    "testing-discovery-no-fixed-host-config": RuleFixture(
        "departments/contract_fixture/main.lua", joined("HOST", "_FIXED_ENDPOINT")
    ),
    "testing-discovery-pointer-only": RuleFixture(
        "departments/contract_fixture/main.lua", joined("raw_", "dom")
    ),
    "module-testing-pipeline-pointer-only": RuleFixture(
        "departments/contract_fixture/main.lua", joined("attachment_", "body")
    ),
    "testing-design-pointer-only-events": RuleFixture(
        "departments/contract_fixture/main.lua", joined("raw_", "prompt")
    ),
    "testing-design-no-target-execution": RuleFixture(
        "departments/contract_fixture/main.lua", joined("target_", "command")
    ),
    "workflow-qa-no-shell-or-network": RuleFixture(
        "departments/contract_fixture/main.lua", joined("os", ".execute")
    ),
    "workflow-qa-no-dev-intake-consumer": RuleFixture(
        "departments/contract_fixture/main.lua", joined("devloop_", "intake_candidate")
    ),
    "no-large-inline-test-bodies": RuleFixture(
        "departments/contract_fixture/main.lua", joined("stdout_", "body")
    ),
}


def read_toml(path: Path) -> dict:
    return tomllib.loads(path.read_text(encoding="utf-8"))


def package_inventory() -> list[tuple[str, Path, dict]]:
    inventory = []
    for manifest_path in sorted((ROOT / "packages").glob("*/fkst.toml")):
        manifest = read_toml(manifest_path)
        package_name = manifest.get("name")
        conformance = manifest.get("conformance")
        if not isinstance(package_name, str) or not isinstance(conformance, dict):
            raise AssertionError(f"invalid package conformance declaration: {manifest_path}")
        pack_relative = conformance.get("pack")
        if not isinstance(pack_relative, str):
            raise AssertionError(f"missing conformance pack declaration: {manifest_path}")
        pack_path = manifest_path.parent / pack_relative
        if not pack_path.is_file():
            raise AssertionError(f"declared conformance pack is missing: {pack_path}")
        inventory.append((package_name, manifest_path.parent, read_toml(pack_path)))
    if not inventory:
        raise AssertionError("no package-owned conformance packs found")
    return inventory


def write_sentinel(package_root: Path, relative_path: str, sentinel: str) -> None:
    target = package_root / relative_path
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.suffix == ".js":
        body = f"const forbiddenContractFixture = {sentinel!r};\n"
    else:
        body = f"local forbidden_contract_fixture = {sentinel!r}\n"
    target.write_text(body, encoding="utf-8")


def fixture_copy(source: Path, temporary_root: Path, suffix: str) -> Path:
    destination = temporary_root / f"{source.name}-{suffix}"
    shutil.copytree(source, destination)
    return destination


def run_fixture(package_name: str, package_root: Path, roots_file: Path = COMPOSED_ROOTS) -> subprocess.CompletedProcess[str]:
    command = """
source "$1"
shared="$CHECKOUT"
PYTHON_BIN="$(resolve_python)"
COMPOSED_ROOTS_FILE="$4"
run_conformance_fixture "$2" "$3"
"""
    return subprocess.run(
        ["bash", "-c", command, "conformance-contract", str(RUN_SH), package_name, str(package_root), str(roots_file)],
        cwd=ROOT,
        env=os.environ.copy(),
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )


def assert_success(result: subprocess.CompletedProcess[str], context: str) -> None:
    if result.returncode != 0:
        raise AssertionError(f"{context} failed with {result.returncode}:\n{result.stdout}")


def assert_failure(result: subprocess.CompletedProcess[str], context: str, expected: str) -> None:
    if result.returncode == 0:
        raise AssertionError(f"{context} unexpectedly passed:\n{result.stdout}")
    if expected not in result.stdout:
        raise AssertionError(f"{context} failed without {expected!r}:\n{result.stdout}")


def rule_ids(pack: dict, package_name: str) -> list[str]:
    if pack.get("owner_package") != package_name:
        raise AssertionError(f"{package_name}: pack owner does not match package")
    rules = pack.get("rules")
    if not isinstance(rules, list) or not rules:
        raise AssertionError(f"{package_name}: conformance pack has no rules")
    identifiers = []
    for rule in rules:
        if not isinstance(rule, dict) or rule.get("kind") != "text_forbid_regex":
            raise AssertionError(f"{package_name}: unsupported conformance rule fixture shape")
        identifier = rule.get("id")
        if not isinstance(identifier, str):
            raise AssertionError(f"{package_name}: conformance rule has no id")
        identifiers.append(identifier)
    return identifiers


def test_package_pack(package_name: str, source: Path, pack: dict, temporary_root: Path) -> int:
    identifiers = rule_ids(pack, package_name)
    unknown = sorted(set(identifiers) - RULE_FIXTURES.keys())
    if unknown:
        raise AssertionError(f"{package_name}: no negative fixture for rules: {', '.join(unknown)}")

    valid = fixture_copy(source, temporary_root, "valid")
    assert_success(run_fixture(package_name, valid), f"{package_name} valid fixture")

    excluded = fixture_copy(source, temporary_root, "excluded")
    for index, identifier in enumerate(identifiers, start=1):
        fixture = RULE_FIXTURES[identifier]
        extension = Path(fixture.relative_path).suffix
        write_sentinel(excluded, f"tests/conformance_contract_{index}{extension}", fixture.sentinel)
    assert_success(run_fixture(package_name, excluded), f"{package_name} excluded test fixture")

    for identifier in identifiers:
        violating = fixture_copy(source, temporary_root, f"violation-{identifier}")
        fixture = RULE_FIXTURES[identifier]
        write_sentinel(violating, fixture.relative_path, fixture.sentinel)
        assert_failure(
            run_fixture(package_name, violating),
            f"{package_name} production violation for {identifier}",
            identifier,
        )
    return 2 + len(identifiers)


def test_composed_roots_fail_closed(inventory: list[tuple[str, Path, dict]], temporary_root: Path) -> int:
    composed = []
    for package_name, source, _pack in inventory:
        manifest = read_toml(source / "fkst.toml")
        if isinstance(manifest.get("event_deps"), dict):
            composed.append((package_name, source))
    if not composed:
        raise AssertionError("no composed package available for roots fail-closed coverage")

    package_name, source = composed[0]
    fixture = fixture_copy(source, temporary_root, "roots-fail-closed")
    missing = temporary_root / "missing-composed-roots"
    missing.write_text("# deliberately missing the composed package entry\n", encoding="utf-8")
    assert_failure(
        run_fixture(package_name, fixture, missing),
        f"{package_name} missing composed roots",
        "has no .fkst/conformance/composed-roots entry",
    )

    invalid = temporary_root / "invalid-composed-roots"
    invalid.write_text(f"{package_name} missing-contract-root\n", encoding="utf-8")
    assert_failure(
        run_fixture(package_name, fixture, invalid),
        f"{package_name} invalid composed roots",
        "missing-contract-root",
    )
    return 2


def main() -> int:
    if not RUN_SH.is_file():
        raise AssertionError(f"runner is missing: {RUN_SH}")
    bin_path = os.environ.get("BIN")
    if not bin_path or not os.access(bin_path, os.X_OK):
        raise AssertionError("BIN must name an executable framework for conformance contract tests")
    checkout = ROOT / ".fkst" / "run" / "fkst-packages-conformance"
    if not checkout.is_dir():
        raise AssertionError(f"pinned platform checkout is missing: {checkout}")

    inventory = package_inventory()
    declared_rules = {
        identifier
        for package_name, _source, pack in inventory
        for identifier in rule_ids(pack, package_name)
    }
    unused = sorted(RULE_FIXTURES.keys() - declared_rules)
    if unused:
        raise AssertionError(f"stale conformance fixtures: {', '.join(unused)}")

    count = 0
    with tempfile.TemporaryDirectory(prefix="fkst-conformance-contract-") as temporary:
        temporary_root = Path(temporary)
        for package_name, source, pack in inventory:
            count += test_package_pack(package_name, source, pack, temporary_root)
        count += test_composed_roots_fail_closed(inventory, temporary_root)
    print(f"OK: {count} hermetic conformance contract cases across {len(inventory)} package packs")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
