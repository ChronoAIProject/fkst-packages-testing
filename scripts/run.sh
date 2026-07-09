#!/usr/bin/env bash
# Thin runner for fkst-packages-testing (a testing-domain library of FLAT building-block
# packages that run on the fkst-substrate engine, built on fkst-packages / library B).
#
# This repo owns its testing packages + the vendored platform libraries (libraries/). It hydrates
# the `.fkst/conformance/fkst-packages.pin` checkout and REUSES two shared, engine-independent pieces
# from it — the BIN-resolution contract (bin_bootstrap.sh) and the source ratchets (check_repo.py) —
# then drives the engine itself, once per package.
#
# Conformance posture (why single-root, not a composed host graph): each flat package's public entry
# queue (for example module_test_request, browser_readiness_check, or artifact_summary) is produced
# by a HOST composer, not by this library. So flat packages are validated SINGLE-ROOT
# (--project-root == --package-root), while lifecycle packages that declare [event_deps] are validated
# CLOSED-WORLD over the roots listed in .fkst/conformance/composed-roots. Closing a full production
# graph is a host's job; this repo owns reusable testing-domain building blocks.
#
# The engine source is pinned by .fkst-substrate-ref (a reproducible fkst-substrate SHA kept coherent
# with the fkst-packages pin's own .fkst/substrate-ref), not a floating branch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load local, machine-specific config (BIN=, FKST_* posture) if present. Exported so the engine and
# the reused fkst-packages helpers see it. Template: env.example (cp env.example .env).
if [ -f "$ROOT/.env" ]; then set -a; . "$ROOT/.env"; set +a; fi

PIN_FILE="$ROOT/.fkst/conformance/fkst-packages.pin"
CHECKOUT="$ROOT/.fkst/run/fkst-packages-conformance"
REPO_URL="https://github.com/ChronoAIProject/fkst-packages.git"

# The fkst-packages pin is a dedicated single-line file (the first 40-hex line), kept out of
# fkst.lock so the engine sees a plain self-contained workspace (vendored libraries, no external
# source). Comments (`#`) are ignored.
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

usage() {
  cat <<'EOF'
usage: scripts/run.sh <check|test|example|supervise> [args]

  check               single-platform-pin guard + shared source ratchets + per-package engine
                      conformance (flat -> single-root; composed -> closed-world over its graph)
  test [pkg]          check + engine self-test + per-package single-root unit tests (hermetic,
                      codex-free); optional single package
  example <name>      run a downstream integration fixture from examples/<name>
  supervise <pkg>     run one testing package's event machine (composed packages run closed-world
                      across their declared graph; flat packages dry-run until skills are pinned)

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

# Shared, engine-independent source ratchets (max-lines, producer-liveness, ...), run against this
# repo as an external project root. Reused verbatim from the pinned checkout.
run_source_ratchets() {
  echo "=== source ratchets ==="
  local args=(--project-root "$ROOT")
  [ -d "$ROOT/.fkst/conformance/allowlists" ] && args+=(--allowlist-dir "$ROOT/.fkst/conformance/allowlists")
  PYTHONPATH="$shared/scripts${PYTHONPATH:+:$PYTHONPATH}" python3 -B "$shared/scripts/check_repo.py" "${args[@]}"
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
    (cd "$src" && LC_ALL=C tar --exclude './tests' --exclude './tests/*' --exclude 'tests' --exclude 'tests/*' -cf - .) | (cd "$dest" && LC_ALL=C tar xf -)
    rm -rf "$dest/tests"
  else
    (cd "$src" && LC_ALL=C tar -cf - .) | (cd "$dest" && LC_ALL=C tar xf -)
  fi
}

composed_test_workspace() {
  local name="$1" roots="$2" work lib t src dep_name source_root="${3:-$ROOT/packages/$name}"
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
  local sub="$1" pkg="$2" name roots t dir
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
  run_engine "$BIN" "$sub" --project-root "$pkg" --package-root "$pkg"
}

cmd_check() {
  local fail=0 ran=0 pkg
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

cmd_test() {
  local target="${1:-}" fail=0 ran=0 pkg name
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
      run_engine "$BIN" test "${args[@]}" || fail=1
    else
      run_engine "$BIN" test --project-root "$pkg" --package-root "$pkg" || fail=1
    fi
  done < <(list_packages)
  if [ "$ran" -eq 0 ]; then echo "error: no packages matched${target:+ for '$target'}" >&2; return 1; fi
  if [ "$fail" -ne 0 ]; then echo "FAILED: $fail package(s)" >&2; return 1; fi
  echo "OK: $ran package(s)"
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

case "${1:-}" in
  check|test|example|supervise) ;;
  -h|--help|help|"") usage; exit 0 ;;
  *) echo "unknown subcommand: $1" >&2; usage >&2; exit 2 ;;
esac

pin="$(read_fkst_packages_pin)"
shared="$(ensure_fkst_packages_checkout "$pin")"
[ -f "$shared/scripts/check_repo.py" ] || { echo "error: shared check_repo.py missing: $shared/scripts/check_repo.py" >&2; exit 1; }

# Repo-local guard first: exactly one fkst-packages coordinate, hydrated == pinned.
python3 -B "$ROOT/scripts/check_single_platform_pin.py"

sub="$1"; shift
case "$sub" in
  check) cmd_check ;;
  test) cmd_test "$@" ;;
  example) cmd_example "$@" ;;
  supervise) cmd_supervise "$@" ;;
esac
