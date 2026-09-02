#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import selectors
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CORPUS = ROOT / "conformance" / "testing-package-release-admission.v1.json"
MAX_CORPUS_BYTES = 1024 * 1024
MAX_ADAPTER_STDOUT_BYTES = 1024 * 1024
MAX_ADAPTER_STDERR_BYTES = 64 * 1024
REQUEST_SCHEMA = "testing-package-release-admission-conformance-request.v1"
OBSERVATION_SCHEMA = "testing-package-release-admission-conformance-observation.v1"
CORPUS_SCHEMA = "testing-package-release-admission-conformance.v1"
PROTOCOL = "stdin-stdout-json.v1"
MUTATION_FIELDS = ("journal", "cache", "workspace", "process", "browser", "evidence")
REQUIRED_CASES = {
    "immutable-fetch-admit-cache-replay",
    "exact-byte-binding-rejections",
    "release-authority-rejections",
    "compatibility-rejections",
    "entrypoint-mapping-rejections",
    "mutable-identity-rejections",
    "same-key-different-digest-conflict",
    "cache-and-resolver-fail-closed",
    "explicit-update",
    "approved-rollback",
    "anti-rollback-rejection",
    "restart-recovery",
    "claim-deadline-policy-rejections",
}


class ConformanceError(RuntimeError):
    pass


