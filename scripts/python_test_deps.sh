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
  echo "error: Python 3.11+ is required for schema tests" >&2
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
      "$PYTHON_BIN" -S -B "$ROOT/scripts/schema_test_suite.py" \
      "$ROOT/scripts/testing_package_manifest_test.py" \
      "$ROOT/scripts/testing_evidence_manifest_schema_test.py" \
      "$ROOT/scripts/testing_results_schema_test.py" \
      "$ROOT/scripts/testing_browser_action_schema_test.py" \
      "$ROOT/scripts/testing_package_executor_request_schema_test.py" \
      "$ROOT/scripts/testing_runner_invocation_schema_test.py" \
      "$ROOT/scripts/testing_schema_publication_test.py" \
      "$ROOT/scripts/testing_schema_release_attestation_test.py"
    env PYTHONNOUSERSITE=1 PYTHONPATH="$DEPS:$ROOT/scripts" \
      "$PYTHON_BIN" -S -B "$ROOT/scripts/schema_fixture_runner_test.py"
    if command -v node >/dev/null 2>&1; then
      node --test "$ROOT/scripts/node_schema/conformance.test.mjs"
    elif [ -n "${CI:-}" ]; then
      echo "error: Node is required for schema conformance in CI" >&2; exit 1
    else
      echo "schema-node-conformance: SKIP (node command unavailable)" >&2
    fi
    ;;
  *)
    echo "usage: scripts/python_test_deps.sh <provision|test>" >&2
    exit 2
    ;;
esac
