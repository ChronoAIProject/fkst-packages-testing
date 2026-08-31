# Testing Evidence Manifest v1

`testing-evidence-manifest.v1` is the canonical, pointer-only evidence contract owned by `contract.testing_evidence_manifest`. It follows the established content-addressed manifest pattern: deterministic canonical JSON, SHA-256 identity, explicit provenance, and fail-closed referential validation.

A manifest binds one repository, immutable run, and immutable plan to bounded entries. Each entry identifies one `evidence_id`, owning `case_id`, optional `assertion_id`, role, artifact pointer, SHA-256 digest, media type, byte size, producer/version, UTC creation time, sensitivity and redaction classification, policy version/status, and provenance source identity. The initial role/media allowlist is `runner-log`/`text/plain`, `screenshot`/`image/png`, and `sanitized-json`/`application/json`.

`CaseResultSet` binds the manifest with two separate digest authorities:

- `evidence_manifest_sha256` is the canonical-content digest and equals `EvidenceManifest.canonical_sha256`.
- `evidence_manifest_artifact_sha256` is SHA-256 of the exact persisted `evidence-manifest.json` bytes, including the serialized `canonical_sha256` field and any writer-owned trailing newline.
- Optional `evidence_manifest_ref.sha256`, when populated, is also the persisted-byte digest and must equal `evidence_manifest_artifact_sha256`.

The canonical digest is computed over deterministic canonical JSON with `canonical_sha256` excluded, avoiding self-reference. Object keys are sorted and arrays retain order. The persisted-byte digest is computed only after serialization and persistence. These values normally differ and must never be compared as though they hash the same bytes.

Publication first verifies the loaded artifact against `evidence_manifest_artifact_sha256`, then independently validates canonical content against `evidence_manifest_sha256` and `manifest.canonical_sha256`. Structured CLI/HTTP production and canonical publication require the persisted digest. The shared ResultSet schema permits its absence during the expand phase for existing browser producers that do not yet emit the new binding.

Validation requires every nested evidence reference to use `kind = "evidence"` and resolve to exactly one manifest entry; entries must belong to a result-set case/assertion and the same repository, run, and plan. Duplicate IDs, foreign identities, cross-root or cross-run pointers, unsupported role/media, and either digest-domain mismatch fail closed.

The manifest never embeds evidence bytes. Artifact pointers must be relative, run-scoped `artifact` references under the authorized `.testing/runs/<run_id>/` root. Absolute paths, traversal, raw DOM, cookies, headers, credentials, environments, and argv are outside this public contract.

## Portable schema validation

The portable [JSON Schema](../schemas/testing-evidence-manifest.v1.schema.json) uses JSON Schema Draft 2020-12. It closes every manifest, repository, reference, entry, and provenance object; requires every production field except optional `assertion_id`; and enforces the 1-to-256 entry bound, JSON-equal entry uniqueness, bounded non-control strings, lowercase SHA-256 syntax, RFC 3339 UTC timestamps with calendar validation, integer byte sizes from 0 through 1,000,000,000, and the closed role, media type, sensitivity, and policy-status enums. The schema also binds the three supported role/media pairs and requires evidence artifact references to use `kind = "artifact"` with a relative, non-drive, non-traversing lexical form.

Draft 2020-12 `maxLength` counts Unicode code points, while the Lua authority bounds UTF-8 bytes. Each bounded string definition therefore carries the machine-readable extension `x-fkst-maxUtf8Bytes`; consumers must enforce that keyword in addition to standard `maxLength`. The repository Python validator registers the extension, and shared multibyte fixtures prove parity with Lua rather than silently treating character and byte limits as equivalent.

Lua remains authoritative for checks that need context or comparison beyond one portable JSON instance: canonical digest recomputation, persisted-byte digest verification, duplicate `evidence_id` detection beyond whole-entry JSON equality, result-set case/assertion foreign keys, run/root containment, repository/run/plan identity, artifact provenance equality, and caller-supplied expected bindings. Schema validation alone does not establish any of those contextual identities or digest authorities.
