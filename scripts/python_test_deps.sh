#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
DEPS="$ROOT/.fkst/run/python-test-deps"

resolve_python() {
  local candidate
  if [ -n "${PYTHON:-}" ]; then printf '%s\n' "$PYTHON"; return 0; fi
  for candidate in python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PY
    then command -v "$candidate"; return 0; fi
  done
  echo "error: Python 3.11+ is required for manifest schema tests" >&2
  return 1
}

[ "$#" -eq 1 ] || { echo "usage: scripts/python_test_deps.sh <provision|test>" >&2; exit 2; }
PYTHON_BIN="$(resolve_python)"
case "$1" in
  provision)
    exec env PYTHONNOUSERSITE=1 "$PYTHON_BIN" -B "$ROOT/scripts/python_test_deps.py" provision
    ;;
  test)
    env PYTHONNOUSERSITE=1 PYTHONPATH="$DEPS" \
      "$PYTHON_BIN" -S -B "$ROOT/scripts/python_test_deps.py" verify
    env PYTHONNOUSERSITE=1 PYTHONPATH="$DEPS:$ROOT/scripts" \
      "$PYTHON_BIN" -S -B "$ROOT/scripts/testing_package_manifest_test.py"
    env PYTHONNOUSERSITE=1 PYTHONPATH="$DEPS:$ROOT/scripts" \
      "$PYTHON_BIN" -S -B "$ROOT/scripts/testing_evidence_manifest_schema_test.py"
    env PYTHONNOUSERSITE=1 PYTHONPATH="$DEPS:$ROOT/scripts" \
      "$PYTHON_BIN" -S -B "$ROOT/scripts/testing_results_schema_test.py"
    ;;
  *)
    echo "usage: scripts/python_test_deps.sh <provision|test>" >&2
    exit 2
    ;;
esac
