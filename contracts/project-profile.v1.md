# Project Profile and execution approval v1

`contract.project_profile` defines repository-owned testing configuration separately from host-owned
execution approval. It follows complete mediation and fail-closed authorization: a structurally valid
profile and knowledge of its digest identify content, but neither grants permission to check out a
repository or run a command.

## Schemas

- Profile: `testing-project-profile.v1`
- Approval: `testing-project-profile-approval.v1`
- Sanitized validation receipt: `testing-project-profile-validation-receipt.v1`
- Canonicalization: `fkst-project-profile-canonical-json.v1`

The canonicalization procedure validates the selected schema, emits UTF-8 JSON with object keys sorted
by byte order, uses dense arrays in declared order, emits integers without alternate representations,
and uses minimal JSON string escaping. Empty or sparse arrays, unsupported fields, invalid UTF-8, and
non-integer numbers are not canonical. A host-supplied cryptographic implementation hashes the emitted
bytes with SHA-256; the generic contract does not implement or select a cryptographic provider.

## Project Profile

The profile has these exact top-level fields:

- `schema`: `testing-project-profile.v1`
- `revision`: bounded profile revision identifier
- `repository = { url, commit_sha }`: credential-free canonical HTTPS Git URL plus an immutable,
  lowercase 40-hex commit object ID; branches, tags, and shortened hashes are invalid
- `working_directory`: `.` or a safe repository-relative path without traversal, whitespace, or
  backslashes
- `commands`: direct dense argv lists for optional `install`, `build`, `migrate`, and `seed`, plus
  required `start` and `cleanup`; shell interpreters and command strings are invalid
- `dependent_services`: optional bounded dense list of `{ name, start_argv, cleanup_argv,
  readiness_checks }`
- `readiness_checks`: non-empty bounded dense list of typed `http`, `tcp`, or `argv` checks
- `allowed_origins`: non-empty bounded dense list of credential-free HTTP(S) origins; HTTP readiness
  checks must remain within this set
- `secret_refs`: optional bounded dense list of `{ name, type = "secret-reference", source_ref }`;
  resolved or literal values are not fields in this schema
- `mutation_policy`: either `{ mode = "read-only" }` or a fixture-scoped policy with bounded
  `allowed_operations` and `cleanup_required = true`
- `timeouts`: explicit bounded install/build/migrate/seed/start/readiness/cleanup/total limits and a
  `receipt_ttl_seconds` limit of at most 300 seconds
- `resource_budgets`: explicit bounded CPU, memory, disk, process, network-request, and output-byte
  budgets

Raw credential markers, credential-bearing URLs, unsupported fields, unsafe paths, sparse lists,
unbounded integers, shell command strings, mutable repository refs, and non-reference secret values
fail validation.

## Approval artifact

The approval is a separate host-controlled artifact with these exact fields:

- `schema`: `testing-project-profile-approval.v1`
- `approval_id`: bounded single-use approval identifier
- `canonicalization`: `fkst-project-profile-canonical-json.v1`
- `profile_sha256`: SHA-256 of the canonical profile bytes
- `repository = { url, commit_sha }`: exact profile repository and immutable commit scope
- `authority`: trusted authority or policy `source_ref`
- `policy_revision`: exact trusted policy revision
- `evidence_ref`: external signature, attestation, or policy-decision evidence pointer
- `issued_at`, `expires_at`: valid UTC timestamps with a validity window of at most 24 hours
- `max_uses`: exactly `1`
- `trace_id`, `dedup_key`: exact campaign scope

An approval `source_ref` is only an identifier. The host supplies `trusted_authorities`, keyed by exact
authority reference and policy revision, and each entry supplies a verifier. The verifier must
authenticate the canonical approval digest and return an attestation binding that digest, authority,
policy revision, and evidence reference. String matching, repository authorship, profile validity,
digest knowledge, and validation receipts are not authority evidence.

## Receipt and point-of-use mediation

`issue_validation_receipt(profile, approval, context)` returns a sanitized receipt only after strict
profile validation, digest recalculation, repository/commit binding, approval-window validation, and
trusted authority authentication. The receipt binds the profile schema/revision/digest, exact
repository and commit, approval artifact pointer and digest, approval ID, authority and evidence
references, policy revision, issue time, trace ID, and dedup key. It contains no commands, secret
references, or resolved values and is audit evidence, not an authorization capability.

`authorize_execution(profile, approval, receipt, context)` must run immediately before the first target
effect, including checkout. It repeats profile validation and canonical digest calculation, repeats
approval authentication, validates every receipt binding and freshness, and then calls a host-supplied
atomic replay guard. Missing approvals, unknown authorities, changed profiles, digest mismatches,
foreign repositories, different commits, stale artifacts, mis-scoped receipts, missing replay guards,
and previously claimed approvals fail before a target effect. The caller must execute the returned
validated profile snapshot immediately and must not execute the original mutable input table.

The replay guard is host state, not generic package state. Its claim must atomically enforce the
single-use tuple of approval ID/digest, profile digest, exact repository/commit, trace ID, and dedup key.
Authority identities, policy revisions, repository URLs, command values, timeouts, resource allocations,
and secret locations remain host-supplied; the generic package provides no product-specific defaults.

## Controlled fixture

The minimal fixture keeps configuration and authorization in separate files:

- `examples/generic-host/project-profile/project-profile.v1.json`
- `examples/generic-host/project-profile/project-profile-approval.v1.json`

The fixture uses non-production identities and direct commands. Its approval digest binds only the
checked-in profile fixture. A real host must replace the authority and evidence references, authenticate
the approval through its own trust root, supply a cryptographic SHA-256 implementation, and persist the
atomic replay claim outside FKST events, logs, receipts, and `.testing` control artifacts.
