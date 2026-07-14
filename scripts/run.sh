#!/usr/bin/env bash
# Runner for fkst-packages-testing, a testing-domain package workspace on fkst-substrate.
#
# This repository owns its testing packages and local testing libraries. It hydrates the revision in
# `.fkst/conformance/fkst-packages.pin` as a clean, read-only platform checkout, reuses its binary and
# source-ratchet contracts, and can delegate repository-level host commands to that pinned checkout.
#
# Conformance posture (why single-root, not a composed host graph): each flat package's public entry
# queue (for example module_test_request, browser_readiness_check, or artifact_summary) is produced
# by a HOST composer, not by this library. So flat packages are validated SINGLE-ROOT
# (--project-root == --package-root), while lifecycle packages that declare [event_deps] are validated
# CLOSED-WORLD over the roots listed in .fkst/conformance/composed-roots. Closing a full production
# graph is a host's job; this repo owns reusable testing-domain building blocks.
#
# The engine source is pinned by .fkst/substrate-ref (a reproducible fkst-substrate SHA kept coherent
# with the fkst-packages pin's own .fkst/substrate-ref), not a floating branch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load local, machine-specific config (BIN=, FKST_* posture) if present. Exported so the engine and
# the reused fkst-packages helpers see it. Template: env.example (cp env.example .env).
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

PIN_FILE="$ROOT/.fkst/conformance/fkst-packages.pin"
CHECKOUT="$ROOT/.fkst/run/fkst-packages-conformance"
REPO_URL="https://github.com/ChronoAIProject/fkst-packages.git"

# The dedicated pin is the hydration coordinate. The workspace and lock repeat the same source
# identity so host composition is explicit and mechanically checked. Comments (`#`) are ignored.
read_fkst_packages_pin() {
  local pin
  pin="$(sed -n '/^[0-9a-fA-F]\{40\}$/{p;q;}' "$PIN_FILE" 2>/dev/null || true)"
  if [ -z "$pin" ]; then
    echo "error: $PIN_FILE must contain a full 40-hex fkst-packages commit sha" >&2
    exit 1
  fi
  printf '%s\n' "$pin"
}

ensure_fkst_packages_checkout() {
  local pin="$1" current
  if [ -d "$CHECKOUT/.git" ]; then
    current="$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null || true)"
    if [ "$current" = "$pin" ]; then printf '%s\n' "$CHECKOUT"; return 0; fi
    rm -rf "$CHECKOUT"
  elif [ -e "$CHECKOUT" ]; then
    rm -rf "$CHECKOUT"
  fi
  mkdir -p "$(dirname "$CHECKOUT")"
  git clone --quiet --no-checkout "$REPO_URL" "$CHECKOUT"
  git -C "$CHECKOUT" checkout --quiet "$pin"
  printf '%s\n' "$CHECKOUT"
}

resolve_python() {
  local candidate
  if [ -n "${PYTHON:-}" ]; then
    printf '%s\n' "$PYTHON"
    return 0
  fi
  for candidate in python3.13 python3.12 python3.11 python3; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" - <<'PY' >/dev/null 2>&1
import sys
raise SystemExit(0 if sys.version_info >= (3, 11) else 1)
PY
    then
      command -v "$candidate"
      return 0
    fi
  done
  echo "error: Python 3.11+ is required for TOML-aware platform and source ratchets" >&2
  return 1
}

usage() {
  cat <<'EOF'
usage: scripts/run.sh <check|test|ai-pipeline-smoke|live-cdp-smoke|example|supervise|host> [args]

  check               single-platform-pin guard + shared source ratchets + per-package engine
                      conformance (flat -> single-root; composed -> closed-world over its graph)
  test [pkg]          check + engine self-test + per-package single-root unit tests (hermetic,
                      codex-free); optional single package
  ai-pipeline-smoke   run the hermetic AI authoring/review/CDP handoff smoke across pipeline seams
  live-cdp-smoke      run the environment-gated testing_runtime smoke against local Chrome/CDP
  example <name>      run a downstream integration fixture from examples/<name>
  supervise <pkg>     run one testing package's event machine (composed packages run closed-world
                      across their declared graph; flat packages dry-run until skills are pinned)
  host -- <command>   delegate repository-level check, test, or supervise to the pinned read-only
                      fkst-packages host runner using .fkst/compose/package-roots

Most packages are flat building blocks, validated single-root (--project-root == --package-root) the
way fkst-packages validates its own flat packages; a host closes their graph by producing their entry
queues. A COMPOSED package (fkst.toml [event_deps]) references other packages' queues, so it is
validated/run CLOSED-WORLD over the full package-root set declared in .fkst/conformance/composed-roots.
EOF
}