def closed_object(value: Any, keys: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ConformanceError(f"{label} must contain exactly {sorted(keys)}")
    return value


def nonempty_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 256:
        raise ConformanceError(f"{label} must be a bounded non-empty string")
    return value


def digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
        raise ConformanceError(f"{label} must be lowercase SHA-256 hex")
    return value


def validate_mutations(value: Any, label: str) -> None:
    item = closed_object(value, set(MUTATION_FIELDS), label)
    for field in MUTATION_FIELDS:
        if not isinstance(item[field], int) or isinstance(item[field], bool) or item[field] < 0:
            raise ConformanceError(f"{label}.{field} must be a non-negative integer")


def zero_mutations(value: dict[str, Any]) -> bool:
    return all(value[field] == 0 for field in MUTATION_FIELDS)


def validate_receipt(value: Any, label: str) -> None:
    receipt = closed_object(
        value,
        {
            "admission_key", "admission_digest", "release_ref", "release_sequence",
            "package_content_sha256", "manifest_digest", "catalog_digest", "schema_set_digest",
            "dependency_lock_digest", "executor_id", "entrypoint", "contract_major", "policy_digest",
            "capability_set_digest", "current_claim_digest", "canonical_request_sha256",
        },
        label,
    )
    for field in ("admission_key", "release_ref", "executor_id", "entrypoint", "contract_major"):
        nonempty_string(receipt[field], f"{label}.{field}")
    if not receipt["release_ref"].startswith("immutable://") or "@sha256:" not in receipt["release_ref"]:
        raise ConformanceError(f"{label}.release_ref must be immutable and content-addressed")
    if not isinstance(receipt["release_sequence"], int) or isinstance(receipt["release_sequence"], bool) or receipt["release_sequence"] < 0:
        raise ConformanceError(f"{label}.release_sequence must be a non-negative integer")
    for field in (
        "admission_digest", "package_content_sha256", "manifest_digest", "catalog_digest",
        "schema_set_digest", "dependency_lock_digest", "policy_digest", "capability_set_digest",
        "current_claim_digest", "canonical_request_sha256",
    ):
        digest(receipt[field], f"{label}.{field}")


def validate_corpus(corpus: Any) -> dict[str, Any]:
    value = closed_object(corpus, {"schema", "protocol", "compatibility", "releases", "cases"}, "corpus")
    if value["schema"] != CORPUS_SCHEMA or value["protocol"] != PROTOCOL:
        raise ConformanceError("unsupported corpus schema or protocol")

    compatibility = closed_object(
        value["compatibility"],
        {"contract_major", "canonicalization_profile", "execution_profile", "capabilities", "platform", "executor"},
        "compatibility",
    )
    for field in ("contract_major", "canonicalization_profile", "execution_profile", "platform"):
        nonempty_string(compatibility[field], f"compatibility.{field}")
    if not isinstance(compatibility["capabilities"], list) or not compatibility["capabilities"]:
        raise ConformanceError("compatibility.capabilities must be a non-empty array")
    for index, capability in enumerate(compatibility["capabilities"]):
        nonempty_string(capability, f"compatibility.capabilities[{index}]")
    executor = closed_object(compatibility["executor"], {"executor_id", "entrypoint"}, "compatibility.executor")
    nonempty_string(executor["executor_id"], "compatibility.executor.executor_id")
    nonempty_string(executor["entrypoint"], "compatibility.executor.entrypoint")

    releases = value["releases"]
    if not isinstance(releases, list) or len(releases) != 4:
        raise ConformanceError("corpus must define four release identities")
    release_ids: set[str] = set()
    sequences: dict[str, int] = {}
    release_keys = {
        "id", "immutable_ref", "release_sequence", "package_version", "package_content_sha256",
        "manifest_digest", "catalog_digest", "schema_set_digest", "dependency_lock_digest",
    }
    for index, release_value in enumerate(releases):
        release = closed_object(release_value, release_keys, f"releases[{index}]")
        release_id = nonempty_string(release["id"], f"releases[{index}].id")
        if release_id in release_ids:
            raise ConformanceError(f"duplicate release id: {release_id}")
        release_ids.add(release_id)
        immutable_ref = nonempty_string(release["immutable_ref"], f"releases[{index}].immutable_ref")
        if not immutable_ref.startswith("immutable://") or "@sha256:" not in immutable_ref:
            raise ConformanceError(f"release {release_id} is not an exact immutable reference")
        sequence = release["release_sequence"]
        if not isinstance(sequence, int) or isinstance(sequence, bool) or sequence < 0:
            raise ConformanceError(f"release {release_id} has invalid release_sequence")
        sequences[release_id] = sequence
        nonempty_string(release["package_version"], f"releases[{index}].package_version")
        for field in ("package_content_sha256", "manifest_digest", "catalog_digest", "schema_set_digest", "dependency_lock_digest"):
            digest(release[field], f"releases[{index}].{field}")
    if release_ids != {"prior-admitted", "baseline", "update", "older-unapproved"}:
        raise ConformanceError("release identities do not match the required transition matrix")
    if not (sequences["older-unapproved"] < sequences["prior-admitted"] < sequences["baseline"] < sequences["update"]):
        raise ConformanceError("trusted release_sequence values must define old, prior, baseline, and update order")

    cases = value["cases"]
    if not isinstance(cases, list) or not cases:
        raise ConformanceError("cases must be a non-empty array")
    case_names: set[str] = set()
    for case_index, case_value in enumerate(cases):
        case = closed_object(case_value, {"name", "invariant", "trials", "expected_observation"}, f"cases[{case_index}]")
        name = nonempty_string(case["name"], f"cases[{case_index}].name")
        nonempty_string(case["invariant"], f"cases[{case_index}].invariant")
        if name in case_names:
            raise ConformanceError(f"duplicate case name: {name}")
        case_names.add(name)
        trials = case["trials"]
        if not isinstance(trials, list) or not trials:
            raise ConformanceError(f"case {name} must contain trials")
        trial_names: set[str] = set()
        for trial_index, trial_value in enumerate(trials):
            trial = closed_object(trial_value, {"name", "operations"}, f"case {name} trial {trial_index}")
            trial_name = nonempty_string(trial["name"], f"case {name} trial name")
            if trial_name in trial_names:
                raise ConformanceError(f"case {name} has duplicate trial {trial_name}")
            trial_names.add(trial_name)
            operations = trial["operations"]
            if not isinstance(operations, list) or not operations:
                raise ConformanceError(f"case {name} trial {trial_name} must contain operations")
            operation_ids: set[str] = set()
            for operation_index, operation in enumerate(operations):
                if not isinstance(operation, dict):
                    raise ConformanceError(f"case {name} operation {operation_index} must be an object")
                unknown = set(operation) - {"id", "kind", "release", "admission_key", "fault", "transition", "authority_decision", "crash_after"}
                if unknown or not {"id", "kind"}.issubset(operation):
                    raise ConformanceError(f"case {name} operation has unknown or missing fields")
                operation_id = nonempty_string(operation["id"], f"case {name} operation id")
                if operation_id in operation_ids:
                    raise ConformanceError(f"case {name} trial {trial_name} has duplicate operation {operation_id}")
                operation_ids.add(operation_id)
                kind = nonempty_string(operation["kind"], f"case {name} operation kind")
                if kind not in {"admit", "restart-runtime"}:
                    raise ConformanceError(f"case {name} has unsupported operation kind {kind}")
                if kind == "admit" and operation.get("release") not in release_ids:
                    raise ConformanceError(f"case {name} operation references unknown release")

        observation = case["expected_observation"]
        if not isinstance(observation, dict) or observation.get("schema") != OBSERVATION_SCHEMA or observation.get("case") != name:
            raise ConformanceError(f"case {name} has an invalid expected observation envelope")
        if set(observation) != {"schema", "case", "trials"} or not isinstance(observation["trials"], list):
            raise ConformanceError(f"case {name} expected observation is not closed")
        if [trial.get("name") for trial in observation["trials"]] != [trial["name"] for trial in trials]:
            raise ConformanceError(f"case {name} observation trial order does not match inputs")
        for trial_index, expected_trial in enumerate(observation["trials"]):
            if not isinstance(expected_trial, dict) or set(expected_trial) != {"name", "steps"}:
                raise ConformanceError(f"case {name} expected trial is not closed")
            steps = expected_trial["steps"]
            operations = trials[trial_index]["operations"]
            if not isinstance(steps, list) or len(steps) != len(operations):
                raise ConformanceError(f"case {name} expected step count does not match operations")
            for step_index, step in enumerate(steps):
                if not isinstance(step, dict) or step.get("id") != operations[step_index]["id"]:
                    raise ConformanceError(f"case {name} expected step order does not match operations")
                if not {"id", "status", "code", "mutations"}.issubset(step):
                    raise ConformanceError(f"case {name} expected step is missing required fields")
                validate_mutations(step["mutations"], f"case {name} expected mutations")
                if step["status"] in {"rejected", "conflict", "replayed"} and not zero_mutations(step["mutations"]):
                    raise ConformanceError(f"case {name} {step['status']} step must have zero mutation deltas")
                if step["status"] == "admitted" and any(step["mutations"][field] != 0 for field in ("workspace", "process", "browser", "evidence")):
                    raise ConformanceError(f"case {name} admission cannot perform execution-owned effects")
                if "receipt" in step:
                    validate_receipt(step["receipt"], f"case {name} receipt")
    if case_names != REQUIRED_CASES:
        missing = sorted(REQUIRED_CASES - case_names)
        extra = sorted(case_names - REQUIRED_CASES)
        raise ConformanceError(f"case matrix mismatch: missing={missing} extra={extra}")
    return value


def load_corpus(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_bytes()
    except OSError as error:
        raise ConformanceError(f"cannot read corpus: {error}") from error
    if len(raw) > MAX_CORPUS_BYTES:
        raise ConformanceError("corpus exceeds the bounded input size")
    try:
        return validate_corpus(json.loads(raw.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ConformanceError(f"corpus is not valid UTF-8 JSON: {error}") from error


def adapter_request(corpus: dict[str, Any], case: dict[str, Any]) -> bytes:
    request = {
        "schema": REQUEST_SCHEMA,
        "protocol": PROTOCOL,
        "compatibility": corpus["compatibility"],
        "releases": corpus["releases"],
        "case": {field: case[field] for field in ("name", "invariant", "trials")},
    }
    return (json.dumps(request, separators=(",", ":"), ensure_ascii=False) + "\n").encode("utf-8")


def isolated_adapter(adapter: list[str], directory: Path) -> list[str]:
    source = Path(adapter[0]).resolve()
    if not source.is_file():
        raise ConformanceError(f"adapter executable is not a file: {adapter[0]}")
    staged = directory / "adapter"
    shutil.copy2(source, staged)
    staged.chmod(staged.stat().st_mode | 0o100)
    return [str(staged), *adapter[1:]]


def adapter_environment(directory: Path) -> dict[str, str]:
    return {
        "HOME": str(directory),
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": os.defpath,
        "PYTHONNOUSERSITE": "1",
        "TMPDIR": str(directory),
    }


def run_adapter(adapter: list[str], request: bytes, timeout_seconds: float, case_name: str) -> tuple[int, bytes, bytes]:
    with tempfile.TemporaryDirectory(prefix="fkst-release-adapter-") as temporary:
        directory = Path(temporary)
        try:
            process = subprocess.Popen(
                isolated_adapter(adapter, directory),
                cwd=directory,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=adapter_environment(directory),
            )
        except OSError as error:
            raise ConformanceError(f"{case_name}: adapter could not start: {error}") from error
        assert process.stdin is not None and process.stdout is not None and process.stderr is not None
        try:
            process.stdin.write(request)
            process.stdin.close()
        except BrokenPipeError:
            pass

        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        output = {"stdout": bytearray(), "stderr": bytearray()}
        limits = {"stdout": MAX_ADAPTER_STDOUT_BYTES, "stderr": MAX_ADAPTER_STDERR_BYTES}
        deadline = time.monotonic() + timeout_seconds
        try:
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    process.kill()
                    process.wait()
                    raise ConformanceError(f"{case_name}: adapter timed out after {timeout_seconds:g} seconds")
                for key, _ in selector.select(remaining):
                    chunk = os.read(key.fileobj.fileno(), 65536)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        continue
                    stream = key.data
                    output[stream].extend(chunk)
                    if len(output[stream]) > limits[stream]:
                        process.kill()
                        process.wait()
                        raise ConformanceError(f"{case_name}: adapter {stream} exceeds the bounded output size")
            return process.wait(), bytes(output["stdout"]), bytes(output["stderr"])
        finally:
            selector.close()
            if process.poll() is None:
                process.kill()
                process.wait()


def run_case(adapter: list[str], corpus: dict[str, Any], case: dict[str, Any], timeout_seconds: float) -> None:
    returncode, stdout, stderr_bytes = run_adapter(adapter, adapter_request(corpus, case), timeout_seconds, case["name"])
    if returncode != 0:
        stderr = stderr_bytes.decode("utf-8", errors="replace").strip()
        raise ConformanceError(f"{case['name']}: adapter exited {returncode}: {stderr}")
    try:
        observation = json.loads(stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ConformanceError(f"{case['name']}: adapter did not emit one UTF-8 JSON observation") from error
    if observation != case["expected_observation"]:
        expected = json.dumps(case["expected_observation"], sort_keys=True, separators=(",", ":"))
        actual = json.dumps(observation, sort_keys=True, separators=(",", ":"))
        raise ConformanceError(f"{case['name']}: observation mismatch\nexpected: {expected}\nactual:   {actual}")


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run Testing Package release admission black-box conformance")
    parser.add_argument("--corpus", type=Path, default=DEFAULT_CORPUS)
    parser.add_argument("--adapter", required=True, help="adapter executable path")
    parser.add_argument("--adapter-arg", action="append", default=[], help="repeatable adapter argument")
    parser.add_argument("--case", action="append", default=[], help="run only the named case; repeatable")
    parser.add_argument("--timeout-seconds", type=float, default=30.0)
    arguments = parser.parse_args(argv)
    if arguments.timeout_seconds <= 0 or arguments.timeout_seconds > 300:
        parser.error("--timeout-seconds must be greater than zero and at most 300")
    return arguments


def main(argv: list[str] | None = None) -> int:
    arguments = parse_arguments(sys.argv[1:] if argv is None else argv)
    try:
        corpus = load_corpus(arguments.corpus)
        selected = set(arguments.case)
        known = {case["name"] for case in corpus["cases"]}
        unknown = sorted(selected - known)
        if unknown:
            raise ConformanceError(f"unknown selected cases: {unknown}")
        cases = [case for case in corpus["cases"] if not selected or case["name"] in selected]
        adapter = [arguments.adapter, *arguments.adapter_arg]
        for case in cases:
            run_case(adapter, corpus, case, arguments.timeout_seconds)
            print(f"testing-package-release-admission: PASS {case['name']}")
        print(f"testing-package-release-admission: PASS {len(cases)} case(s)")
        return 0
    except ConformanceError as error:
        print(f"testing-package-release-admission: FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
