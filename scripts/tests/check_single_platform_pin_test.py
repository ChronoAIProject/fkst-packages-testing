import runpy
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "check_single_platform_pin.py"
REV = "0123456789abcdef0123456789abcdef01234567"


def load_guard(root: Path):
    return runpy.run_path(str(SCRIPT), init_globals={"__FKST_TEST_ROOT": str(root), "__name__": "fkst_pin_test"})


class SinglePlatformPinTest(unittest.TestCase):
    def make_root(self) -> Path:
        temp = Path(tempfile.mkdtemp(prefix="fkst-pin-test."))
        (temp / ".fkst" / "conformance").mkdir(parents=True)
        (temp / ".fkst" / "run" / "fkst-packages-conformance").mkdir(parents=True)
        (temp / ".fkst" / "conformance" / "fkst-packages.pin").write_text(REV + "\n", encoding="utf-8")
        subprocess.run(["git", "init", "-q"], cwd=temp / ".fkst" / "run" / "fkst-packages-conformance", check=True)
        subprocess.run(["git", "checkout", "-q", "--orphan", "pin"], cwd=temp / ".fkst" / "run" / "fkst-packages-conformance", check=True)
        subprocess.run(
            ["git", "commit", "-q", "--allow-empty", "--date", "2001-01-01T00:00:00Z", "-m", "pin"],
            cwd=temp / ".fkst" / "run" / "fkst-packages-conformance",
            env={
                "GIT_AUTHOR_NAME": "FKST",
                "GIT_AUTHOR_EMAIL": "fkst@example.invalid",
                "GIT_COMMITTER_NAME": "FKST",
                "GIT_COMMITTER_EMAIL": "fkst@example.invalid",
            },
            check=True,
        )
        head = subprocess.run(
            ["git", "-C", str(temp / ".fkst" / "run" / "fkst-packages-conformance"), "rev-parse", "HEAD"],
            text=True,
            stdout=subprocess.PIPE,
            check=True,
        ).stdout.strip()
        (temp / ".fkst" / "conformance" / "fkst-packages.pin").write_text(head + "\n", encoding="utf-8")
        return temp

    def test_main_accepts_matching_pinned_checkout(self):
        root = self.make_root()
        guard = load_guard(root)

        self.assertEqual(guard["main"](), 0)

    def test_main_rejects_second_platform_ref_file(self):
        root = self.make_root()
        (root / "fkst-packages-ref").write_text(REV + "\n", encoding="utf-8")
        guard = load_guard(root)

        with self.assertRaises(SystemExit):
            guard["main"]()

    def test_main_rejects_dirty_pinned_checkout(self):
        root = self.make_root()
        (root / ".fkst" / "run" / "fkst-packages-conformance" / "local-change.txt").write_text("dirty\n", encoding="utf-8")
        guard = load_guard(root)

        with self.assertRaises(SystemExit):
            guard["main"]()


if __name__ == "__main__":
    unittest.main()
