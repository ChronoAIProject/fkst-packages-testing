#!/usr/bin/env python3
"""Guard that fkst-packages has exactly one host coordinate (the dedicated pin file)."""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
if "__FKST_TEST_ROOT" in globals():
    ROOT = Path(globals()["__FKST_TEST_ROOT"]).resolve()
PIN_FILE = ROOT / ".fkst" / "conformance" / "fkst-packages.pin"
CHECKOUT = ROOT / ".fkst" / "run" / "fkst-packages-conformance"
EXCLUDED_REF_FILES = {".fkst-substrate-ref"}
SHA_RE = re.compile(r"[0-9a-f]{40}")


def fail(message: str) -> None:
    print(f"FAIL single-platform-pin {message}", file=sys.stderr)
    raise SystemExit(1)


def pin_rev() -> str:
    try:
        text = PIN_FILE.read_text(encoding="utf-8")
    except FileNotFoundError:
        fail(f"missing pin file path={PIN_FILE}")
    for line in text.splitlines():
        candidate = line.strip()
        if not candidate or candidate.startswith("#"):
            continue
        if not SHA_RE.fullmatch(candidate):
            fail(f"pin file first non-comment line is not a full git SHA path={PIN_FILE} line={candidate!r}")
        return candidate
    fail(f"pin file has no full git SHA path={PIN_FILE}")


def check_no_second_ref_pin(expected_rev: str) -> None:
    offenders: list[str] = []
    for path in ROOT.iterdir():
        if not path.is_file() or not path.name.endswith("-ref"):
            continue
        if path.name in EXCLUDED_REF_FILES:
            continue
        offenders.append(path.name)

    if offenders:
        fail(f"unexpected top-level ref files={','.join(sorted(offenders))}")


def checkout_head() -> str:
    git_dir = CHECKOUT / ".git"
    if not git_dir.exists():
        fail(f"missing hydrated checkout path={CHECKOUT}")

    result = subprocess.run(
        ["git", "-C", str(CHECKOUT), "rev-parse", "HEAD"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        fail(f"cannot read hydrated checkout HEAD path={CHECKOUT} stderr={result.stderr.strip()}")

    head = result.stdout.strip()
    if not SHA_RE.fullmatch(head):
        fail(f"hydrated checkout HEAD is not a full SHA head={head!r}")
    return head


def check_checkout_clean() -> None:
    result = subprocess.run(
        ["git", "-C", str(CHECKOUT), "status", "--porcelain"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        fail(f"cannot inspect hydrated checkout status path={CHECKOUT} stderr={result.stderr.strip()}")
    if result.stdout.strip():
        fail(f"hydrated checkout has local changes path={CHECKOUT}")


def main() -> int:
    expected_rev = pin_rev()
    check_no_second_ref_pin(expected_rev)

    head = checkout_head()
    if head != expected_rev:
        fail(f"checkout_head={head} pin_rev={expected_rev}")
    check_checkout_clean()

    print(f"PASS single-platform-pin pin_rev={expected_rev} checkout_head={head}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
