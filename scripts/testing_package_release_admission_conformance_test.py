#!/usr/bin/env python3
from __future__ import annotations

import json
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import testing_package_release_admission_conformance as conformance


ROOT = Path(__file__).resolve().parents[1]
RUNNER = ROOT / "scripts" / "testing_package_release_admission_conformance.py"


def write_adapter(path: Path, mode: str) -> None:
    path.write_text(
        "\n".join(
            (
                f"#!{sys.executable}",
                "import json,sys",
                "request=json.load(sys.stdin)",
                f"mode={mode!r}",
                "if request.get('schema') != 'testing-package-release-admission-conformance-request.v1': raise SystemExit(41)",
                "observation=request['case']['expected_observation']",
                "if mode == 'mismatch': observation=dict(observation); observation['case']='wrong'",
                "if mode == 'malformed': sys.stdout.write('{')",
                "elif mode == 'oversized': sys.stdout.write('x'*(1024*1024+1))",
                "else: json.dump(observation,sys.stdout,separators=(',',':'))",
                "sys.stdout.write('\\n')",
            )
        ),
        encoding="utf-8",
    )
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


def run(adapter: Path, *arguments: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(RUNNER), "--adapter", str(adapter), *arguments],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def main() -> int:
    corpus = conformance.load_corpus(conformance.DEFAULT_CORPUS)
    assert {case["name"] for case in corpus["cases"]} == conformance.REQUIRED_CASES
    baseline = next(release for release in corpus["releases"] if release["id"] == "baseline")
    update = next(release for release in corpus["releases"] if release["id"] == "update")
    prior = next(release for release in corpus["releases"] if release["id"] == "prior-admitted")
    older = next(release for release in corpus["releases"] if release["id"] == "older-unapproved")
    assert older["release_sequence"] < prior["release_sequence"] < baseline["release_sequence"] < update["release_sequence"]

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        passing = root / "passing-adapter"
        write_adapter(passing, "pass")
        result = run(passing)
        assert result.returncode == 0, result.stderr
        assert f"PASS {len(conformance.REQUIRED_CASES)} case(s)" in result.stdout

        selected = run(passing, "--case", "approved-rollback")
        assert selected.returncode == 0, selected.stderr
        assert "PASS approved-rollback" in selected.stdout and "PASS 1 case(s)" in selected.stdout

        unknown = run(passing, "--case", "not-a-case")
        assert unknown.returncode != 0 and "unknown selected cases" in unknown.stderr

        mismatching = root / "mismatching-adapter"
        write_adapter(mismatching, "mismatch")
        mismatch = run(mismatching, "--case", "explicit-update")
        assert mismatch.returncode != 0 and "observation mismatch" in mismatch.stderr

        malformed = root / "malformed-adapter"
        write_adapter(malformed, "malformed")
        invalid = run(malformed, "--case", "explicit-update")
        assert invalid.returncode != 0 and "did not emit one UTF-8 JSON observation" in invalid.stderr

        oversized = root / "oversized-adapter"
        write_adapter(oversized, "oversized")
        excessive = run(oversized, "--case", "explicit-update")
        assert excessive.returncode != 0 and "stdout exceeds the bounded output size" in excessive.stderr

        mutated_path = root / "mutated.json"
        mutated = json.loads(conformance.DEFAULT_CORPUS.read_text(encoding="utf-8"))
        mutated["releases"][1]["immutable_ref"] = "branch://dev"
        mutated_path.write_text(json.dumps(mutated), encoding="utf-8")
        rejected = subprocess.run(
            [sys.executable, str(RUNNER), "--corpus", str(mutated_path), "--adapter", str(passing)],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        assert rejected.returncode != 0 and "not an exact immutable reference" in rejected.stderr

    print("testing-package-release-admission-conformance: PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
