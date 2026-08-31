# `testing-runner-invocation.v1`

`testing-runner-invocation.v1` is the portable, canonical request envelope for one testing-runner invocation. The authoritative portable grammar is `schemas/testing-runner-invocation.v1.schema.json`, a closed JSON Schema Draft 2020-12 object. All 16 root properties are required. Unknown properties are rejected at every object level.

This contract validates structure, lexical bounds, and the canonical request digest. It does not grant execution authority or prove that referenced content, mappings, claims, policy, clocks, or effects are valid.

## Schema bundle

The root schema has resource ID `https://chronoaiproject.github.io/fkst-packages-testing/schemas/testing-runner-invocation.v1.schema.json`. It uses local relative `$ref` values into `./testing-package-executor.request.v1.schema.json`. An offline consumer must register both schema resources by their declared `$id` values before validating or preflighting references. Missing resources and unresolved fragments are fatal bundle errors; consumers must not fetch them from the network.

The invocation schema reuses these definitions verbatim:

| Definition | Exact `$ref` | Use |
| --- | --- | --- |
| Identity string | `./testing-package-executor.request.v1.schema.json#/$defs/identityString` | Root identities, executor identities, resolved executor ID, capability items, and producer name |
| Semantic version | `./testing-package-executor.request.v1.schema.json#/$defs/semanticVersion` | Executor, resolved executor, and producer versions |
| SHA-256 digest | `./testing-package-executor.request.v1.schema.json#/$defs/sha256` | Executor digests, reference digests, capability digest, and canonical request digest |
| Immutable reference | `./testing-package-executor.request.v1.schema.json#/$defs/reference` | Each approved input reference |
| Executor identity | `./testing-package-executor.request.v1.schema.json#/$defs/executorIdentity` | `executor`, further constrained to `testing-runner.v1` |

## Root object

Every row is required. The object is closed with `additionalProperties: false`.

| Field | Type | Exact rule |
| --- | --- | --- |
| `schema` | string | Constant `testing-runner-invocation.v1` |
| `canonicalization` | string | Constant `fkst-testing-runner-invocation-canonical-json.v1` |
| `invocation_id` | identity string | Invocation identity |
| `qa_run_ref` | identity string | QA run identity, not an immutable-reference object |
| `attempt_ref` | identity string | Attempt identity, not `attempt_id` |
| `executor` | object | Closed executor identity described below |
| `resolved_executor` | object | Closed resolved executor described below |
| `execution_profile` | identity string | Requested execution profile identity |
| `approved_input_refs` | object | Exactly nine closed immutable references |
| `requested_capabilities` | array | Ordered, unique, 1–64 identity strings |
| `budgets` | object | Closed step and elapsed-time limits |
| `deadline_epoch_seconds` | integer | Inclusive range 1–9007199254740991, in Unix epoch seconds |
| `producer` | object | Closed producer identity |
| `trace_id` | identity string | Trace correlation identity |
| `dedup_key` | identity string | Runtime deduplication key; this contract does not persist or resolve it |
| `canonical_request_sha256` | digest string | Canonical digest defined below |

Input JSON object member order is not significant. Canonical serialization sorts object keys. Array order is significant.

## Executor objects

`executor` is the reused closed `testing-package-executor.identity.v1` object with all fields required:

| Field | Type | Exact rule |
| --- | --- | --- |
| `schema` | string | Constant `testing-package-executor.identity.v1` |
| `package_id` | identity string | Package identity |
| `package_version` | semantic version | Numeric `X.Y.Z` only |
| `package_content_sha256` | digest string | Lowercase SHA-256 |
| `manifest_digest` | digest string | Lowercase SHA-256 |
| `entrypoint` | identity string | Package-declared entrypoint identity |
| `contract_major` | identity string | Constant `testing-runner.v1` in this envelope |

`resolved_executor` is closed and requires:

| Field | Type | Exact rule |
| --- | --- | --- |
| `executor_id` | identity string | Resolved executor identity |
| `version` | semantic version | Numeric `X.Y.Z` only |
| `capability_digest` | digest string | Lowercase SHA-256 |

The presence of `resolved_executor` is structural input only. This contract does not establish that a Runtime mapping exists or that the selected executor is authorized.

## Approved input references

`approved_input_refs` is closed and requires exactly the following nine properties:

| Property | Required `kind` |
| --- | --- |
| `source_ref` | `testing-package-source` |
| `pql_input_set_ref` | `testing-package-pql-input` |
| `approved_test_case_set_ref` | `testing-approved-test-case-set` |
| `structured_plan_ref` | `testing-structured-plan` |
| `package_release_ref` | `testing-package-release` |
| `package_manifest_ref` | `testing-package-manifest` |
| `schema_catalog_ref` | `testing-schema-catalog` |
| `capability_port_set_ref` | `testing-package-capability-set` |
| `policy_ref` | `testing-package-policy` |

Each property is a closed reused `reference` object. All three fields are required:

| Field | Type | Exact rule |
| --- | --- | --- |
| `kind` | identity string | Must equal the property-specific literal above |
| `ref` | immutable reference string | 1–4096 UTF-8 bytes, begins `immutable://`, contains no query `?`, fragment `#`, U+0000–U+001F, or U+007F |
| `sha256` | digest string | Exactly 64 lowercase hexadecimal characters |

The `ref` is a pointer only. Portable or Lua validation does not load it, hash persisted bytes, validate the target document, or compare identities across referenced documents.

## Lexical types

