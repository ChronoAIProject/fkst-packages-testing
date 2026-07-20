#!/usr/bin/env python3
from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "scripts" / "engine_provenance.sh"
PIN = "1" * 40
STALE_PIN = "2" * 40


def executable(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(body).lstrip(), encoding="utf-8")
    path.chmod(0o755)
    return path


class Harness:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="fkst-engine-provenance-")
        self.root = Path(self.temporary.name) / "repo"
        self.root.mkdir()
        (self.root / ".fkst").mkdir()
        (self.root / ".fkst" / "substrate-ref").write_text(PIN + "\n", encoding="utf-8")
        self.cache_bin = self.root / "cache" / "fkst-framework"
        self.built_bin = self.root / "built" / "fkst-framework"
        self.build_log = self.root / "build.log"
        self.path_bin_dir = self.root / "path-bin"
        self.path_bin_dir.mkdir()

    def close(self) -> None:
        self.temporary.cleanup()

    def engine(self, path: Path, pin: str = PIN, available: bool = True) -> Path:
        if not available:
            return executable(path, "#!/usr/bin/env sh\nexit 23\n")
        return executable(
            path,
            f"""
            #!/usr/bin/env sh
            [ "${{1:-}}" = "init-package-repo" ] || exit 0
            mkdir -p .git
            printf '%s\n' '{pin}' > .fkst-substrate-ref
            printf '%s\n' 'init-package-repo substrate_ref={pin}'
            """,
        )

    def run(
        self,
        *,
        explicit: Path | None = None,
        env_bin: Path | None = None,
        path_bin: Path | None = None,
        sibling_bin: Path | None = None,
        cache_bin: Path | None = None,
        built_bin: Path | None = None,
        ci: bool = False,
        readonly: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        if env_bin is not None:
            (self.root / ".fkst" / "env").write_text(f"BIN={env_bin}\n", encoding="utf-8")
        if path_bin is not None:
            shutil.copy2(path_bin, self.path_bin_dir / "fkst-framework")
        if sibling_bin is not None:
            target = self.root.parent / "fkst-substrate" / "target" / "debug" / "fkst-framework"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(sibling_bin, target)
        if cache_bin is not None:
            self.cache_bin.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(cache_bin, self.cache_bin)
        if built_bin is not None:
            self.built_bin.parent.mkdir(parents=True, exist_ok=True)
            if built_bin != self.built_bin:
                shutil.copy2(built_bin, self.built_bin)

        driver = f"""
        set -euo pipefail
        source {SOURCE!s}
        bootstrap_parse_pin() {{ printf '%s\n%s\n%s\n' ChronoAIProject fkst-substrate {PIN}; }}
        bootstrap_cache_root() {{ printf '%s\n' {self.cache_bin.parent!s}; }}
        bootstrap_cache_bin_path() {{ printf '%s\n' {self.cache_bin!s}; }}
        bootstrap_bin_on_total_miss() {{
          printf 'build\n' >> {self.build_log!s}
          [ -x {self.built_bin!s} ] || return 41
          printf '%s\n' {self.built_bin!s}
        }}
        if ! resolve_pinned_engine {self.root!s} {'readonly' if readonly else 'bootstrap'}; then
          printf 'ERROR=%s\n' "$RESOLVE_BIN_ERROR"
          exit 1
        fi
        printf 'RESULT_BIN=%s\n' "$RESOLVED_BIN"
        printf 'RESULT_PIN=%s\n' "$RESOLVED_ENGINE_PIN"
        printf 'ENGINE_VER=%s\n' "$FKST_ENGINE_VER"
        """
        environment = os.environ.copy()
        environment.pop("BIN", None)
        environment.pop("CI", None)
        environment.pop("GITHUB_ACTIONS", None)
        environment["PATH"] = str(self.path_bin_dir) + os.pathsep + environment.get("PATH", "")
        if explicit is not None:
            environment["BIN"] = str(explicit)
        if ci:
            environment["CI"] = "1"
        return subprocess.run(
            ["/bin/bash", "-c", textwrap.dedent(driver)],
            cwd=self.root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )


class EngineProvenanceTest(unittest.TestCase):
    def harness(self) -> Harness:
        harness = Harness()
        self.addCleanup(harness.close)
        return harness

    def assert_success(self, result: subprocess.CompletedProcess[str], selected: Path) -> None:
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn(f"RESULT_BIN={selected}", result.stdout)
        self.assertIn(f"RESULT_PIN={PIN}", result.stdout)
        self.assertIn(f"ENGINE_VER={PIN[:12]}", result.stdout)

    def test_matching_explicit_bin_and_ci_bin_are_accepted(self) -> None:
        for ci in (False, True):
            harness = self.harness()
            candidate = harness.engine(harness.root / f"explicit-{ci}")
            self.assert_success(harness.run(explicit=candidate, ci=ci), candidate)

    def test_stale_explicit_bin_fails_closed_without_build(self) -> None:
        harness = self.harness()
        candidate = harness.engine(harness.root / "explicit-stale", STALE_PIN)
        result = harness.run(explicit=candidate, built_bin=harness.engine(harness.built_bin))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"expected={PIN}", result.stdout)
        self.assertIn(f"observed={STALE_PIN}", result.stdout)
        self.assertIn(f"selected={candidate}", result.stdout)
        self.assertFalse(harness.build_log.exists())

    def test_matching_env_bin_is_accepted_and_stale_env_bin_fails_closed(self) -> None:
        valid_harness = self.harness()
        valid = valid_harness.engine(valid_harness.root / "env-valid")
        self.assert_success(valid_harness.run(env_bin=valid), valid)

        stale_harness = self.harness()
        stale = stale_harness.engine(stale_harness.root / "env-stale", STALE_PIN)
        result = stale_harness.run(env_bin=stale)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(f"expected={PIN}", result.stdout)
        self.assertIn(f"observed={STALE_PIN}", result.stdout)

    def test_unavailable_explicit_provenance_fails_closed(self) -> None:
        harness = self.harness()
        candidate = harness.engine(harness.root / "explicit-unavailable", available=False)
        result = harness.run(explicit=candidate)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("observed=unavailable", result.stdout)
        self.assertIn("remediation=", result.stdout)

    def test_stale_path_bin_falls_back_to_matching_cache(self) -> None:
        harness = self.harness()
        stale = harness.engine(harness.root / "path-stale", STALE_PIN)
        cache = harness.engine(harness.root / "cache-valid")
        self.assert_success(harness.run(path_bin=stale, cache_bin=cache), harness.cache_bin)

    def test_stale_dirty_sibling_is_not_modified_and_cache_is_used(self) -> None:
        harness = self.harness()
        sibling_source = harness.root.parent / "fkst-substrate"
        sibling_source.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=sibling_source, check=True)
        marker = sibling_source / "local-change.txt"
        marker.write_text("keep me\n", encoding="utf-8")
        stale = harness.engine(harness.root / "sibling-stale", STALE_PIN)
        cache = harness.engine(harness.root / "cache-valid")
        self.assert_success(harness.run(sibling_bin=stale, cache_bin=cache), harness.cache_bin)
        self.assertEqual(marker.read_text(encoding="utf-8"), "keep me\n")

    def test_matching_cache_hit_does_not_build(self) -> None:
        harness = self.harness()
        cache = harness.engine(harness.root / "cache-valid")
        self.assert_success(harness.run(cache_bin=cache), harness.cache_bin)
        self.assertFalse(harness.build_log.exists())

    def test_cache_miss_builds_and_verifies_pinned_binary(self) -> None:
        harness = self.harness()
        built = harness.engine(harness.root / "built-valid")
        self.assert_success(harness.run(built_bin=built), harness.built_bin)
        self.assertEqual(harness.build_log.read_text(encoding="utf-8"), "build\n")

    def test_readonly_cache_miss_fails_without_build(self) -> None:
        harness = self.harness()
        built = harness.engine(harness.root / "built-valid")
        result = harness.run(built_bin=built, readonly=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("pinned engine unavailable", result.stdout)
        self.assertFalse(harness.build_log.exists())


if __name__ == "__main__":
    unittest.main()
