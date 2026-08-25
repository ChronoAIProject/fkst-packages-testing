#!/usr/bin/env python3
"""Validate CI revision inputs used by repository quality gates."""

from __future__ import annotations

import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "ci.yml"
RUNNER = ROOT / "scripts" / "run.sh"
REQUIRED_WORKFLOW_LINES = (
    "FKST_COMPETENCE_BASE_REF: ${{ github.event.pull_request.base.sha }}",
    "FKST_LUA_COVERAGE_BASE_REF: ${{ github.event.pull_request.base.sha || github.ref_name }}",
    "FKST_RATCHET_TARGET_REF: ${{ github.event.pull_request.base.sha || github.event.before }}",
    "scripts/python_test_deps.sh provision",
)
REQUIRED_RUNNER_LINES = (
    "env -u FKST_COMPETENCE_BASE_REF -u FKST_LUA_COVERAGE_BASE_REF -u FKST_RATCHET_TARGET_REF -u GITHUB_BASE_REF -u GITHUB_EVENT_NAME -u GITHUB_EVENT_PATH -u GITHUB_REF_TYPE",
)
FORBIDDEN_WORKFLOW_LINES = (
    "FKST_LUA_COVERAGE_BASE_REF: ${{ github.base_ref || github.ref_name }}",
)


def main() -> int:
    workflow = WORKFLOW.read_text(encoding="utf-8")
    runner = RUNNER.read_text(encoding="utf-8")
    errors = [
        f"missing required CI contract: {line}"
        for line in REQUIRED_WORKFLOW_LINES
        if line not in workflow
    ]
    errors.extend(
        f"missing required runner isolation: {line}"
        for line in REQUIRED_RUNNER_LINES
        if line not in runner
    )
    errors.extend(
        f"forbidden ambiguous CI contract: {line}"
        for line in FORBIDDEN_WORKFLOW_LINES
        if line in workflow
    )
    if errors:
        for error in errors:
            print(f"FAIL ci-contract {error}", file=sys.stderr)
        return 1
    print("PASS ci-contract pull_request_base=commit-sha")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
