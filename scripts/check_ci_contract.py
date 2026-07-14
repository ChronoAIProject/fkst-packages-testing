#!/usr/bin/env python3
"""Validate CI revision inputs used by repository quality gates."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
REQUIRED_LINES = (
    "FKST_COMPETENCE_BASE_REF: ${{ github.event.pull_request.base.sha }}",
    "FKST_LUA_COVERAGE_BASE_REF: ${{ github.event.pull_request.base.sha || github.ref_name }}",
)
FORBIDDEN_LINES = (
    "FKST_LUA_COVERAGE_BASE_REF: ${{ github.base_ref || github.ref_name }}",
)


def main() -> int:
    source = WORKFLOW.read_text(encoding="utf-8")
    errors = [f"missing required CI contract: {line}" for line in REQUIRED_LINES if line not in source]
    errors.extend(f"forbidden ambiguous CI contract: {line}" for line in FORBIDDEN_LINES if line in source)
    if errors:
        for error in errors:
            print(f"FAIL ci-contract {error}", file=sys.stderr)
        return 1
    print("PASS ci-contract pull_request_base=commit-sha")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
