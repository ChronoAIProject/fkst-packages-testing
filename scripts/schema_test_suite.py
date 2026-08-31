#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import sys
from collections.abc import Sequence
from pathlib import Path


def main(argv: Sequence[str] | None = None) -> int:
    failures = []
    for filename in sys.argv[1:] if argv is None else argv:
        path = Path(filename)
        spec = importlib.util.spec_from_file_location("fkst_schema_suite_" + path.stem, path)
        if spec is None or spec.loader is None:
            raise SystemExit(f"unable to load schema adapter: {path}")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        try:
            result = module.main()
            if result not in (None, 0):
                raise AssertionError(f"adapter returned nonzero status: {result!r}")
        except Exception as error:
            failures.append((path.name, error))
    if failures:
        for name, error in failures:
            print(f"{name}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
