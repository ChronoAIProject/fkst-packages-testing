# Successor release tooling acceptance evidence

## Assurance method

This record follows requirements-traceability and configuration-controlled verification practice.
Each acceptance claim is bound to an implementation symbol, a named test, an exact tested revision,
an execution result, and a durable evidence URL. Verdicts are `supported`, `gap`, or `unverified`;
aggregate suite success is not substituted for a missing named test. Normative behavior remains in the
contracts, schemas, verifier, generator, and tests. This document is descriptive evidence only.

The supplied local issue bundle contains the complete `#818` history and its approved amendment
summary, but not the original bodies and comments for `#800`, `#806`, `#808`, `#810`, or `#812`.
Accordingly, this record completes the execution evidence for every locally identified amended
criterion, but it does not claim verbatim-source or criterion-set completeness for `#800` or `#806`.
That residual limitation is reported explicitly rather than inferred away from a green suite.

## Evaluation identity and product-tree equivalence

- Evaluated product base: `bdf7055156759ff4f066fd82ab830aad6353c25f`, the merge commit for pull
  request `#814`, with parents `9ff11f1073d8ff19ada511d74169229a153513a0` and
  `1334a5066e1d20db749402f13e86696376f5db88`.
- Tested pull-request head: `6242eb8c7faa63d652d3ac6cefc7ba7a8b2f4df0`.
- Actual Hosted checkout: synthetic merge `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`, with parents
  `bdf7055156759ff4f066fd82ab830aad6353c25f` and
  `6242eb8c7faa63d652d3ac6cefc7ba7a8b2f4df0`, as recorded in the [CI job].
- Later `dev` revision: merge commit `1039fb60761716fa955ceac5349ac446e225796f`, with the same two parents as
  the tested synthetic merge. It is not the checkout named by the job log.
- `git merge-base --is-ancestor` succeeds from the product base to the tested head, from
  `efbd80c70543dd2237da1307e5be41735de948a1` to the product base, and from the tested head to later
  `dev`. The pull request `#811` API identity supplied to `#818` names
  `efbd80c70543dd2237da1307e5be41735de948a1` as both `headRefOid` and `mergeCommit`; no distinct merge
  node is required for that accepted head.
- `git diff --name-only bdf7055156759ff4f066fd82ab830aad6353c25f..6242eb8c7faa63d652d3ac6cefc7ba7a8b2f4df0`
  lists only `docs/verification/successor-release-tooling.md`; the same fact is recorded by the
  [base-to-head comparison]. `git merge-tree --write-tree` for those revisions produces tree
  `5b3b70e2f794302cfa6189a105c8a0757969bd06`, equal to the tree of both the tested head and later
  `dev`. All product, contract, schema, artifact, and test paths are therefore byte-identical between
  the evaluated product base and the revision-bound CI checkout; only this evidence document differs.

## Amended ownership and semantics

The Runtime-only dispatch amendment supersedes any interpretation that publisher successor
coordinates select local executable code:

- Runtime selects and resolves local execution after release verification.
- Successor `executor` and `mappings` coordinates are opaque, bounded, signed publisher metadata.
- The signed release binds the signed tool catalog; the verified catalog maps
  `browser.read-title.v1` to Runtime port `browser_read_title`, but does not authorize a
  publisher-selected module load.
- Legacy releases retain strict `testing_package_executor.executor.execute` coordinates.
- The signed catalog port and the repository-owned local adapter have different authority roles: the
  catalog declares the verified capability-to-port binding, while Runtime supplies and invokes the
  local executable path.

This boundary is implemented by `verifyReleaseShape` validating bounded successor metadata,
`verifyToolCatalog` binding the catalog, and `executionTest` plus `executeVerified` using
repository-owned `RUNTIME_PATHS`. The release contract states that the release layer does not own
Runtime fetch, capability routing, effect delivery, or result publication.

## Revision-bound execution evidence

The pull-request event for head `6242eb8c7faa63d652d3ac6cefc7ba7a8b2f4df0` completed successfully in
[CI run `34183597265`] and [CI job `101927476554`] on September 8, 2026 UTC:

- `03:28:48`: engine provenance passed with expected and observed
  `1e21b9b57fcfe0b09521c16d77c85e693e755718`.
- `03:36:03`: the `testing-runner` package suite completed with `347 passed, 0 failed`.
- `03:36:39`: hermetic conformance completed `52` contract cases across `14` package packs.
- `03:37:45`: `testing-package-release: PASS`; this executes
  `python3 scripts/testing_package_release_test.py`, whose `main` invokes the named Python tests in
  the matrix. `testing-schema-publication: PASS` also completed `17` schemas and `351` cases.