# Reuse the shared BIN-resolution contract from the pinned checkout (DRY): $BIN > .fkst/env > PATH >
# sibling ../fkst-substrate > pinned-source cache. CI injects BIN and never builds.
resolve_testing_bin() {
  [ -n "${BIN:-}" ] && [ -x "${BIN:-}" ] && return 0
  # shellcheck source=/dev/null
  . "$shared/scripts/bin_bootstrap.sh"
  if ! resolve_bin_contract "$ROOT" "bootstrap"; then
    echo "error: $RESOLVE_BIN_ERROR" >&2
    if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "  CI must build fkst-substrate and inject BIN; scripts/run.sh will not build in CI." >&2
    fi
    exit 1
  fi
  BIN="$RESOLVED_BIN"
  export BIN
}

ensure_host_lock() {
  local pin="$1" output_file rc
  output_file="$(mktemp "${TMPDIR:-/tmp}/fkst-host-lock.XXXXXX")"
  set +e
  "$BIN" host lock --project-root "$ROOT" >"$output_file" 2>&1
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    rm -f "$output_file"
    return 0
  fi
  if ! grep -q "unknown subcommand: host" "$output_file"; then
    cat "$output_file" >&2
    rm -f "$output_file"
    return "$rc"
  fi
  rm -f "$output_file"
  "$PYTHON_BIN" - "$ROOT" "$shared" "$pin" <<'PY'
import hashlib
import os
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path

root = Path(sys.argv[1])
platform = Path(sys.argv[2])
pin = sys.argv[3]
workspace = tomllib.loads((root / "fkst.workspace.toml").read_text(encoding="utf-8"))
sources = workspace.get("external_sources")
if not isinstance(sources, list) or len(sources) != 1 or not isinstance(sources[0], dict):
    raise SystemExit("error: expected exactly one [[external_sources]] table")
source = sources[0]
source_id = source.get("id")
git_url = source.get("git")
libraries = source.get("libraries")
if not isinstance(source_id, str) or not isinstance(git_url, str):
    raise SystemExit("error: external source id and git are required")
if not isinstance(libraries, list) or not all(isinstance(item, str) for item in libraries):
    raise SystemExit("error: external source libraries must be a string list")

def digest_tree(path: Path) -> str:
    digest = hashlib.sha256()
    if not path.is_dir():
        raise SystemExit(f"error: missing path for lock digest: {path}")

    def update_item(item: Path) -> None:
        relative = item.relative_to(path).as_posix()
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        if item.is_symlink():
            digest.update(b"l")
            digest.update(os.fsencode(os.readlink(item)))
        else:
            digest.update(b"f")
            digest.update(item.read_bytes())
        digest.update(b"\0")

    def collect(directory: Path) -> None:
        for item in sorted(directory.iterdir(), key=lambda child: str(child)):
            if item.name == ".git":
                continue
            if item.is_dir() and not item.is_symlink():
                collect(item)
                continue
            if item.is_symlink() or item.is_file():
                update_item(item)

    collect(path)
    return "sha256-" + digest.hexdigest()

def digest_exports(unit_root: Path) -> str:
    public_root = unit_root / "public"
    return digest_tree(public_root if public_root.is_dir() else unit_root)

def discover_library_units(checkout_root: Path) -> dict[str, Path]:
    manifest = tomllib.loads((checkout_root / "fkst.workspace.toml").read_text(encoding="utf-8"))
    workspace_table = manifest.get("workspace")
    if not isinstance(workspace_table, dict):
        raise SystemExit("error: external source workspace table is missing")
    unit_patterns = workspace_table.get("units")
    if not isinstance(unit_patterns, list) or not all(isinstance(item, str) for item in unit_patterns):
        raise SystemExit("error: external source workspace units must be a string list")

    units: dict[str, Path] = {}
    for pattern in unit_patterns:
        candidates = checkout_root.glob(pattern) if any(char in pattern for char in "*?[") else [checkout_root / pattern]
        for unit_root in candidates:
            unit_manifest = unit_root / "fkst.toml"
            if not unit_manifest.is_file():
                continue
            unit = tomllib.loads(unit_manifest.read_text(encoding="utf-8"))
            if unit.get("kind") != "library":
                continue
            library_table = unit.get("library")
            if isinstance(library_table, dict) and isinstance(library_table.get("name"), str):
                name = library_table["name"]
            elif isinstance(unit.get("name"), str):
                name = unit["name"]
            else:
                raise SystemExit(f"error: library at {unit_root} does not declare a name")
            previous = units.get(name)
            if previous is not None:
                raise SystemExit(
                    f"error: external source declares duplicate library {name!r} at {previous} and {unit_root}"
                )
            units[name] = unit_root
    return units

def export_clean_tree(repo: Path, rev: str, destination: Path) -> None:
    archive = subprocess.run(
        ["git", "-C", str(repo), "archive", "--format=tar", rev],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if archive.returncode != 0:
        raise SystemExit(
            "error: external source archive failed: "
            + archive.stderr.decode("utf-8", errors="replace").strip()
        )
    extract = subprocess.run(
        ["tar", "-xf", "-", "-C", str(destination)],
        input=archive.stdout,
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    if extract.returncode != 0:
        raise SystemExit(
            "error: external source archive extraction failed: "
            + extract.stderr.decode("utf-8", errors="replace").strip()
        )

lines = [
]
with tempfile.TemporaryDirectory(prefix="fkst-host-lock-") as temporary:
    archive_root = Path(temporary) / "source"
    archive_root.mkdir()
    export_clean_tree(platform, pin, archive_root)
    library_units = discover_library_units(archive_root)

    lines.extend([
        "[[external_source]]",
        f'id = "{source_id}"',
        f'git = "{git_url}"',
        "",
        "[external_source.intent]",
        f'rev = "{pin}"',
        "",
        "[external_source.resolved]",
        f'rev = "{pin}"',
        f'tree_sha256 = "{digest_tree(archive_root)}"',
        "",
    ])
    for name in libraries:
        unit_root = library_units.get(name)
        if unit_root is None:
            raise SystemExit(f"error: external source library {name!r} is absent")
        unit = unit_root.relative_to(archive_root).as_posix()
        lines.extend([
            "[[external_source.libraries]]",
            f'name = "{name}"',
            f'unit = "{unit}"',
            f'exports_sha256 = "{digest_exports(unit_root)}"',
            "",
        ])
tmp = root / f".fkst.lock.{os.getpid()}.tmp"
tmp.write_text("\n".join(lines), encoding="utf-8")
tmp.replace(root / "fkst.lock")
PY
}

# Shared, engine-independent source ratchets (max-lines, producer-liveness, ...), run against this
# repo as an external project root. Reused verbatim from the pinned checkout.
run_source_ratchets() {
  echo "=== source ratchets ==="
  local args=(--project-root "$ROOT") coverage_base
  [ -d "$ROOT/.fkst/conformance/allowlists" ] && args+=(--allowlist-dir "$ROOT/.fkst/conformance/allowlists")
  coverage_base="$(local_coverage_base_ref)"
  if [ -n "$coverage_base" ]; then
    env FKST_LUA_COVERAGE_BASE_REF="$coverage_base" PYTHONPATH="$shared/scripts${PYTHONPATH:+:$PYTHONPATH}" "$PYTHON_BIN" -B "$shared/scripts/check_repo.py" "${args[@]}"
  else
    env PYTHONPATH="$shared/scripts${PYTHONPATH:+:$PYTHONPATH}" "$PYTHON_BIN" -B "$shared/scripts/check_repo.py" "${args[@]}"
  fi
}

list_packages() {
  local d
  for d in "$ROOT"/packages/*/; do
    [ -d "$d" ] || continue
    printf '%s\n' "${d%/}"
  done
}

package_dir() {
  local name="$1"
  local dir="$ROOT/packages/$name"
  [ -d "$dir" ] || { echo "error: no package named '$name' under packages/" >&2; exit 1; }
  printf '%s\n' "$dir"
}

# Run an engine command, dropping advisory `PASS ` lines but preserving the engine's own exit code
# via PIPESTATUS (a failing package must fail the run; an all-pass pipe must not). set +e guards the
# pipe so a grep that matches nothing never trips the script-wide set -e.
run_engine() {
  local rc
  set +e
  "$@" 2>&1 | grep -vE '^PASS '
  rc=${PIPESTATUS[0]}
  set -e
  return "$rc"
}

local_coverage_base_ref() {
  if [ -n "${FKST_LUA_COVERAGE_BASE_REF:-}" ] || [ -n "${GITHUB_BASE_REF:-}" ]; then
    return 0
  fi
  local branch
  branch="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  case "$branch" in
    ""|HEAD|/*|-*|*..*) return 0 ;;
    *) printf '%s\n' "$branch" ;;
  esac
}

# --- Composed-package support -------------------------------------------------------------------
# A COMPOSED package (fkst.toml [event_deps]) references sibling/platform packages' queues across
# namespaces, so it must be validated CLOSED-WORLD over its whole event graph — single-root (partial-
# graph) can't resolve a cross-namespace ref. Each top-level composed package this repo owns declares
# its full package-root set in .fkst/conformance/composed-roots (closing the world is a host's job;
# we declare exactly the set a host would compose). Flat packages stay single-root.
COMPOSED_ROOTS_FILE="$ROOT/.fkst/conformance/composed-roots"

# The roots declared for a composed package (empty if <name> is not a top-level composed entry).
composed_roots_for() {
  [ -f "$COMPOSED_ROOTS_FILE" ] || return 0
  awk -v k="$1" '!/^[[:space:]]*#/ && $1==k { $1=""; sub(/^[[:space:]]+/,""); print; exit }' "$COMPOSED_ROOTS_FILE"
}

# True if <name> appears only as a MEMBER root inside some composed package's set (validated
# transitively as part of that parent's closed-world graph, never standalone).
is_composed_member() {
  [ -f "$COMPOSED_ROOTS_FILE" ] || return 1
  awk -v k="$1" '!/^[[:space:]]*#/ { for (i=2;i<=NF;i++) { t=$i; sub(/^@platform\//,"",t); if (t==k) found=1 } } END { exit !found }' "$COMPOSED_ROOTS_FILE"
}

# A package is "composed" when its manifest declares an [event_deps] section.
package_is_composed() { grep -qE '^\[event_deps\]' "$1/fkst.toml" 2>/dev/null; }

# Resolve a composed-roots token to a package dir: @platform/<name> -> hydrated pin checkout;
# bare <name> -> this repo's packages/<name>.
resolve_composed_root() {
  case "$1" in
    @platform/*) printf '%s\n' "$shared/packages/${1#@platform/}" ;;
    *)           printf '%s\n' "$ROOT/packages/$1" ;;
  esac
}

copy_tree() {
  local src="$1" dest="$2" exclude_tests="${3:-0}"
  mkdir -p "$dest"
  if [ "$exclude_tests" = "1" ]; then
    (cd "$src" && LC_ALL=C tar --exclude './tests/*_test.lua' --exclude 'tests/*_test.lua' -cf - .) | (cd "$dest" && LC_ALL=C tar xf -)
  else
    (cd "$src" && LC_ALL=C tar -cf - .) | (cd "$dest" && LC_ALL=C tar xf -)
  fi
}

flat_test_workspace() {
  local name="$1" source_root="$2" parent work lib
  parent="$(mktemp -d "${TEST_RT:-${TMPDIR:-/tmp}}/fkst-testing-flat.XXXXXX")"
  work="$parent/$name"
  mkdir -p "$work/packages/$name" "$work/libraries"
  copy_tree "$source_root" "$work/packages/$name" 0
  cp "$source_root/fkst.toml" "$work/fkst.toml"
  [ ! -f "$source_root/core.lua" ] || cp "$source_root/core.lua" "$work/core.lua"
  [ ! -d "$source_root/departments" ] || copy_tree "$source_root/departments" "$work/departments" 0
  [ ! -d "$source_root/raisers" ] || copy_tree "$source_root/raisers" "$work/raisers" 0
  [ ! -d "$source_root/tests" ] || copy_tree "$source_root/tests" "$work/tests" 0
  "$PYTHON_BIN" - "$work/fkst.toml" "$name" <<'PY'
from pathlib import Path
import sys

manifest = Path(sys.argv[1])
name = sys.argv[2]
text = manifest.read_text(encoding="utf-8")
text = text.replace('root = "."', f'root = "packages/{name}"', 1)
text = text.replace('pack = "conformance/pack.toml"', f'pack = "packages/{name}/conformance/pack.toml"', 1)
manifest.write_text(text, encoding="utf-8")
PY
  cat > "$work/fkst.workspace.toml" <<'TOML'
[workspace]
units = [".", "libraries/*"]
packages = ["."]
libraries = ["libraries/*"]

[registries]
workspace = "workspace"
TOML
  for lib in "$ROOT"/libraries/*/; do
    [ -d "$lib" ] || continue
    copy_tree "${lib%/}" "$work/libraries/$(basename "$lib")" 0
  done
  printf '%s\n' "$work"
}

composed_test_workspace() {
  local name="$1" roots="$2" work lib t src dep_name source_root
  source_root="${3:-$ROOT/packages/$name}"
  work="$(mktemp -d "${TEST_RT:-${TMPDIR:-/tmp}}/fkst-testing-composed.XXXXXX")"
  mkdir -p "$work/packages" "$work/libraries"
  cat > "$work/fkst.workspace.toml" <<'TOML'
[workspace]
units = ["packages/*", "libraries/*"]
packages = ["packages/*"]
libraries = ["libraries/*"]

[registries]
workspace = "workspace"
TOML
  for lib in "$ROOT"/libraries/*/; do
    [ -d "$lib" ] || continue
    copy_tree "${lib%/}" "$work/libraries/$(basename "$lib")" 0
  done
  # Platform packages use source-scoped forge/devloop libraries. The local forge mirror wins for
  # host-owned packages; copy any missing platform library so composed package tests close the same
  # library graph as host conformance.
  for dep_name in forge devloop; do
    [ -d "$work/libraries/$dep_name" ] && continue
    [ -d "$shared/libraries/$dep_name" ] || { echo "error: pinned platform library missing: $dep_name" >&2; return 1; }
    copy_tree "$shared/libraries/$dep_name" "$work/libraries/$dep_name" 0
  done
  copy_tree "$source_root" "$work/packages/$name" 0
  for t in $roots; do
    src="$(resolve_composed_root "$t")"
    dep_name="${t#@platform/}"
    [ -d "$src" ] || { echo "error: composed root '$t' -> $src not found (hydrate the pin / check packages/)" >&2; return 1; }
    copy_tree "$src" "$work/packages/$dep_name" 1
  done
  printf '%s\n' "$work"
}

# Run an engine subcommand (conformance|supervise) for one package with the correct scope:
#   top-level composed (in composed-roots) -> CLOSED-WORLD across its declared graph. project-root is
#     the repo (no package-root folds into it), so the engine enforces every consumed queue has a
#     producer — a genuinely closed graph, the same shape the launchd supervisor runs;
#   composed member (a root of another composed package) -> skipped standalone (covered by its parent);
#   undeclared composed ([event_deps] but no entry) -> hard error (tells the maintainer to declare it);
#   flat -> SINGLE-ROOT (partial-graph), the repo default for self-contained blocks.
run_pkg_engine() {
  local sub="$1" pkg="$2" name roots t dir work rc
  name="$(basename "$pkg")"
  roots="$(composed_roots_for "$name")"
  if [ -n "$roots" ]; then
    local args=(--project-root "$ROOT" --package-root "$pkg")
    for t in $roots; do
      dir="$(resolve_composed_root "$t")"
      [ -d "$dir" ] || { echo "error: composed root '$t' -> $dir not found (hydrate the pin / check packages/)" >&2; return 1; }
      args+=(--package-root "$dir")
    done
    echo "    (composed, closed-world: $name + $roots)"
    run_engine "$BIN" "$sub" "${args[@]}"
    return $?
  fi
  if package_is_composed "$pkg"; then
    if is_composed_member "$name"; then
      echo "    (skipped standalone — composed member, validated within its parent's graph)"
      return 0
    fi
    echo "error: $name declares [event_deps] but has no .fkst/conformance/composed-roots entry; declare its closed-world package roots" >&2
    return 1
  fi
  work="$(flat_test_workspace "$name" "$pkg")" || return 1
  set +e
  run_engine "$BIN" "$sub" --project-root "$work" --package-root "$work"
  rc=$?
  set -e
  rm -rf "$(dirname "$work")"
  return "$rc"
}

cmd_check() {
  local fail=0 ran=0 pkg
  "$PYTHON_BIN" -B "$ROOT/scripts/check_ci_contract.py" || fail=1
  run_source_ratchets || fail=1
  resolve_testing_bin
  echo "=== engine conformance (composed closed-world / flat single-root) ==="
  while IFS= read -r pkg; do
    echo "--- $(basename "$pkg") ---"
    ran=$((ran + 1))
    run_pkg_engine conformance "$pkg" || fail=1
  done < <(list_packages)
  if [ "$ran" -eq 0 ]; then echo "error: no packages found under packages/" >&2; return 1; fi
  if [ "$fail" -ne 0 ]; then echo "FAILED: check" >&2; fi
  return "$fail"
}

run_browser_observation_self_test() {
  local target="${1:-}"
  if [ -z "$target" ] || [ "$target" = "browser-observation" ]; then
    echo "=== browser-observation JS self-test ==="
    node "$ROOT/packages/browser-observation/bin/fkst-cdp-observer.js" --self-test
  fi
}

append_coverage_artifact() {
  local package_name="$1" coverage_dir="$2" artifact="$coverage_dir/coverage.json"
  if [ ! -f "$artifact" ]; then
    echo "error: fkst-framework test --coverage did not write coverage.json for $package_name in $coverage_dir" >&2
    return 1
  fi
  COVERAGE_ARTIFACTS+=("$package_name=$artifact")
}

enforce_lua_coverage_ratchet() {
  local output="${FKST_LUA_COVERAGE_OUTPUT:-$ROOT/.fkst/run/lua-coverage/coverage.json}" coverage_base
  if [ "${#COVERAGE_ARTIFACTS[@]}" -eq 0 ]; then
    echo "error: Lua coverage ratchet has no package coverage artifacts" >&2
    return 1
  fi
  PYTHONPATH="$shared/scripts${PYTHONPATH:+:$PYTHONPATH}" \
    FKST_LUA_COVERAGE_MERGED_OUTPUT="$output" \
    "$PYTHON_BIN" -B - "$ROOT" "${COVERAGE_ARTIFACTS[@]}" <<'PY'
import os
import sys
from pathlib import Path

import check_repo_coverage as coverage

root = Path(sys.argv[1])
artifacts = [coverage.parse_covered_json_arg(value) for value in sys.argv[2:]]
count = coverage.write_canonical_coverage_json(
    coverage.merge_covered_sets(artifacts),
    Path(os.environ["FKST_LUA_COVERAGE_MERGED_OUTPUT"]),
    root,
)
print(f"wrote {count} file(s) to {os.environ['FKST_LUA_COVERAGE_MERGED_OUTPUT']}")
PY
  if [ ! -f "$output" ]; then
    echo "error: Lua coverage ratchet did not write coverage artifact: $output" >&2
    return 1
  fi
  (
    cd "$ROOT"
    coverage_base="$(local_coverage_base_ref)"
    if [ -n "$coverage_base" ]; then
      env FKST_LUA_COVERAGE_BASE_REF="$coverage_base" \
        PYTHONPATH="$shared/scripts${PYTHONPATH:+:$PYTHONPATH}" \
        FKST_LUA_COVERAGE_JSON="$output" \
        "$PYTHON_BIN" -B "$shared/scripts/check_repo_coverage.py"
    else
      env PYTHONPATH="$shared/scripts${PYTHONPATH:+:$PYTHONPATH}" \
        FKST_LUA_COVERAGE_JSON="$output" \
        "$PYTHON_BIN" -B "$shared/scripts/check_repo_coverage.py"
    fi
  )
}

cmd_test() {
  local target="${1:-}" fail=0 ran=0 pkg name coverage_dir
  cmd_check
  resolve_testing_bin

  # Hermetic roots so local runs predict CI and never touch ambient durable state. Script-global
  # (not `local`) so the EXIT trap can still see them; `:-` keeps the trap safe under set -u.
  TEST_RT="$(mktemp -d "${TMPDIR:-/tmp}/fkst-testing-rt.XXXXXX")"
  TEST_DURABLE="$(mktemp -d "${TMPDIR:-/tmp}/fkst-testing-durable.XXXXXX")"
  trap 'rm -rf "${TEST_RT:-}" "${TEST_DURABLE:-}"' EXIT
  export FKST_RUNTIME_ROOT="$TEST_RT" FKST_DURABLE_ROOT="$TEST_DURABLE"
  unset FKST_GITHUB_WRITE FKST_SUPERVISOR_PID 2>/dev/null || true
  echo "test hermetic: FKST_RUNTIME_ROOT=$TEST_RT FKST_DURABLE_ROOT=$TEST_DURABLE"
  COVERAGE_ARTIFACTS=()

  echo "=== self-test ==="
  "$BIN" --self-test >/dev/null
  run_browser_observation_self_test "$target"

  echo "=== package tests (single-root, hermetic) ==="
  while IFS= read -r pkg; do
    name="$(basename "$pkg")"
    if [ -n "$target" ] && [ "$name" != "$target" ]; then continue; fi
    # Composed members (e.g. the seam shim) have no independently-closeable world; their behavior is
    # covered inside their parent's closed-world check, so skip them standalone here.
    if [ -z "$(composed_roots_for "$name")" ] && package_is_composed "$pkg" && is_composed_member "$name"; then
      echo "--- $name ---"; echo "    (skipped standalone — composed member)"; continue
    fi
    echo "--- $name ---"
    ran=$((ran + 1))
    roots="$(composed_roots_for "$name")"
    if [ -n "$roots" ]; then
      work="$(composed_test_workspace "$name" "$roots")" || { fail=1; continue; }
      local args=(--project-root "$work" --package-root "$work/packages/$name")
      for t in $roots; do
        args+=(--package-root "$work/packages/${t#@platform/}")
      done
      echo "    (composed tests, closed-world: $name + $roots)"
      coverage_dir="$TEST_RT/package-lua-coverage/$name"
      rm -rf "$coverage_dir"
      mkdir -p "$coverage_dir"
      if run_engine "$BIN" test "${args[@]}" --coverage "$coverage_dir"; then
        append_coverage_artifact "$name" "$coverage_dir" || fail=1
      else
        fail=1
      fi
      rm -rf "$work"
    else
      work="$(flat_test_workspace "$name" "$pkg")" || { fail=1; continue; }
      coverage_dir="$TEST_RT/package-lua-coverage/$name"
      rm -rf "$coverage_dir"
      mkdir -p "$coverage_dir"
      if run_engine "$BIN" test --project-root "$work" --package-root "$work" --coverage "$coverage_dir"; then
        append_coverage_artifact "$name" "$coverage_dir" || fail=1
      else
        fail=1
      fi
      rm -rf "$(dirname "$work")"
    fi
  done < <(list_packages)
  if [ "$ran" -eq 0 ]; then echo "error: no packages matched${target:+ for '$target'}" >&2; return 1; fi
  if [ "$fail" -ne 0 ]; then echo "FAILED: $fail package(s)" >&2; return 1; fi
  if [ -z "$target" ]; then
    echo "=== Lua coverage ratchet ==="
    enforce_lua_coverage_ratchet || return 1
  fi
  echo "OK: $ran package(s)"
}

cmd_ai_pipeline_smoke() {
  local roots work args t rc=0 source_root
  resolve_testing_bin

  roots="$(composed_roots_for testing-pipeline)"
  [ -n "$roots" ] || { echo "error: testing-pipeline composed roots are not declared" >&2; return 1; }
  work="$(composed_test_workspace "testing-pipeline" "$roots")" || return 1
  rm -f "$work/packages/testing-pipeline/tests/"*_test.lua
  cp "$ROOT/scripts/ai_pipeline_author_review_smoke_test.lua" "$work/packages/testing-pipeline/tests/ai_pipeline_author_review_smoke_test.lua"
  args=(--project-root "$work" --package-root "$work/packages/testing-pipeline")
  for t in $roots; do
    args+=(--package-root "$work/packages/${t#@platform/}")
  done
  echo "=== ai pipeline smoke: authoring, consensus review, publication handoff ==="
  run_engine "$BIN" test "${args[@]}" || rc=1
  rm -rf "$work"

  source_root="$ROOT/packages/testing-runner"
  work="$(flat_test_workspace "testing-runner" "$source_root")" || return 1
  rm -f "$work/tests/"*_test.lua
  cp "$ROOT/scripts/ai_pipeline_runner_smoke_test.lua" "$work/tests/ai_pipeline_runner_smoke_test.lua"
  echo "=== ai pipeline smoke: reviewed AI case resumes into CDP execution ==="
  run_engine "$BIN" test --project-root "$work" --package-root "$work" || rc=1
  rm -rf "$(dirname "$work")"
  return "$rc"
}

cmd_live_cdp_smoke() {
  local source_root="$ROOT/packages/testing-runner" work parent rc run_id artifact_rel artifact_source artifact_target
  [ -n "${FKST_LIVE_BASE_URL:-}" ] || { echo "error: FKST_LIVE_BASE_URL is required" >&2; return 1; }
  [ -n "${FKST_LIVE_CDP_URL:-}" ] || { echo "error: FKST_LIVE_CDP_URL is required" >&2; return 1; }
  resolve_testing_bin
  work="$(flat_test_workspace "testing-runner" "$source_root")" || return 1
  parent="$(dirname "$work")"
  rm -f "$work/tests/"*_test.lua
  mkdir -p "$work/departments/live_cdp_smoke"
  cp "$ROOT/scripts/live_cdp_smoke.lua" "$work/departments/live_cdp_smoke/main.lua"
  run_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  artifact_rel=".testing/runs/live-cdp-smoke-$run_id"
  export FKST_LIVE_ARTIFACT_ROOT="$artifact_rel"
  mkdir -p "$work/$artifact_rel"

  set +e
  (
    cd "$work"
    run_engine "$BIN" run "$work/departments/live_cdp_smoke/main.lua" \
      --project-root "$work" \
      --package-root "$work" \
      --owner-namespace testing-runner \
      --event '{"queue":"live_cdp_smoke","payload":{}}'
  )
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    artifact_source="$work/$artifact_rel"
    artifact_target="$ROOT/$artifact_rel"
    if [ ! -d "$artifact_source" ]; then
      echo "error: live CDP smoke passed without producing $artifact_source" >&2
      rc=1
    elif [ -e "$artifact_target" ]; then
      echo "error: refusing to overwrite existing live CDP smoke artifact: $artifact_target" >&2
      rc=1
    else
      mkdir -p "$(dirname "$artifact_target")"
      cp -R "$artifact_source" "$artifact_target"
      echo "live CDP smoke artifacts: $artifact_target"
    fi
  fi
  rm -rf "$parent"
  return "$rc"
}

cmd_example() {
  local name="${1:-generic-host}" example roots work args t
  example="$ROOT/examples/$name"
  [ -d "$example" ] || { echo "error: no example named '$name' under examples/" >&2; exit 1; }
  resolve_testing_bin
  roots="browser-readiness testing-pipeline module-test-loop testing-runner test-artifacts test-publication"
  work="$(composed_test_workspace "$name" "$roots" "$example")" || return 1
  args=(--project-root "$work" --package-root "$work/packages/$name")
  for t in $roots; do
    args+=(--package-root "$work/packages/${t#@platform/}")
  done
  echo "example $name (closed-world: $roots)"
  run_engine "$BIN" test "${args[@]}"
}

cmd_supervise() {
  local name="${1:-}" pkg roots t dir rt durable
  [ -n "$name" ] || { echo "usage: scripts/run.sh supervise <package>" >&2; exit 1; }
  pkg="$(package_dir "$name")"
  resolve_testing_bin
  rt="${FKST_RUNTIME_ROOT:-$ROOT/.fkst/run/runtime}"
  durable="${FKST_DURABLE_ROOT:-$ROOT/.fkst/run/durable}"
  mkdir -p "$rt" "$durable"
  export FKST_RUNTIME_ROOT="$rt" FKST_DURABLE_ROOT="$durable"
  echo "BIN=$BIN"
  roots="$(composed_roots_for "$name")"
  if [ -n "$roots" ]; then
    # Composed: closed-world across the declared graph (supervise is always closed-world in the
    # engine). project-root is the repo so no package-root folds into the host root. This mirrors the
    # launchd supervisor command exactly, but resolves platform roots from the reproducible pin.
    local args=(--project-root "$ROOT" --package-root "$pkg")
    for t in $roots; do
      dir="$(resolve_composed_root "$t")"
      [ -d "$dir" ] || { echo "error: composed root '$t' -> $dir not found" >&2; exit 1; }
      args+=(--package-root "$dir")
    done
    echo "supervise $name (composed closed-world: $roots)"
    exec "$BIN" supervise "${args[@]}" --framework-bin "$BIN"
  fi
  echo "supervise $name (single-root; dry-run until the host write switch + FKST_SKILL_* are pinned)"
  exec "$BIN" supervise --project-root "$pkg" --package-root "$pkg" --framework-bin "$BIN"
}

cmd_host() {
  local python_shim_dir="$ROOT/.fkst/run/python-bin"
  local catalog_root="${FKST_WORKFLOW_CATALOG_ROOT:-$ROOT/.fkst/workflow}"
  case "$catalog_root" in
    /*) ;;
    *) echo "error: FKST_WORKFLOW_CATALOG_ROOT must be an absolute path: $catalog_root" >&2; exit 1 ;;
  esac
  [ -d "$catalog_root" ] || { echo "error: workflow catalog root does not exist: $catalog_root" >&2; exit 1; }
  export FKST_WORKFLOW_CATALOG_ROOT="$catalog_root"
  resolve_testing_bin
  mkdir -p "$python_shim_dir"
  ln -sfn "$PYTHON_BIN" "$python_shim_dir/python3"

  if [ "${1:-}" = "--" ] && [ "${2:-}" = "test" ]; then
    if [ -n "${3:-}" ] && [ "${3:-}" != "github-devloop-workflow" ]; then
      echo "error: unknown workflow host test package: ${3:-}" >&2
      return 2
    fi
    PATH="$python_shim_dir:$PATH" "$shared/scripts/run.sh" host \
      --host-root "$ROOT" \
      --platform-root "$shared" \
      --local-packages "$ROOT/packages" \
      -- check
    PATH="$python_shim_dir:$PATH" \
      env -u FKST_COMPETENCE_BASE_REF -u FKST_LUA_COVERAGE_BASE_REF -u GITHUB_BASE_REF \
      "$shared/scripts/run.sh" test github-devloop-workflow
    return
  fi

  PATH="$python_shim_dir:$PATH" exec "$shared/scripts/run.sh" host \
    --host-root "$ROOT" \
    --platform-root "$shared" \
    --local-packages "$ROOT/packages" \
    "$@"
}

case "${1:-}" in
  check|test|ai-pipeline-smoke|live-cdp-smoke|example|supervise|host) ;;
  -h|--help|help|"") usage; exit 0 ;;
  *) echo "unknown subcommand: $1" >&2; usage >&2; exit 2 ;;
esac

pin="$(read_fkst_packages_pin)"
shared="$(ensure_fkst_packages_checkout "$pin")"
[ -f "$shared/scripts/check_repo.py" ] || { echo "error: shared check_repo.py missing: $shared/scripts/check_repo.py" >&2; exit 1; }

PYTHON_BIN="$(resolve_python)"

# Resolve the declared external source before validating it. fkst.lock is generated evidence and is
# intentionally absent from clean checkouts, so every command recreates it from the pinned workspace.
resolve_testing_bin
ensure_host_lock "$pin"

# Repo-local guard: exactly one fkst-packages coordinate, resolved == hydrated == pinned.
"$PYTHON_BIN" -B "$ROOT/scripts/check_single_platform_pin.py"

sub="$1"; shift
case "$sub" in
  check) cmd_check ;;
  test) cmd_test "$@" ;;
  ai-pipeline-smoke) cmd_ai_pipeline_smoke ;;
  live-cdp-smoke) cmd_live_cdp_smoke ;;
  example) cmd_example "$@" ;;
  supervise) cmd_supervise "$@" ;;
  host) cmd_host "$@" ;;
esac
