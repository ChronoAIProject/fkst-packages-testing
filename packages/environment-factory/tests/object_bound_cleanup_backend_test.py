#!/usr/bin/env python3
"""Backend-selection tests for atomic object-bound cleanup capture."""

import importlib.util
import pathlib
import sys
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


if __name__ == "__main__":
    unittest.main()
