#!/usr/bin/env python3
from __future__ import annotations

import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RUN_SH = ROOT / "scripts" / "run.sh"


def git_lines(*arguments: str) -> list[str]:
    result = subprocess.run(
        ["git", "-C", str(ROOT), *arguments],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
    )
    return result.stdout.splitlines()


def changed_paths() -> list[str]:
    return sorted(
        set(git_lines("diff", "--name-only", "HEAD"))
        | set(git_lines("ls-files", "--others", "--exclude-standard"))
    )


def affected_packages(paths: list[str]) -> list[str] | None:
    packages = set()
    for value in paths:
        path = Path(value)
        if value == "fkst.lock" or path.parts[:2] in ((".fkst", "run"), (".testing", "runs")):
            continue
        if len(path.parts) < 3 or path.parts[0] != "packages":
            return None
        package_name = path.parts[1]
        if not (ROOT / "packages" / package_name).is_dir():
            return None
        packages.add(package_name)
    return sorted(packages)


def run_test(package_name: str | None = None) -> int:
    command = [str(RUN_SH), "test"]
    if package_name is not None:
        command.append(package_name)
    return subprocess.run(command, cwd=ROOT, check=False).returncode


def main() -> int:
    paths = changed_paths()
    packages = affected_packages(paths)
    if not paths or packages is None or not packages:
        reason = "no changed paths" if not paths else "broad repository changes"
        print(f"test-affected: {reason} detected; running full repository tests", flush=True)
        return run_test()

    failed = False
    for package_name in packages:
        print(f"test-affected: running package test for {package_name}", flush=True)
        failed = run_test(package_name) != 0 or failed
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
