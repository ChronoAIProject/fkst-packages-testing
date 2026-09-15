#!/usr/bin/env python3
"""Backend-selection tests for atomic object-bound cleanup capture."""

import importlib.util
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock


BROKER_PATH = pathlib.Path(__file__).resolve().parents[1] / "bin" / "object-bound-cleanup-broker.py"
SPEC = importlib.util.spec_from_file_location("object_bound_cleanup_broker", BROKER_PATH)
BROKER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BROKER)


class Primitive:
    def __init__(self):
        self.calls = []
        self.argtypes = None
        self.restype = None

    def __call__(self, *args):
        self.calls.append(args)
        return 0


class Library:
    pass


class BackendSelectionTest(unittest.TestCase):
    def call(self, platform, library):
        with mock.patch.object(BROKER.sys, "platform", platform), mock.patch.object(
            BROKER.ctypes, "CDLL", return_value=library
        ):
            BROKER.rename_noreplace("source", 11, "destination", 22)

    def test_linux_uses_renameat2_with_noreplace(self):
        library = Library()
        library.renameat2 = Primitive()
        library.renameatx_np = Primitive()
        self.call("linux", library)
        self.assertEqual(len(library.renameat2.calls), 1)
        self.assertEqual(library.renameat2.calls[0][0], 11)
        self.assertEqual(library.renameat2.calls[0][2], 22)
        self.assertEqual(library.renameat2.calls[0][4], BROKER.RENAME_NOREPLACE)
        self.assertEqual(library.renameatx_np.calls, [])

    def test_darwin_uses_renameatx_np_with_exclusive_flag(self):
        library = Library()
        library.renameat2 = Primitive()
        library.renameatx_np = Primitive()
        self.call("darwin", library)
        self.assertEqual(len(library.renameatx_np.calls), 1)
        self.assertEqual(library.renameatx_np.calls[0][0], 11)
        self.assertEqual(library.renameatx_np.calls[0][2], 22)
        self.assertEqual(library.renameatx_np.calls[0][4], BROKER.RENAME_EXCL)
        self.assertEqual(library.renameat2.calls, [])

    def test_missing_platform_primitive_fails_closed(self):
        with self.assertRaisesRegex(BROKER.CleanupBlocked, "atomic-capture-unsupported"):
            self.call("linux", Library())
        with self.assertRaisesRegex(BROKER.CleanupBlocked, "atomic-capture-unsupported"):
            self.call("darwin", Library())

    def test_unsupported_platform_has_no_ordinary_rename_fallback(self):
        library = Library()
        library.rename = Primitive()
        with mock.patch.object(BROKER.os, "rename", side_effect=AssertionError("unsafe fallback")):
            with self.assertRaisesRegex(BROKER.CleanupBlocked, "atomic-capture-unsupported"):
                self.call("win32", library)
        self.assertEqual(library.rename.calls, [])


class ProofRetirementRecoveryTest(unittest.TestCase):
    def test_release_proof_replays_after_first_marker_unlink(self):
        with tempfile.TemporaryDirectory() as temporary:
            containment_root = pathlib.Path(temporary) / "containment"
            target = containment_root / "target"
            target.mkdir(parents=True)
            (target / "owned.txt").write_text("owned\n", encoding="utf-8")

            def identity(candidate):
                linked = os.stat(candidate, follow_symlinks=False)
                return {
                    "realpath": os.path.realpath(candidate),
                    "device": str(linked.st_dev),
                    "inode": str(linked.st_ino),
                }

            request = {
                "schema": BROKER.REQUEST_SCHEMA,
                "operation": "capture-delete",
                "capture_id": "a" * 64,
                "target": os.path.realpath(target),
                "target_identity": identity(target),
                "containment_root": os.path.realpath(containment_root),
                "containment_root_identity": identity(containment_root),
            }
            self.assertEqual(BROKER.cleanup(request)["status"], "captured-cleaned")
            self.assertEqual(
                BROKER.cleanup({**request, "operation": "finalize"})["status"],
                "finalized",
            )

            real_unlink = BROKER.os.unlink
            interrupted = False

            def interrupt_after_first_unlink(name, *args, **kwargs):
                nonlocal interrupted
                real_unlink(name, *args, **kwargs)
                if not interrupted:
                    interrupted = True
                    raise RuntimeError("simulated proof retirement interruption")

            with mock.patch.object(BROKER.os, "unlink", side_effect=interrupt_after_first_unlink):
                with self.assertRaisesRegex(RuntimeError, "simulated proof retirement interruption"):
                    BROKER.cleanup({**request, "operation": "release-proof"})

            proof = pathlib.Path(temporary) / f"{BROKER.QUARANTINE_PREFIX}{request['capture_id']}"
            finalized = proof / BROKER.CAPTURE_FINALIZED_MARKER
            finalized.write_bytes(b"finalized:tampered\n")
            with self.assertRaisesRegex(BROKER.CleanupBlocked, "capture-proof-marker-invalid"):
                BROKER.cleanup({**request, "operation": "release-proof"})
            finalized.write_bytes(BROKER.capture_marker_body(request))
            released = BROKER.cleanup({**request, "operation": "release-proof"})
            self.assertEqual(released["status"], "released")
            self.assertFalse(proof.exists())


if __name__ == "__main__":
    unittest.main()
