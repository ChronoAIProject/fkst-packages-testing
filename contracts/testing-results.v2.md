# Testing Results v2

The canonical execution result slice has four Draft 2020-12 documents:

- `testing-observation.v1`
- `testing-assertion-result.v1`
- `testing-case-result.v2`
- `testing-case-result-set.v2`

The JSON Schemas under `schemas/` are closed-world documents and expose the
`fkst-testing-results-canonical-json.v1` profile through `x-fkst-canonicalization`.
Strings carry `x-fkst-maxUtf8Bytes` plus the matching enforced `fkst-utf8-max-*`
format in addition to their character bound. Digests
are lowercase, exact 64-character SHA-256 values. References are bounded
pointer records and evidence references are bounded to 64 entries. Timestamps
are UTC second-resolution values in the strict `YYYY-MM-DDTHH:MM:SSZ` form;
year zero is accepted for parity with the Lua calendar checker, while
impossible calendar dates are rejected.

Assertion results use the status/classification truth table: `passed` is
`deterministic`, `failed` is `assertion_failure`, and `skipped` is either
`skipped` or `not_applicable`. Case results cover the complete execution
matrix (`passed`, `failed`, `skipped`, `error`, `blocked`, and `lost`) with
their corresponding classifications, assertion status limits, required
assertion contains rules, and `error`/`non_execution_reason` conditionals.

The result-set schema references the case schema and the published
`testing-evidence-manifest.v1` reference definition without embedding or
changing the manifest schema. A persisted manifest digest is required when
the result-set manifest reference carries a digest.

The following invariants remain Lua-only because they require context or
cross-record comparison:

- timestamp ordering (`completed_at >= started_at`),
- duplicate observation, assertion, evidence, and case IDs,
- observation/assertion/case foreign-key resolution,
- exact plan assertion count, order, identity, and requiredness,
- set/case plan, trace, and dedup equality,
- EvidenceManifest binding, evidence-reference resolution, and provenance,
- canonical digest recomputation and persisted-artifact digest equality.

`libraries/contract/testing_results.lua` remains the execution authority. The
schemas describe the portable structural slice only and do not change wire
behavior or add invocation/executor/browser-action contracts. Raw serialized payload-byte ceilings,
including whitespace overhead, belong to the transport or artifact loader; the Lua authority defines
bounded semantic fields and collections but no separate whole-document byte constant.
