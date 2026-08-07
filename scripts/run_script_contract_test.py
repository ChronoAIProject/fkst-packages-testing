#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path


SOURCE_ROOT = Path(__file__).resolve().parents[1]
SOURCE_RUN_SH = SOURCE_ROOT / "scripts" / "run.sh"
SOURCE_ENGINE_PROVENANCE = SOURCE_ROOT / "scripts" / "engine_provenance.sh"
SOURCE_CI_CONTRACT = SOURCE_ROOT / "scripts" / "check_ci_contract.py"
SOURCE_CI_WORKFLOW = SOURCE_ROOT / ".github" / "workflows" / "ci.yml"
SUBSTRATE_PIN = "1" * 40
GENERIC_HOST_CLOSED_WORLD_ROOTS = (
    "local-qa-host-adapter",
    "environment-factory",
    "testing-design",
    "browser-readiness",
    "module-testing-pipeline",
    "module-test-loop",
    "testing-runner",
    "test-artifacts",
    "test-publication",
    "workflow-qa",
    "consensus",
    "github-proxy",
)
GENERIC_HOST_CLOSED_WORLD_ENV = (
    "local-qa-host-adapter environment-factory testing-design browser-readiness "
    "module-testing-pipeline module-test-loop testing-runner test-artifacts test-publication "
    "workflow-qa @platform/consensus @platform/github-proxy"
)


def dedent(value: str) -> str:
    return textwrap.dedent(value).lstrip()


