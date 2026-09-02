# Testing Result Authority v1

`AssertionReducer` is the provider-neutral semantic authority for test status. Runtime and executors own effects and observations, but Browser or process success cannot establish `passed`.

## Published identities

- `testing-assertion-reducer-identity.v1` identifies the supported reducer by symbolic `reducer_id`, semantic `reducer_version`, `policy_profile`, `reducer_sha256`, and supported result contract majors.
- `testing-result-authority-receipt.v1` binds one admitted invocation and release identity to one StructuredPlan, executor, reducer, `testing-case-result-set.v2`, evidence manifest, and execution completion identity.
- `fkst-testing-result-authority-canonical-json.v1` uses UTF-8 JSON with lexicographically sorted object keys, no insignificant whitespace, and one trailing newline for persisted bytes.

## Digest domains

`reducer_sha256` is SHA-256 over the canonical reducer identity with `reducer_sha256` absent. `receipt_sha256` is SHA-256 over the canonical receipt with `receipt_sha256` set to 64 lowercase zeroes. Artifact reference digests bind persisted bytes; `case_result_set_content_sha256` and `evidence_manifest_content_sha256` bind canonical contract content. `completed_execution_sha256` binds the execution receipt independently from the result-authority receipt.

## Verification

An offline verifier validates all closed fields and digests, independently invokes the identified reducer over the exact bound semantic inputs, and compares the recomputed status projection with the exact bound `CaseResultSet`. A structurally valid and internally digest-consistent receipt is invalid when reducer recomputation disagrees with its result bytes.

The reducer keeps `assertion_failure`, `cancelled`, `infrastructure_failure`, and `lost_or_inconclusive` distinct. `testing-package-executor.completed-execution.v1` remains an execution receipt and cannot substitute for `testing-result-authority-receipt.v1`.