| Type | Exact rule |
| --- | --- |
| Identity string | JSON string, non-empty, at most 180 Unicode characters and at most 180 UTF-8 bytes, with no U+0000–U+001F or U+007F |
| Semantic version | Identity-string bounds plus exact regular language `[0-9]+\.[0-9]+\.[0-9]+`; prefixes, prereleases, labels, and omitted components are rejected |
| Digest string | Exactly 64 characters from `[0-9a-f]`; uppercase hexadecimal is rejected |
| Immutable reference string | JSON string, non-empty, at most 4096 Unicode characters and at most 4096 UTF-8 bytes, matching `immutable://[^?#]*`, with no U+0000–U+001F or U+007F |

The UTF-8 byte limit is normative in addition to JSON Schema `maxLength`. A multibyte value can satisfy the character count and still be invalid because its encoded byte length exceeds the limit. Non-string values are invalid for every lexical type.

## Capabilities, budgets, and deadline

`requested_capabilities` is an ordered JSON array. It contains 1–64 unique identity strings. The order is part of the invocation identity and therefore changes `canonical_request_sha256`. Consumers must not sort or deduplicate the array.

Lua callers must represent `requested_capabilities` as a dense array with integer keys `1..N`. String keys, key `0`, negative keys, fractional keys, and gaps are malformed even when `ipairs` would expose a prefix.

`budgets` is closed and requires both fields:

| Field | Type | Inclusive range | Unit |
| --- | --- | --- | --- |
| `step_budget` | integer | 1–8 | runner steps |
| `time_budget_seconds` | integer | 1–600 | seconds |

`deadline_epoch_seconds` is an integer in the inclusive range 1–9007199254740991 and is expressed in Unix epoch seconds. Portable and Lua validation enforce only the numeric range; comparison with the current clock is Runtime-owned.

`producer` is closed and requires `name` as an identity string and `version` as a semantic version.

## Canonical JSON and digest

The canonicalization profile is `fkst-testing-runner-invocation-canonical-json.v1`:

1. Copy the complete invocation and omit only the root `canonical_request_sha256` member.
2. Encode JSON objects with keys sorted lexicographically by their valid UTF-8 strings.
3. Preserve array order exactly.
4. Emit no insignificant whitespace and no trailing newline.
5. Encode `null`, booleans, and integers with their JSON tokens. Integers must be in the inclusive safe range -9007199254740991 through 9007199254740991; negative zero is emitted as `0`.
6. Encode strings as UTF-8. Escape quotation mark and reverse solidus. Use `\b`, `\t`, `\n`, `\f`, and `\r` for those controls and lowercase `\u00xx` escapes for other bytes below U+0020. Reject invalid UTF-8.
7. Compute SHA-256 over those exact canonical UTF-8 bytes and encode the result as 64 lowercase hexadecimal characters.

The digest is not a digest of the pretty-printed fixture file or of referenced artifacts. Validation must not mutate the supplied object. A structurally and lexically valid request with a different recomputed digest fails specifically as `digest-mismatch` in Lua.

## Closed compatibility policy

There are no aliases. In particular, reject `attempt_id`, `plan_ref`, `pql_input_ref`, `schema_set_ref`, and `capability_set_ref`. The decode-only schema name `ai-testing-session-input.v1` is not accepted by this canonical validator. Do not infer renamed properties, upgrade unsupported versions, normalize semantic versions, lowercase digests, reorder capabilities, or accept caller-defined root entrypoints.

Closed objects also forbid authority and execution material, including Talos lease, worker, generation, or fence tokens; NyxID, credentials, bearer tokens, or secrets; pool or machine selection; host absolute paths; shell, argv, environment dumps, or executable paths; plugins or dynamic imports; CDP endpoints or Chrome profiles; cookies, headers, or browser storage; prompts, model fields, or ModelInference configuration; caller-selected free-form entrypoints; and inline artifact bodies.

## Authority ownership

| Decision or check | Portable schema | Lua validator | Runtime |
| --- | --- | --- | --- |
| Closed shape, required fields, constants, lexical bounds, arrays, and numeric ranges | Authoritative | Mirrors and classifies | May rely on validated input |
| Canonical JSON recomputation and `canonical_request_sha256` equality | Not recomputed | Authoritative | May rely on validated input |
| Dense Lua table representation | Not applicable | Authoritative | Not applicable |
| Immutable loading and persisted-byte digest verification | No | No | Authoritative |
| Package, manifest, schema, policy, capability, and executor mapping resolution | No | No | Authoritative |
| Claims, freshness, deadlines against a clock, cancellation, deduplication, effects, receipts, and replay | No | No | Authoritative |

The shared Runtime-only fixtures are deliberately portable-valid and Lua-valid. Their `runtime_reason` values are classification metadata, not evidence that Runtime executed or observed the outcome. The closed reason set is:

- `mapping-ambiguous`
- `mapping-missing`
- `unsupported-execution-profile`
- `unsupported-mapping`
- `capability-mismatch`
- `policy-mismatch`
- `lineage-mismatch`
- `lineage-rebuilt`
- `lineage-substituted`
- `stale-plan`
- `deadline-expired`
- `cancelled`
- `current-claim-unavailable`
- `current-claim-superseded`
- `replay-conflict`

## Normative fixtures

The reusable conformance corpus is indexed by `packages/testing-runner/tests/fixtures/testing-runner-invocation.v1/index.json`. Index order is deterministic, every entry is exactly `{name, file}`, every fixture wrapper is exactly `{case, portable_valid, lua_valid, lua_error, request}`, and inventory is closed. `packages/testing-runner/tests/fixtures/testing-runner-invocation.v1/runtime-outcomes.json` is the closed Runtime-only classification sidecar.

The normative valid envelope is `packages/testing-runner/tests/fixtures/testing-runner-invocation.v1/valid-canonical-envelope.json`. Its `canonical_request_sha256` is exactly `e307a583193b235addb17935725e3c52fa125860b4f3fa340431b6e6d43e9066`.