class RunnerWorkspace:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="fkst-runner-contract-")
        self.root = Path(self.temporary.name) / "workspace"
        self.root.mkdir()
        self.log_path = self.root / "framework.jsonl"
        self.coverage_log_path = self.root / "coverage.jsonl"
        self.tmpdir = self.root / "tmp"
        self.tmpdir.mkdir()
        self.tools = self.root / "fixture-bin"
        self.tools.mkdir()
        self._write_fixture()

    def close(self) -> None:
        self.temporary.cleanup()

    def write(self, relative: str, body: str, executable: bool = False) -> Path:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(body, encoding="utf-8")
        if executable:
            path.chmod(0o755)
        return path

    def _package(self, name: str, composed: bool = False, with_tests: bool = True) -> None:
        kind = "package.composed" if composed else "package"
        event_deps = '\n[event_deps]\npackages = ["dependency"]\n' if composed else ""
        self.write(
            f"packages/{name}/fkst.toml",
            dedent(
                f"""
                kind = "{kind}"
                name = "{name}"
                persistence_class = "stateless_adapter"

                [code]
                root = "."
                {event_deps}
                [conformance]
                pack = "conformance/pack.toml"
                """
            ),
        )
        self.write(f"packages/{name}/core.lua", "return {}\n")
        self.write(
            f"packages/{name}/conformance/pack.toml",
            dedent(
                f"""
                schema = 1
                runner_protocol = "fkst-declarative-rulepack@1"
                owner_package = "{name}"

                [[rules]]
                id = "fixture-never-match"
                severity = "error"
                kind = "text_forbid_regex"
                include = ["**/*.lua"]
                exclude = ["tests/**"]
                pattern = "FIXTURE_NEVER_MATCHES"
                message = "fixture rule"
                """
            ),
        )
        if with_tests:
            test_name = name.replace("-", "_")
            self.write(f"packages/{name}/tests/{test_name}_test.lua", "return {}\n")

    def _write_fixture(self) -> None:
        (self.root / "scripts").mkdir()
        (self.root / ".fkst" / "workflow").mkdir(parents=True)
        shutil.copy2(SOURCE_RUN_SH, self.root / "scripts" / "run.sh")
        (self.root / "scripts" / "run.sh").chmod(0o755)
        shutil.copy2(SOURCE_ENGINE_PROVENANCE, self.root / "scripts" / "engine_provenance.sh")
        (self.root / "scripts" / "engine_provenance.sh").chmod(0o755)
        shutil.copy2(SOURCE_CI_CONTRACT, self.root / "scripts" / "check_ci_contract.py")
        self.write(
            ".github/workflows/ci.yml",
            SOURCE_CI_WORKFLOW.read_text(encoding="utf-8"),
        )
        self.write("scripts/check_single_platform_pin.py", "raise SystemExit(0)\n")
        self.write(".fkst/substrate-ref", SUBSTRATE_PIN + "\n")
        self.write(
            "fkst.workspace.toml",
            dedent(
                """
                [workspace]
                units = ["packages/*"]
                packages = ["packages/*"]
                libraries = []
                """
            ),
        )
        self._package("dependency")
        self._package("flat-one")
        self._package("parent", composed=True)
        self.write(
            ".fkst/conformance/composed-roots",
            "parent dependency @platform/platform-dep\n",
        )
        self.write(
            ".fkst/local-libraries/forge/fkst.toml",
            'kind = "library"\n[library]\nname = "forge"\n',
        )
        self.write(".fkst/local-libraries/forge/tracked-mirror.txt", "tracked local forge\n")

        checkout = self.root / ".fkst" / "run" / "fkst-packages-conformance"
        checkout.mkdir(parents=True)
        self.write(
            ".fkst/run/fkst-packages-conformance/scripts/check_repo.py",
            dedent(
                """
                import os

                if os.environ.get("FAKE_SOURCE_RATCHET_FAIL") == "1":
                    print("fixture source ratchet failed")
                    raise SystemExit(17)
                """
            ),
        )
        self.write(
            ".fkst/run/fkst-packages-conformance/scripts/bin_bootstrap.sh",
            "resolve_bin_contract() { return 1; }\n",
        )
        self.write(
            ".fkst/run/fkst-packages-conformance/scripts/run.sh",
            dedent(
                """
                #!/usr/bin/env bash
                set -euo pipefail

                case "${1:-}" in
                  host)
                    shift
                    host_root=""
                    while [ "$#" -gt 0 ]; do
                      case "$1" in
                        --host-root) host_root="$2"; shift 2 ;;
                        --) shift; break ;;
                        *) shift ;;
                      esac
                    done
                    [ "${1:-}" = "check" ] || exit 2
                    "$BIN" conformance --project-root "$host_root"
                    ;;
                  test)
                    exit 0
                    ;;
                  *)
                    exit 2
                    ;;
                esac
                """
            ),
            executable=True,
        )
        self.write(
            ".fkst/run/fkst-packages-conformance/scripts/check_repo_coverage.py",
            dedent(
                """
                import json
                import os
                from pathlib import Path

                def record(kind):
                    path = os.environ.get("FAKE_COVERAGE_LOG")
                    if path:
                        with Path(path).open("a", encoding="utf-8") as handle:
                            handle.write(json.dumps({"kind": kind}) + "\\n")

                def parse_covered_json_arg(value):
                    return value

                def merge_covered_sets(values):
                    record("merge")
                    if os.environ.get("FAKE_COVERAGE_MERGE_FAIL") == "1":
                        raise RuntimeError("fixture coverage merge failed")
                    return set(values)

                def write_canonical_coverage_json(values, output, root):
                    output.parent.mkdir(parents=True, exist_ok=True)
                    output.write_text('{"files":[]}\\n', encoding="utf-8")
                    return len(values)

                if __name__ == "__main__":
                    record("ratchet")
                    raise SystemExit(1 if os.environ.get("FAKE_COVERAGE_RATCHET_FAIL") == "1" else 0)
                """
            ),
        )
        self.write(
            ".fkst/run/fkst-packages-conformance/packages/platform-dep/fkst.toml",
            'kind = "package"\nname = "platform-dep"\n[code]\nroot = "."\n',
        )
        self.write(
            ".fkst/run/fkst-packages-conformance/packages/platform-dep/tests/platform_dep_test.lua",
            "return {}\n",
        )
        for name in ("forge", "devloop"):
            self.write(
                f".fkst/run/fkst-packages-conformance/libraries/{name}/fkst.toml",
                f'kind = "library"\n[library]\nname = "{name}"\n',
            )

        subprocess.run(["git", "init", "-q"], cwd=checkout, check=True)
        subprocess.run(["git", "config", "user.email", "fixture@example.invalid"], cwd=checkout, check=True)
        subprocess.run(["git", "config", "user.name", "Fixture"], cwd=checkout, check=True)
        subprocess.run(["git", "add", "."], cwd=checkout, check=True)
        subprocess.run(["git", "commit", "-q", "-m", "fixture platform"], cwd=checkout, check=True)
        pin = subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=checkout, check=True, text=True, stdout=subprocess.PIPE
        ).stdout.strip()
        self.write(".fkst/conformance/fkst-packages.pin", f"{pin}\n")

        self.write(
            "fixture-framework",
            dedent(
                f"""
                #!{sys.executable}
                import json
                import os
                import sys
                from pathlib import Path

                argv = sys.argv[1:]
                subcommand = argv[0] if argv else ""
                if subcommand == "init-package-repo":
                    Path(".fkst-substrate-ref").write_text({SUBSTRATE_PIN!r} + "\\n", encoding="utf-8")
                    print("init-package-repo substrate_ref=" + {SUBSTRATE_PIN!r})
                    raise SystemExit(0)
                project_root = None
                package_roots = []
                for index, value in enumerate(argv):
                    if value == "--project-root" and index + 1 < len(argv):
                        project_root = argv[index + 1]
                    if value == "--package-root" and index + 1 < len(argv):
                        package_roots.append(argv[index + 1])
                test_files = []
                if project_root and Path(project_root).is_dir():
                    test_files = sorted(
                        str(path.relative_to(project_root))
                        for path in Path(project_root).rglob("*_test.lua")
                    )
                forge_marker = None
                if project_root:
                    marker_path = Path(project_root) / "libraries" / "forge" / "tracked-mirror.txt"
                    if marker_path.is_file():
                        forge_marker = marker_path.read_text(encoding="utf-8")
                record = {{
                    "argv": argv,
                    "subcommand": subcommand,
                    "project_root": project_root,
                    "package_roots": package_roots,
                    "test_files": test_files,
                    "forge_marker": forge_marker,
                    "generic_host_closed_world_roots": os.environ.get(
                        "FKST_GENERIC_HOST_CLOSED_WORLD_ROOTS"
                    ),
                    "runtime_root": os.environ.get("FKST_RUNTIME_ROOT"),
                    "durable_root": os.environ.get("FKST_DURABLE_ROOT"),
                    "module_test_loop_test_runtime": os.environ.get(
                        "FKST_MODULE_TEST_LOOP_TEST_RUNTIME"
                    ),
                    "runtime_root_exists": bool(os.environ.get("FKST_RUNTIME_ROOT"))
                    and Path(os.environ["FKST_RUNTIME_ROOT"]).is_dir(),
                    "durable_root_exists": bool(os.environ.get("FKST_DURABLE_ROOT"))
                    and Path(os.environ["FKST_DURABLE_ROOT"]).is_dir(),
                    "github_write": os.environ.get("FKST_GITHUB_WRITE"),
                    "supervisor_pid": os.environ.get("FKST_SUPERVISOR_PID"),
                }}
                log_path = os.environ.get("FAKE_FRAMEWORK_LOG")
                if log_path:
                    with Path(log_path).open("a", encoding="utf-8") as handle:
                        handle.write(json.dumps(record) + "\\n")
                if os.environ.get("FAKE_FAIL_SUBCOMMAND") == subcommand:
                    raise SystemExit(23)
                if subcommand == "test" and "--coverage" in argv and os.environ.get("FAKE_SKIP_COVERAGE") != "1":
                    coverage_dir = Path(argv[argv.index("--coverage") + 1])
                    coverage_dir.mkdir(parents=True, exist_ok=True)
                    (coverage_dir / "coverage.json").write_text('{{"files":[]}}\\n', encoding="utf-8")
                raise SystemExit(0)
                """
            ),
            executable=True,
        )
        self.write("fixture-bin/node", "#!/usr/bin/env sh\nexit 0\n", executable=True)

    def add_package_without_tests(self, name: str = "missing-tests") -> None:
        self._package(name, with_tests=False)

    def add_generic_host_composition(self) -> None:
        for name in GENERIC_HOST_CLOSED_WORLD_ROOTS[:-2]:
            self._package(name)
        for name in GENERIC_HOST_CLOSED_WORLD_ROOTS[-2:]:
            self.write(
                f".fkst/run/fkst-packages-conformance/packages/{name}/fkst.toml",
                f'kind = "package"\nname = "{name}"\n[code]\nroot = "."\n',
            )
            self.write(
                f".fkst/run/fkst-packages-conformance/packages/{name}/tests/{name.replace('-', '_')}_test.lua",
                "return {}\n",
            )
        self.write(
            "examples/generic-host/fkst.toml",
            dedent(
                """
                kind = "package.composed"
                name = "generic-host"
                persistence_class = "saga"

                [code]
                root = "."
                """
            ),
        )
        self.write("examples/generic-host/tests/generic_host_test.lua", "return {}\n")

    def create_external_host(self, name: str = "fixture-external-host", with_manifest: bool = True) -> Path:
        host_root = Path(self.temporary.name) / name
        host_root.mkdir()
        if with_manifest:
            (host_root / "fkst.toml").write_text(
                dedent(
                    f"""
                    kind = "package.composed"
                    name = "{name}"
                    persistence_class = "saga"

                    [code]
                    root = "."
                    """
                ),
                encoding="utf-8",
            )
        tests = host_root / "tests"
        tests.mkdir()
        (tests / "external_host_test.lua").write_text("return {}\n", encoding="utf-8")
        return host_root

    def run(self, *arguments: str, extra_env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment.update(
            {
                "BIN": str(self.root / "fixture-framework"),
                "PYTHON": sys.executable,
                "FAKE_FRAMEWORK_LOG": str(self.log_path),
                "FAKE_COVERAGE_LOG": str(self.coverage_log_path),
                "FKST_SKIP_REPOSITORY_CONTRACT_TESTS": "1",
                "FKST_GITHUB_WRITE": "enabled-in-parent",
                "FKST_SUPERVISOR_PID": "4242",
                "TMPDIR": str(self.tmpdir),
                "PATH": str(self.tools) + os.pathsep + environment.get("PATH", ""),
            }
        )
        if extra_env:
            environment.update(extra_env)
        return subprocess.run(
            [str(self.root / "scripts" / "run.sh"), *arguments],
            cwd=self.root,
            env=environment,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )

    def records(self, subcommand: str | None = None) -> list[dict]:
        if not self.log_path.exists():
            return []
        records = [json.loads(line) for line in self.log_path.read_text(encoding="utf-8").splitlines()]
        if subcommand is None:
            return records
        return [record for record in records if record["subcommand"] == subcommand]

    def coverage_records(self) -> list[str]:
        if not self.coverage_log_path.exists():
            return []
        return [
            json.loads(line)["kind"]
            for line in self.coverage_log_path.read_text(encoding="utf-8").splitlines()
        ]


class RunnerContractTest(unittest.TestCase):
    def workspace(self) -> RunnerWorkspace:
        fixture = RunnerWorkspace()
        self.addCleanup(fixture.close)
        return fixture

    def assert_success(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertEqual(result.returncode, 0, result.stdout)

    def assert_failure(self, result: subprocess.CompletedProcess[str]) -> None:
        self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_targeted_selection_uses_only_the_selected_flat_test_workspace(self) -> None:
        fixture = self.workspace()
        result = fixture.run("test", "flat-one")
        self.assert_success(result)
        tests = fixture.records("test")
        self.assertEqual(len(tests), 1)
        self.assertEqual(tests[0]["project_root"], tests[0]["package_roots"][0])
        self.assertTrue(all("flat_one_test.lua" in path for path in tests[0]["test_files"]))
        self.assertEqual(tests[0]["forge_marker"], "tracked local forge\n")
        self.assertNotIn("full repository", result.stdout.lower())
        self.assertIn(f"PASS engine-provenance expected_pin={SUBSTRATE_PIN}", result.stdout)
        self.assertEqual(fixture.coverage_records(), [])

        unknown = fixture.run("test", "unknown-package")
        self.assert_failure(unknown)
        self.assertIn("no packages matched for 'unknown-package'", unknown.stdout)

    def test_check_test_and_supervise_emit_exact_engine_invariant(self) -> None:
        fixture = self.workspace()
        for arguments in (("check",), ("test", "flat-one"), ("supervise", "flat-one")):
            result = fixture.run(*arguments)
            self.assert_success(result)
            self.assertIn(f"PASS engine-provenance expected_pin={SUBSTRATE_PIN}", result.stdout)
            self.assertIn(f"ENGINE_VER={SUBSTRATE_PIN[:12]}", result.stdout)

    def test_composed_target_uses_declared_roots_and_excludes_dependency_tests(self) -> None:
        fixture = self.workspace()
        result = fixture.run("test", "parent")
        self.assert_success(result)
        tests = fixture.records("test")
        self.assertEqual(len(tests), 1)
        roots = [Path(path).name for path in tests[0]["package_roots"]]
        self.assertEqual(roots, ["parent", "dependency", "platform-dep"])
        self.assertTrue(any("parent_test.lua" in path for path in tests[0]["test_files"]))
        self.assertFalse(any("dependency_test.lua" in path for path in tests[0]["test_files"]))
        self.assertFalse(any("platform_dep_test.lua" in path for path in tests[0]["test_files"]))
        self.assertEqual(tests[0]["forge_marker"], "tracked local forge\n")
        self.assertFalse(Path(tests[0]["project_root"]).exists())

    def test_selected_package_without_tests_fails_closed(self) -> None:
        fixture = self.workspace()
        fixture.add_package_without_tests()
        result = fixture.run("test", "missing-tests")
        self.assert_failure(result)
        self.assertIn("has no tests/*_test.lua files", result.stdout)
        self.assertEqual(fixture.records("test"), [])

    def test_test_children_use_hermetic_environment_and_cleanup_after_success(self) -> None:
        fixture = self.workspace()
        result = fixture.run("test", "flat-one")
        self.assert_success(result)
        for record in fixture.records("conformance") + fixture.records("test"):
            self.assertIsNotNone(record["runtime_root"])
            self.assertIsNotNone(record["durable_root"])
            self.assertIsNone(record["github_write"])
            self.assertIsNone(record["supervisor_pid"])
        test_record = fixture.records("test")[0]
        self.assertFalse(Path(test_record["runtime_root"]).exists())
        self.assertFalse(Path(test_record["durable_root"]).exists())
        self.assertFalse(Path(test_record["project_root"]).exists())

    def test_package_failure_propagates_and_cleans_workspaces(self) -> None:
        fixture = self.workspace()
        result = fixture.run("test", "flat-one", extra_env={"FAKE_FAIL_SUBCOMMAND": "test"})
        self.assert_failure(result)
        record = fixture.records("test")[0]
        self.assertFalse(Path(record["project_root"]).exists())
        self.assertFalse(Path(record["runtime_root"]).exists())
        self.assertFalse(Path(record["durable_root"]).exists())

    def test_conformance_failure_propagates_and_cleans_hermetic_roots(self) -> None:
        fixture = self.workspace()
        result = fixture.run("test", "flat-one", extra_env={"FAKE_FAIL_SUBCOMMAND": "conformance"})
        self.assert_failure(result)
        record = fixture.records("conformance")[0]
        self.assertIsNone(record["github_write"])
        self.assertIsNone(record["supervisor_pid"])
        self.assertFalse(Path(record["runtime_root"]).exists())
        self.assertFalse(Path(record["durable_root"]).exists())

    def test_source_ratchet_failure_skips_package_tests_and_cleans_hermetic_roots(self) -> None:
        fixture = self.workspace()
        result = fixture.run("test", "flat-one", extra_env={"FAKE_SOURCE_RATCHET_FAIL": "1"})

        self.assert_failure(result)
        self.assertIn("fixture source ratchet failed", result.stdout)
        self.assertIn("FAILED: check", result.stdout)
        self.assertEqual(fixture.records("test"), [])
        self.assertEqual(fixture.coverage_records(), [])
        conformance = fixture.records("conformance")
        self.assertGreater(len(conformance), 0)
        for record in conformance:
            self.assertFalse(Path(record["runtime_root"]).exists())
            self.assertFalse(Path(record["durable_root"]).exists())

    def test_host_checks_use_hermetic_environment_and_cleanup_after_success(self) -> None:
        for arguments in (("host", "--", "check"), ("host", "--", "test")):
            with self.subTest(arguments=arguments):
                fixture = self.workspace()
                ambient_runtime = fixture.root / "ambient-runtime"
                ambient_durable = fixture.root / "ambient-durable"
                result = fixture.run(
                    *arguments,
                    extra_env={
                        "FKST_RUNTIME_ROOT": str(ambient_runtime),
                        "FKST_DURABLE_ROOT": str(ambient_durable),
                    },
                )
                self.assert_success(result)
                checks = fixture.records("conformance")
                self.assertEqual(len(checks), 1)
                record = checks[0]
                self.assertNotEqual(record["runtime_root"], str(ambient_runtime))
                self.assertNotEqual(record["durable_root"], str(ambient_durable))
                self.assertIsNone(record["github_write"])
                self.assertIsNone(record["supervisor_pid"])
                self.assertFalse(Path(record["runtime_root"]).exists())
                self.assertFalse(Path(record["durable_root"]).exists())

    def test_host_check_failure_propagates_and_cleans_hermetic_roots(self) -> None:
        fixture = self.workspace()
        result = fixture.run("host", "--", "check", extra_env={"FAKE_FAIL_SUBCOMMAND": "conformance"})
        self.assert_failure(result)
        self.assertEqual(result.returncode, 23, result.stdout)
        record = fixture.records("conformance")[0]
        self.assertFalse(Path(record["runtime_root"]).exists())
        self.assertFalse(Path(record["durable_root"]).exists())

    def test_host_check_rejects_trailing_arguments(self) -> None:
        fixture = self.workspace()
        result = fixture.run("host", "--", "check", "unexpected")
        self.assertEqual(result.returncode, 2, result.stdout)
        self.assertIn("does not accept trailing arguments", result.stdout)
        self.assertEqual(fixture.records("conformance"), [])

    def test_host_check_fails_closed_when_hermetic_root_cannot_be_created(self) -> None:
        fixture = self.workspace()
        fixture.write(
            "fixture-bin/mktemp",
            dedent(
                """
                #!/usr/bin/env bash
                case "$*" in
                  *fkst-host-check*) exit 9 ;;
                esac
                exec /usr/bin/mktemp "$@"
                """
            ),
            executable=True,
        )
        result = fixture.run("host", "--", "check")
        self.assert_failure(result)
        self.assertIn("failed to create hermetic host check root", result.stdout)
        self.assertEqual(fixture.records("conformance"), [])

    def test_generic_host_pins_engine_arguments_environment_and_workspace_lifetime(self) -> None:
        fixture = self.workspace()
        fixture.add_generic_host_composition()
        ambient_runtime = fixture.root / "ambient-runtime"
        ambient_durable = fixture.root / "ambient-durable"

        result = fixture.run(
            "example",
            "generic-host",
            extra_env={
                "FKST_GENERIC_HOST_CLOSED_WORLD_ROOTS": "ambient-wrong-roots",
                "FKST_RUNTIME_ROOT": str(ambient_runtime),
                "FKST_DURABLE_ROOT": str(ambient_durable),
                "FKST_MODULE_TEST_LOOP_TEST_RUNTIME": "ambient-wrong-flag",
            },
        )
        self.assert_success(result)

        records = fixture.records("test")
        self.assertEqual(len(records), 1)
        record = records[0]
        self.assertEqual(record["subcommand"], "test")
        work = Path(record["project_root"])
        package_roots = [
            work / "packages" / "generic-host",
            *(work / "packages" / name for name in GENERIC_HOST_CLOSED_WORLD_ROOTS),
        ]
        expected_argv = ["test", "--project-root", str(work)]
        for package_root in package_roots:
            expected_argv.extend(("--package-root", str(package_root)))

        self.assertTrue(work.is_absolute())
        self.assertEqual(record["argv"], expected_argv)
        self.assertEqual(record["package_roots"], [str(path) for path in package_roots])
        self.assertEqual(Path(record["package_roots"][1]).name, "local-qa-host-adapter")
        self.assertEqual(
            record["generic_host_closed_world_roots"], GENERIC_HOST_CLOSED_WORLD_ENV
        )
        self.assertNotEqual(
            record["generic_host_closed_world_roots"], "ambient-wrong-roots"
        )
        runtime_root = work / ".fkst" / "run" / "runtime"
        durable_root = work / ".fkst" / "run" / "durable"
        self.assertEqual(record["runtime_root"], str(runtime_root))
        self.assertEqual(record["durable_root"], str(durable_root))
        self.assertNotEqual(record["runtime_root"], str(ambient_runtime))
        self.assertNotEqual(record["durable_root"], str(ambient_durable))
        self.assertEqual(record["module_test_loop_test_runtime"], "1")
        self.assertNotEqual(
            record["module_test_loop_test_runtime"], "ambient-wrong-flag"
        )
        self.assertTrue(record["runtime_root_exists"])
        self.assertTrue(record["durable_root_exists"])
        self.assertFalse(work.exists())
        self.assertFalse(runtime_root.exists())
        self.assertFalse(durable_root.exists())
        self.assertFalse(ambient_runtime.exists())
        self.assertFalse(ambient_durable.exists())

    def test_external_host_reuses_generic_composition_and_cleans_copied_workspace(self) -> None:
        fixture = self.workspace()
        fixture.add_generic_host_composition()
        host_root = fixture.create_external_host()
        logical_tmpdir = fixture.root / "logical-tmp"
        logical_tmpdir.symlink_to(fixture.tmpdir, target_is_directory=True)

        example_result = fixture.run("example", "generic-host")
        self.assert_success(example_result)
        external_result = fixture.run(
            "external-host",
            str(host_root),
            extra_env={"TMPDIR": str(logical_tmpdir)},
        )
        self.assert_success(external_result)
        self.assertIn(f"PASS engine-provenance expected_pin={SUBSTRATE_PIN}", external_result.stdout)

        tests = fixture.records("test")
        self.assertEqual(len(tests), 2)
        example, external = tests
        self.assertEqual(Path(example["package_roots"][0]).name, "generic-host")
        self.assertEqual(Path(external["package_roots"][0]).name, "external-host")
        example_roots = [Path(path).name for path in example["package_roots"][1:]]
        external_roots = [Path(path).name for path in external["package_roots"][1:]]
        self.assertEqual(example_roots, external_roots)
        self.assertEqual(external_roots, list(GENERIC_HOST_CLOSED_WORLD_ROOTS))
        self.assertEqual(external["test_files"], ["packages/external-host/tests/external_host_test.lua"])
        self.assertNotEqual(Path(external["package_roots"][0]), host_root)
        self.assertEqual(example["project_root"], str(Path(example["project_root"]).resolve()))
        self.assertEqual(external["project_root"], str(Path(external["project_root"]).resolve()))
        self.assertTrue(
            all(path == str(Path(path).resolve()) for path in example["package_roots"])
        )
        self.assertTrue(
            all(path == str(Path(path).resolve()) for path in external["package_roots"])
        )
        self.assertFalse(Path(example["project_root"]).exists())
        self.assertFalse(Path(external["project_root"]).exists())
        self.assertFalse((fixture.root / "module-test-loop-test-state-store.json").exists())
        self.assertTrue(host_root.exists())

    def test_external_host_rejects_invalid_or_repository_owned_roots(self) -> None:
        fixture = self.workspace()
        host_root = fixture.create_external_host()
        missing_manifest = fixture.create_external_host("missing-manifest", with_manifest=False)
        embedded_package = fixture.write(
            "packages/embedded-host/fkst.toml",
            'kind = "package.composed"\nname = "embedded-host"\n',
        ).parent
        embedded_library = fixture.write(
            "libraries/embedded-host/fkst.toml",
            'kind = "library"\nname = "embedded-host"\n',
        ).parent
        linked_package = Path(fixture.temporary.name) / "linked-package-host"
        linked_package.symlink_to(embedded_package, target_is_directory=True)

        cases = (
            ((), "usage: scripts/run.sh external-host <absolute-host-root>"),
            ((str(host_root), "unexpected"), "usage: scripts/run.sh external-host <absolute-host-root>"),
            (("relative-host",), "must be an absolute path"),
            (((Path(fixture.temporary.name) / "absent-host").as_posix(),), "does not exist"),
            ((str(missing_manifest),), "must contain fkst.toml"),
            ((str(embedded_package),), "may not be within this repository's packages/ or libraries/"),
            ((str(embedded_library),), "may not be within this repository's packages/ or libraries/"),
            ((str(linked_package),), "may not be within this repository's packages/ or libraries/"),
        )
        for arguments, message in cases:
            with self.subTest(arguments=arguments):
                result = fixture.run("external-host", *arguments)
                self.assert_failure(result)
                self.assertIn(message, result.stdout)
        self.assertEqual(fixture.records("test"), [])

    def test_external_host_test_failure_propagates_and_cleans_copied_workspace(self) -> None:
        fixture = self.workspace()
        fixture.add_generic_host_composition()
        host_root = fixture.create_external_host()
        result = fixture.run(
            "external-host",
            str(host_root),
            extra_env={"FAKE_FAIL_SUBCOMMAND": "test"},
        )
        self.assertEqual(result.returncode, 23, result.stdout)
        record = fixture.records("test")[0]
        self.assertFalse(Path(record["project_root"]).exists())
        self.assertTrue(host_root.exists())

    def test_external_host_construction_failure_cleans_partial_composed_workspace(self) -> None:
        fixture = self.workspace()
        fixture.add_generic_host_composition()
        host_root = fixture.create_external_host()
        fixture.write(
            "fixture-bin/tar",
            dedent(
                """
                #!/usr/bin/env bash
                if [ "${FAKE_TAR_FAIL_BASENAME:-}" = "$(basename "$PWD")" ]; then
                  exit 19
                fi
                exec /usr/bin/tar "$@"
                """
            ),
            executable=True,
        )
        before = set(fixture.tmpdir.glob("fkst-testing-composed.*"))
        result = fixture.run(
            "external-host",
            str(host_root),
            extra_env={"FAKE_TAR_FAIL_BASENAME": host_root.name},
        )
        self.assert_failure(result)
        self.assertEqual(set(fixture.tmpdir.glob("fkst-testing-composed.*")), before)
        self.assertEqual(fixture.records("test"), [])
        self.assertTrue(host_root.exists())

    def test_missing_package_coverage_fails(self) -> None:
        fixture = self.workspace()
        result = fixture.run("test", "flat-one", extra_env={"FAKE_SKIP_COVERAGE": "1"})
        self.assert_failure(result)
        self.assertIn("did not write coverage.json", result.stdout)

    def test_full_run_merges_and_enforces_coverage_but_targeted_run_does_not(self) -> None:
        full = self.workspace()
        result = full.run("test")
        self.assert_success(result)
        self.assertEqual(full.coverage_records(), ["merge", "ratchet"])

        targeted = self.workspace()
        result = targeted.run("test", "flat-one")
        self.assert_success(result)
        self.assertEqual(targeted.coverage_records(), [])
        self.assertNotIn("Lua coverage ratchet", result.stdout)

    def test_coverage_merge_and_ratchet_failures_propagate(self) -> None:
        merge = self.workspace()
        result = merge.run("test", extra_env={"FAKE_COVERAGE_MERGE_FAIL": "1"})
        self.assert_failure(result)
        self.assertIn("fixture coverage merge failed", result.stdout)

        ratchet = self.workspace()
        result = ratchet.run("test", extra_env={"FAKE_COVERAGE_RATCHET_FAIL": "1"})
        self.assert_failure(result)
        self.assertEqual(ratchet.coverage_records(), ["merge", "ratchet"])

    def test_missing_and_invalid_composed_roots_fail_closed(self) -> None:
        missing = self.workspace()
        missing.write(".fkst/conformance/composed-roots", "# no parent entry\n")
        result = missing.run("test", "parent")
        self.assert_failure(result)
        self.assertIn("has no .fkst/conformance/composed-roots entry", result.stdout)

        invalid = self.workspace()
        invalid.write(".fkst/conformance/composed-roots", "parent missing-root\n")
        result = invalid.run("test", "parent")
        self.assert_failure(result)
        self.assertIn("missing-root", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
