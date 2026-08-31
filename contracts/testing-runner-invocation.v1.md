# `testing-runner-invocation.v1`

This contract is the portable request envelope for one canonical testing-runner invocation. It is a closed Draft 2020-12 object; every property is required and all reusable lexical definitions come from `testing-package-executor.request.v1.schema.json` through local relative `$ref` values.

## Wire grammar

The root fields, in order, are `schema` (`testing-runner-invocation.v1`), `canonicalization` (`fkst-testing-runner-invocation-canonical-json.v1`), `invocation_id`, `qa_run_ref`, `attempt_ref`, `executor`, `resolved_executor`, `execution_profile`, `approved_input_refs`, `requested_capabilities`, `budgets`, `deadline_epoch_seconds`, `producer`, `trace_id`, `dedup_key`, and `canonical_request_sha256`.

`executor` is the closed `testing-package-executor.identity.v1` shape with `contract_major` equal to `testing-runner.v1`. `resolved_executor` contains `executor_id`, semantic `version`, and `capability_digest`. `approved_input_refs` contains the nine closed immutable references `source_ref`, `pql_input_set_ref`, `approved_test_case_set_ref`, `structured_plan_ref`, `package_release_ref`, `package_manifest_ref`, `schema_catalog_ref`, `capability_port_set_ref`, and `policy_ref`; each has its exact contract-specific `kind`. `requested_capabilities` is an ordered, unique array of one to 64 identity strings. `budgets` contains `step_budget` from 1 through 8 and `time_budget_seconds` from 1 through 600. `deadline_epoch_seconds` is an integer from 1 through 9007199254740991. `producer` contains `name` and semantic `version`.

## Canonical digest

Use `contract.canonical_json`: recursively sort object keys lexicographically, preserve array order, emit compact JSON without a trailing newline, validate Unicode scalar UTF-8 strings, and allow only safe-range integers. `canonical_request_sha256` is lowercase SHA-256 over the complete request object with only `canonical_request_sha256` omitted. It is not a digest of fixture bytes, and changing capability array order changes the digest. Validation never mutates the request.

## Authority boundary

This slice performs offline schema validation and Lua canonical-request digest verification only. It does not load immutable references or verify persisted bytes, resolve package releases/manifests/catalogs/policies/capabilities, select executors, consult clocks or leases, persist deduplication, execute effects, publish receipts, or provide replay authority. Those concerns remain Runtime-owned.
