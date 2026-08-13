# Testing Evidence Manifest v1

`testing-evidence-manifest.v1` is the canonical, pointer-only evidence contract owned by `contract.testing_evidence_manifest`. It follows the established content-addressed manifest pattern: deterministic canonical JSON, SHA-256 identity, explicit provenance, and fail-closed referential validation.

A manifest binds one repository, immutable run, and immutable plan to bounded entries. Each entry identifies one `evidence_id`, owning `case_id`, optional `assertion_id`, role, artifact pointer, SHA-256 digest, media type, byte size, producer/version, UTC creation time, sensitivity and redaction classification, policy version/status, and provenance source identity. The initial role/media allowlist is `runner-log`/`text/plain`, `screenshot`/`image/png`, and `sanitized-json`/`application/json`.

`CaseResultSet` binds the manifest using `evidence_manifest_ref` and `evidence_manifest_sha256`. Validation requires every nested evidence reference to use `kind = "evidence"` and resolve to exactly one manifest entry; entries must belong to a result-set case/assertion and the same repository, run, and plan. Duplicate IDs, foreign identities, cross-run pointers, unsupported role/media, and digest mismatches fail closed.

The manifest never embeds evidence bytes. Artifact pointers must be relative, run-scoped `artifact` references; absolute paths, traversal, raw DOM, cookies, headers, credentials, environments, and argv are outside this public contract.

The canonical digest is computed over canonical JSON with the `canonical_sha256` field excluded, avoiding self-reference. Object keys are sorted and arrays retain order.