- `03:38:09`: the final Lua coverage ratchet completed `OK: 14 package(s)`. Earlier pre-test
  coverage-deferred warnings were setup-stage warnings, not the final result.
- `03:55:36`: Generic Host completed `58 passed, 0 failed`.
- `03:55:40`: AI smoke completed `2 passed, 0 failed`; runner smoke completed `1 passed, 0 failed`;
  repository checks/tests succeeded. The job concluded successfully at `03:55:45`.

The earlier worker-local attempts remain historical limitations, not contrary execution evidence:
`python3 scripts/testing_package_release_test.py` could not import `jsonschema`, and local
`scripts/run.sh test testing-runner` plus `scripts/run.sh test-affected` rejected engine provenance
`723f5433814975d5c02723e7c5874190c7b8ed73` and could not rebuild because `cargo` was absent. The
provenance-matched Hosted job subsequently executed the relevant suites successfully.

## Requirement-to-evidence matrix

Every `supported` row below cites the same revision-bound [CI job] and a named test executed by a
reported passing suite. “Source issue” reflects the amended requirement mapping available in the
local `#818` record; the absent original issue text remains the separate completeness limitation in
the conclusions.

| Amended requirement / source issue | Implementation path and symbol | Named test | Revision-bound execution and URL | Verdict |
| --- | --- | --- | --- | --- |
| Expected release digest authenticates before authorization, DSSE, dependent reads, extraction, loading, or effects (`#800`, `#806`, `#808`) | `scripts/verify_testing_package_release.mjs`: `verifyTestingPackageRelease`, `digestMatches`, `stage`; `contracts/testing-package-release-admission.v1.md`: `Admission ordering` | `scripts/testing_package_release_test.py`: `assert_expected_release_first_gate`, `assert_rejection_matrix`, `SUCCESS_STAGES` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; `testing-package-release: PASS` in [CI job] | `supported` |
| Wrong expected digest and substituted authorization or DSSE causally poison before effects (`#800`, `#806`, `#808`) | `scripts/verify_testing_package_release.mjs`: `verifyTestingPackageRelease`, `digestMatches`, `decodeBase64`, `pae` | `scripts/testing_package_release_test.py`: `assert_expected_release_first_gate`, `signed_case`, `assert_rejection_matrix` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; `testing-package-release: PASS` in [CI job] | `supported` |
| Authority, validity window, revocation, and release-sequence floor are enforced (`#800`, `#806`, `#810`) | `scripts/verify_testing_package_release.mjs`: `verifyReleaseShape`, `timestamp`, `keyid`, `verifyTestingPackageRelease`; `schemas-next-release/testing-package-release.v1.schema.json`: `properties.authority`; `libraries/contract/testing_package_release.lua`: `timestamp`, `M.validate` | `scripts/testing_package_release_test.py`: `assert_successor_walking_skeleton`; `packages/testing-runner/tests/testing_package_release_test.lua`: `test_successor_rejects_incomplete_or_malformed_policy` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; Python release test passed and `testing-runner` reported `347 passed, 0 failed` in [CI job] | `supported` |
| UTF-8 byte bounds, scalar and control rejection, safe sequence integers, and real UTC dates agree across JavaScript, schema, and Lua (`#800`, `#806`, `#810`, `#812`) | `scripts/verify_testing_package_release.mjs`: `metadataString`, `keyid`, `timestamp`; `schemas-next-release/testing-package-release.v1.schema.json`: `$defs.metadata`, `$defs.timestamp`, `properties.authority.properties.release_sequence`; `schemas-next-release/testing-package-tool-catalog.v1.schema.json`: `properties.tools.items.properties.port`; `libraries/contract/testing_package_release.lua`: `bounded_string`, `timestamp`, `M.validate` | `scripts/testing_package_release_test.py`: `assert_successor_walking_skeleton`; `packages/testing-runner/tests/testing_package_release_test.lua`: `test_successor_rejects_malformed_publisher_metadata`, `test_successor_rejects_incomplete_or_malformed_policy` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; Python release test and `testing-runner` package suite passed in [CI job]; repair `1334a5066e1d20db749402f13e86696376f5db88` is an ancestor | `supported` |
| Tool catalog path, bytes, binding, profile, capability, and Runtime port are exact (`#800`, `#806`, `#810`) | `scripts/verify_testing_package_release.mjs`: `TOOL_CATALOG_PATH`, `verifyToolCatalog`, `verifyTestingPackageRelease`; `schemas-next-release/testing-package-tool-catalog.v1.schema.json`; `scripts/generate_testing_package_release.py`: `tool_catalog`, `release_value` | `scripts/testing_package_release_test.py`: `assert_successor_walking_skeleton` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; `testing-package-release: PASS` in [CI job] | `supported` |
| Successor coordinates are opaque signed metadata while legacy coordinates remain strict (`#800`, `#806`, superseded dispatch amendment in `#810`) | `scripts/verify_testing_package_release.mjs`: `verifyReleaseShape`; `schemas-next-release/testing-package-release.v1.schema.json`: legacy and successor `allOf` conditions; `libraries/contract/testing_package_release.lua`: `bounded_string`, `M.validate` | `scripts/testing_package_release_test.py`: `assert_successor_walking_skeleton`; `packages/testing-runner/tests/testing_package_release_test.lua`: `test_successor_accepts_bounded_publisher_metadata`, `test_legacy_rejects_publisher_coordinate_substitution` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; Python release test and `testing-runner` package suite passed in [CI job] | `supported` |
| Only Runtime resolves executable code; publisher-named modules are not loaded (`#806`, `#810`) | `scripts/verify_testing_package_release.mjs`: `RUNTIME_PATHS`, `executionTest`, `executeVerified`; `contracts/testing-package-release.v1.md`: “The release layer does not own Runtime fetch” paragraph | `scripts/testing_package_release_test.py`: `assert_successor_walking_skeleton` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; the walking skeleton and runner smoke passed in [CI job] | `supported` |
| The full locally identified rejection matrix prevents effects before each applicable gate (`#800`, `#806`, `#808`, `#810`) | `scripts/verify_testing_package_release.mjs`: `closed`, `requireCanonical`, `fileBinding`, `verifyReleaseShape`, `verifyManifest`, `verifyToolCatalog`, `verifyBundle`, `executeVerified`, `verifyTestingPackageRelease`; `scripts/generate_testing_package_release.py`: `unsigned_outputs`, `main` | `scripts/testing_package_release_test.py`: `assert_rejection_matrix`, `assert_generator_rejections`, `assert_expected_release_first_gate`, `assert_successor_walking_skeleton` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; `testing-package-release: PASS` in [CI job] | `supported` |
| A passing executor and complete `ResultAuthority` receipt validation precede success (`#800`, `#806`) | `scripts/verify_testing_package_release.mjs`: `executionTest`, `executeVerified`; `libraries/contract/testing_result_authority.lua`: `M.create_receipt`, `M.validate_receipt`, `M.canonicalize` | `scripts/testing_package_release_test.py`: `assert_successor_walking_skeleton`, `SUCCESS_STAGES`; `packages/testing-runner/tests/testing_result_authority_contract_test.lua`: `test_identity_is_symbolic_versioned_and_digest_bound`, `test_receipt_replays_byte_identically_and_rejects_substitution`, `test_semantically_false_digest_consistent_result_is_rejected`, `test_rejects_malformed_identity_receipt_and_write_shapes`, `test_rejects_artifact_semantic_and_completion_mismatches` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; Python release test and `testing-runner` package suite passed in [CI job] | `supported` |
| Signed release, authorization, bundle, manifest, schema publication, and successor catalog artifacts are immutable and bound (`#800`, `#806`) | `package-release/testing-package-release.v1.json`; `package-release/testing-package-release.v1.dsse.json`; `package-release/testing-package-release.v1.key.json`; `package-release/testing-package-bundle.v1.json`; `package-release/testing-package-manifest.v1.json`; `schema-release/testing-package-schema-release.v1.json`; `schema-release/testing-package-schema-release.v1.dsse.json`; `schema-release/testing-package-schema-release.v1.key.json`; `scripts/generate_testing_package_release.py`: `TOOL_CATALOG_PATH`, `tool_catalog`, `unsigned_outputs`; `scripts/verify_testing_package_release.mjs`: `fileBinding`, `verifyManifest`, `verifyToolCatalog`, `verifyBundle`, `verifyTestingPackageRelease` | `scripts/testing_package_release_test.py`: `main`, `assert_rejection_matrix`, `assert_successor_walking_skeleton` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; `testing-package-release: PASS` and `testing-schema-publication: PASS` in [CI job] | `supported` |
| Repository and dependency inputs use exact real commit pins (`#800`, `#806`) | `scripts/generate_testing_package_release.py`: `repository_commit`, `pinned_commit`, `source_file`, `unsigned_outputs`; `.fkst/conformance/fkst-packages.pin`; `.fkst/substrate-ref`; `package-release/testing-package-release.v1.source-commit` | `scripts/testing_package_release_test.py`: `assert_bundle_uses_pinned_git_tree`, `assert_rejection_matrix`, `assert_generator_rejections` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; engine provenance matched `1e21b9b57fcfe0b09521c16d77c85e693e755718` and the release test passed in [CI job] | `supported` |
| Generation is deterministic, complete, contained, and free of ambient source fallback (`#800`, `#806`, `#810`) | `scripts/generate_testing_package_release.py`: `canonical_timestamp`, `exact_commit`, `repository_commit`, `pinned_commit`, `source_file`, `signing_seed`, `signed_artifacts`, `unsigned_outputs`, `main` | `scripts/testing_package_release_test.py`: `assert_generator_rejections`, `assert_successor_walking_skeleton`, `main` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; `testing-package-release: PASS` in [CI job] | `supported` |
| Lua malformed publisher-metadata regression is repaired (`#812`, merged by `#814`) | `libraries/contract/testing_package_release.lua`: `bounded_string`, `M.validate` | `packages/testing-runner/tests/testing_package_release_test.lua`: `test_successor_rejects_malformed_publisher_metadata` | Synthetic checkout `7d9757b7cb76344bc8d0486ec51c6f53740b5f60`; `testing-runner` reported `347 passed, 0 failed` and the final Lua coverage ratchet passed in [CI job] | `supported` |
| The rows above exhaust the verbatim original and amended acceptance criteria of `#800` and `#806` | Original `#800` and `#806` issue bodies and accepted amendment comments | A source-completeness review against those original records | The supplied local bundle does not contain those records, and this delivery is prohibited from fetching GitHub content independently | `unverified` |

