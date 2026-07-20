#!/usr/bin/env bash

engine_read_expected_pin() {
  local repo_root="$1" pin_file pin
  pin_file="$repo_root/.fkst/substrate-ref"
  [ -f "$pin_file" ] || { echo "missing authoritative engine pin: $pin_file" >&2; return 1; }
  pin="$(sed -n '/^[[:space:]]*#/d; /^[[:space:]]*$/d; { s/^[[:space:]]*//; s/[[:space:]]*$//; p; q; }' "$pin_file")"
  [[ "$pin" =~ ^[0-9a-fA-F]{40}$ ]] || { echo "invalid authoritative engine pin: $pin_file" >&2; return 1; }
  printf '%s\n' "$pin" | tr 'A-F' 'a-f'
}

engine_probe_pin() {
  local candidate="$1" probe_root output observed rc
  [ -x "$candidate" ] || return 1
  command -v git >/dev/null 2>&1 || return 1
  probe_root="$(mktemp -d "${TMPDIR:-/tmp}/fkst-engine-probe.XXXXXX")" || return 1
  if ! git -C "$probe_root" init -q >/dev/null 2>&1; then
    rm -rf "$probe_root"
    return 1
  fi
  if output="$(cd "$probe_root" && "$candidate" init-package-repo 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    rm -rf "$probe_root"
    return 1
  fi
  observed="$(sed -n '/^[[:space:]]*[0-9a-fA-F]\{40\}[[:space:]]*$/ { s/[[:space:]]//g; p; q; }' "$probe_root/.fkst-substrate-ref" 2>/dev/null || true)"
  if [ -z "$observed" ]; then
    observed="$(printf '%s\n' "$output" | sed -n 's/^init-package-repo substrate_ref=\([0-9a-fA-F]\{40\}\)$/\1/p' | head -1)"
  fi
  rm -rf "$probe_root"
  [[ "$observed" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
  printf '%s\n' "$observed" | tr 'A-F' 'a-f'
}

engine_provenance_message() {
  local expected="$1" observed="$2" selected="$3"
  printf '%s' "expected=$expected observed=$observed selected=$selected remediation=use or rebuild the content-addressed fkst-framework for $expected"
}

engine_accept_candidate() {
  local candidate="$1" expected="$2"
  RESOLVED_BIN="$candidate"
  RESOLVED_ENGINE_PIN="$expected"
  FKST_ENGINE_SOURCE_PIN="$expected"
  FKST_ENGINE_VER="${expected:0:12}"
  export FKST_ENGINE_SOURCE_PIN FKST_ENGINE_VER
}

engine_check_candidate() {
  local candidate="$1" expected="$2" policy="$3" observed="unavailable"
  if [ -x "$candidate" ] && [[ "$candidate" != /* ]]; then
    candidate="$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
  fi
  if [ -x "$candidate" ]; then
    observed="$(engine_probe_pin "$candidate" 2>/dev/null || true)"
    [ -n "$observed" ] || observed="unavailable"
  fi
  if [ "$observed" = "$expected" ]; then
    engine_accept_candidate "$candidate" "$expected"
    return 0
  fi
  if [ "$policy" = "required" ]; then
    RESOLVE_BIN_ERROR="engine provenance mismatch $(engine_provenance_message "$expected" "$observed" "$candidate")"
    return 2
  fi
  echo "warning: skipping engine candidate with mismatched provenance $(engine_provenance_message "$expected" "$observed" "$candidate")" >&2
  return 1
}

engine_env_candidate() {
  local repo_root="$1" candidate
  [ -f "$repo_root/.fkst/env" ] || return 0
  candidate="$(grep -E '^BIN=' "$repo_root/.fkst/env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  candidate="${candidate%%[[:space:]]#*}"
  candidate="${candidate%\"}"; candidate="${candidate#\"}"
  candidate="${candidate%\'}"; candidate="${candidate#\'}"
  printf '%s\n' "$candidate"
}

resolve_pinned_engine() {
  local repo_root="$1" mode="${2:-bootstrap}" expected explicit candidate pin owner repo ref cache_root cache_bin built_bin rc
  RESOLVED_BIN=""
  RESOLVED_ENGINE_PIN=""
  RESOLVE_BIN_ERROR=""
  expected="$(engine_read_expected_pin "$repo_root" 2>/dev/null || true)"
  if [ -z "$expected" ]; then
    RESOLVE_BIN_ERROR="authoritative engine provenance is unavailable expected=<invalid> observed=unavailable selected=<none> remediation=restore a full SHA in $repo_root/.fkst/substrate-ref"
    return 1
  fi

  explicit="${BIN:-}"
  if [ -n "$explicit" ]; then
    engine_check_candidate "$explicit" "$expected" required
    return $?
  fi

  candidate="$(engine_env_candidate "$repo_root")"
  if [ -n "$candidate" ]; then
    [[ "$candidate" = /* ]] || candidate="$repo_root/$candidate"
    engine_check_candidate "$candidate" "$expected" required
    return $?
  fi

  candidate="$(command -v fkst-framework 2>/dev/null || true)"
  if [ -n "$candidate" ]; then
    engine_check_candidate "$candidate" "$expected" optional && return 0
    rc=$?
    [ "$rc" -eq 2 ] && return "$rc"
  fi

  candidate="$repo_root/../fkst-substrate/target/debug/fkst-framework"
  if [ -x "$candidate" ]; then
    engine_check_candidate "$candidate" "$expected" optional && return 0
    rc=$?
    [ "$rc" -eq 2 ] && return "$rc"
  fi

  pin="$(bootstrap_read_pin "$repo_root" 2>/dev/null || printf '%s\n' "$expected")"
  {
    IFS= read -r owner
    IFS= read -r repo
    IFS= read -r ref
  } < <(bootstrap_parse_pin "$pin" 2>/dev/null || true)
  cache_root="$(bootstrap_cache_root 2>/dev/null || true)"
  if [ -n "${owner:-}" ] && [ -n "${repo:-}" ] && [ -n "${ref:-}" ] && [ -n "$cache_root" ]; then
    cache_bin="$(bootstrap_cache_bin_path "$repo_root" "$cache_root" "$owner" "$repo" "$ref" 2>/dev/null || true)"
    if [ -n "$cache_bin" ] && [ -x "$cache_bin" ]; then
      engine_check_candidate "$cache_bin" "$expected" optional && return 0
    fi
  fi

  if [ "$mode" = "readonly" ]; then
    RESOLVE_BIN_ERROR="pinned engine unavailable $(engine_provenance_message "$expected" unavailable "${cache_bin:-<none>}")"
    return 1
  fi
  if [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; then
    RESOLVE_BIN_ERROR="CI engine provenance unavailable $(engine_provenance_message "$expected" unavailable "${explicit:-<none>}")"
    return 1
  fi
  if ! declare -F bootstrap_bin_on_total_miss >/dev/null 2>&1; then
    RESOLVE_BIN_ERROR="pinned engine bootstrap unavailable $(engine_provenance_message "$expected" unavailable "${cache_bin:-<none>}")"
    return 1
  fi
  built_bin="$(bootstrap_bin_on_total_miss "$repo_root")" || return $?
  engine_check_candidate "$built_bin" "$expected" required
}