No locally evidenced row is classified `gap`. The only `unverified` row is source-completeness: the
available evidence proves execution of the mapped behaviors but cannot prove that unavailable
original issue text contains no additional criterion.

## Conclusions

### Issue `#806`

Status: `supported` for every locally identified amended tooling criterion: authentication-first
ordering, causal poison proofs, authority policy, metadata bounds, exact catalog binding,
Runtime-only code resolution, legacy compatibility, pre-effect rejection, executor success, receipt
validation, immutable artifact binding, exact provenance pins, and deterministic contained
generation. No product `gap` is evidenced. Exhaustive criterion-set completeness is `unverified`
because the original `#806` body and amendment comments are absent from the supplied local record.

Closeout recommendation: do not use aggregate CI alone and do not claim unconditional closure from
this document. A maintainer with access to the original `#806` record may close it if a verbatim
criterion audit finds no requirement beyond the supported rows. Any omitted criterion must be added
as `supported`, `gap`, or `unverified` before closure.

### Issue `#800`

Status: `supported` for every locally identified amended tooling criterion: deterministic generation,
real immutable source pins, signed release and authorization output, bound bundle, manifest, schema
publication, and tool catalog, strict verifier rejection ordering, temporary successor execution,
and complete receipt validation. No product `gap` is evidenced. Exhaustive criterion-set completeness
is `unverified` because the original `#800` body and amendment comments are absent from the supplied
local record.

Closeout recommendation: a maintainer may close `#800` only after comparing its verbatim original and
amended criteria with this matrix and confirming that no criterion is omitted. The successful Hosted
job removes the former execution-evidence blocker; it does not remove the source-completeness blocker.

## Production-signing boundary

Deterministic seeds and temporary Ed25519 test keys demonstrate reproducible test tooling only. They
do not prove or authorize production signing, authorization publication, key custody, rotation,
revocation publication, or release publication under `#745` or `#789`. This acceptance record also
does not implement or recover `#796`, alter Runtime dispatch ownership, or authorize a production
release.

[CI run `34183597265`]: https://github.com/ChronoAIProject/fkst-packages-testing/actions/runs/34183597265
[CI job `101927476554`]: https://github.com/ChronoAIProject/fkst-packages-testing/actions/runs/34183597265/job/101927476554
[CI job]: https://github.com/ChronoAIProject/fkst-packages-testing/actions/runs/34183597265/job/101927476554
[base-to-head comparison]: https://github.com/ChronoAIProject/fkst-packages-testing/compare/bdf7055156759ff4f066fd82ab830aad6353c25f...6242eb8c7faa63d652d3ac6cefc7ba7a8b2f4df0
