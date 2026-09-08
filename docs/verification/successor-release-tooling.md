# Successor release tooling acceptance evidence

## Assurance method

This record follows requirements-traceability and configuration-controlled verification practice:
each claim is bound to one revision, mapped to implementation and named tests, and assigned an
explicit `verified`, `gap`, or `unverified` verdict. Inspection establishes that evidence exists; it
does not substitute for successful execution. Normative behavior remains in the contracts, schemas,
verifier, generator, and tests. This document is descriptive evidence only.

## Evaluation identity and limitations

- Evaluated `dev` revision: `bdf7055156759ff4f066fd82ab830aad6353c25f`.
- Evaluation time: `2026-09-08T02:49:02Z`.
- This later Markdown change is not the evaluated product revision and must not be represented as
  having been exercised by this evidence.
- Pull request `#814` merge commit is `bdf7055156759ff4f066fd82ab830aad6353c25f`, with parents
  `9ff11f1073d8ff19ada511d74169229a153513a0` and
  `1334a5066e1d20db749402f13e86696376f5db88`. `git merge-base --is-ancestor
  bdf7055156759ff4f066fd82ab830aad6353c25f bdf7055156759ff4f066fd82ab830aad6353c25f`
  returned success, so `#814` is reachable from the evaluated revision.
- The exact merge commit for pull request `#811` is unavailable in the supplied shallow/grafted
  history. Locally present topic commits are `c76beb5e1d8306aa518c6a437f03cded264d4435`,
  `56d09acebdd1d67ac9e0baeb80a402b961b02eff`, and
  `efbd80c70543dd2237da1307e5be41735de948a1`; the last is reachable from the evaluated revision.
  These topic commits are not substituted for the unavailable `#811` merge commit.
- The supplied bundle contains the full `#816` record but not the full bodies, amendments, merged-pull-
  request records, or Hosted CI records for `#800`, `#806`, `#808`, `#810`, and `#812`. The matrix
  uses the approved `#816` summary for traceability. Claims requiring unavailable original wording or
  Hosted evidence remain `unverified`.

## Amended ownership and semantics

The amended framing supersedes any requirement that publisher successor coordinates select local
code:

- Runtime selects and resolves local execution after release verification.
- Successor `executor` and `mappings` coordinates are opaque, bounded, signed publisher metadata.
- The verified tool catalog binds `browser.read-title.v1` to Runtime port `browser_read_title`; it does
  not authorize a publisher-selected module load.
- Legacy releases retain strict `testing_package_executor.executor.execute` coordinates.

This boundary is implemented by `verifyReleaseShape` accepting bounded successor metadata while
`executionTest` invokes the repository-owned executor, and by `M.validate` retaining exact legacy
values while accepting bounded successor strings.

## Execution evidence

All commands targeted `bdf7055156759ff4f066fd82ab830aad6353c25f`.

- `python3 scripts/testing_package_release_test.py` did not reach the tests because `jsonschema` is
  unavailable: `ModuleNotFoundError: No module named 'jsonschema'`.
- `scripts/run.sh test testing-runner` and the required final `scripts/run.sh test-affected` did not
  reach package tests. They rejected the available `fkst-framework` because observed provenance
  `723f5433814975d5c02723e7c5874190c7b8ed73` differed from required pin
  `1e21b9b57fcfe0b09521c16d77c85e693e755718`, then could not rebuild because `cargo` was absent.
- No Hosted CI/job URL was supplied. Green CI is therefore not used as proxy evidence.
- `git merge-base --is-ancestor <commit> bdf7055156759ff4f066fd82ab830aad6353c25f`
  succeeded for `#814`, `1334a5066e1d20db749402f13e86696376f5db88`, and
  `efbd80c70543dd2237da1307e5be41735de948a1`.
- `sha256sum package-release/testing-package-*.json
  package-release/testing-package-release.v1.source-commit` reproduced the committed digests,
  including release `fc34643f3837daa098e1d7be81c27b91d56a6d3be4d0d6f244fe20146f516b56`
  and authorization `16ec5e60a1d95d86f3594f245c49abf5c59ef471b4629ba16c095e507a4734ab`.

The unavailable engine is an environment verification failure, not evidence of a product defect.

## Requirement-to-evidence matrix

| Requirement / source issue | Implementation path and symbol | Test path and test name | Exact tested revision and command/result | Verdict |
| --- | --- | --- | --- | --- |
| Expected release digest authenticates before authorization, DSSE, dependent reads, extraction, loading, or effects (`#800`, `#806`, `#808`) | `scripts/verify_testing_package_release.mjs`: top-level sequence and `stage`; `contracts/testing-package-release.v1.md` | `scripts/testing_package_release_test.py`: `assert_expected_release_first_gate`, `assert_rejection_matrix`, `SUCCESS_STAGES` | `bdf7055156759ff4f066fd82ab830aad6353c25f`; direct test unavailable without `jsonschema`; package test unavailable without the required engine | `unverified` |
| Wrong expected digest and substituted authorization/DSSE causally poison before effects (`#800`, `#806`, `#808`) | `scripts/verify_testing_package_release.mjs`: release and authorization digest gates, key import, DSSE verification | `scripts/testing_package_release_test.py`: `assert_expected_release_first_gate`, `signed_case`, attacker-key substitution, invalid-signature stages | `bdf7055156759ff4f066fd82ab830aad6353c25f`; cases inspected; current-head execution unavailable | `unverified` |
| Authority, validity window, revocation, and release-sequence floor are enforced (`#800`, `#806`, `#810`) | `scripts/verify_testing_package_release.mjs`: `verifyReleaseShape`, `timestamp`, `keyid`, policy checks; successor schema `authority`; Lua `M.validate` | `scripts/testing_package_release_test.py`: `assert_successor_walking_skeleton` cases `not-yet-valid`, `expired`, `revoked`, `sequence-floor`, `authority-*`; Lua `test_successor_rejects_incomplete_or_malformed_policy` | `bdf7055156759ff4f066fd82ab830aad6353c25f`; source/cases inspected; Python and Lua execution unavailable | `unverified` |
| UTF-8 byte bounds, scalar/control rejection, safe sequence integers, and real UTC dates agree across JavaScript, schema, and Lua (`#800`, `#806`, `#810`, `#812`) | Verifier `metadataString`, `keyid`, `timestamp`; release schema `$defs.metadata` and `$defs.timestamp`; tool-catalog schema `tools[].port`; Lua `bounded_string`, `timestamp`, `M.validate` | Python `assert_successor_walking_skeleton` metadata/key/date/scalar cases; Lua `test_successor_rejects_malformed_publisher_metadata` and `test_successor_rejects_incomplete_or_malformed_policy` | `bdf7055156759ff4f066fd82ab830aad6353c25f`; `#814` and repair `1334a5066e1d20db749402f13e86696376f5db88` reachable; execution unavailable | `unverified` |
| Tool catalog path, bytes, binding, profile, capability, and Runtime port are exact (`#800`, `#806`, `#810`) | Verifier `verifyToolCatalog` and `TOOL_CATALOG_PATH`; `schemas-next-release/testing-package-tool-catalog.v1.schema.json`; generator `tool_catalog`, `release_value` | Python `assert_successor_walking_skeleton` positive catalog assertions and `tool-*` rejection cases | `bdf7055156759ff4f066fd82ab830aad6353c25f`; implementation/matrix inspected; execution unavailable | `unverified` |
| Successor coordinates are opaque signed metadata while legacy coordinates remain strict (`#800`, `#806`, superseded dispatch amendment in `#810`) | Verifier successor branch in `verifyReleaseShape`; release-schema legacy conditional; Lua successor/legacy branches in `M.validate` | Python successor-coordinate acceptance and legacy substitution rejection within `assert_successor_walking_skeleton`; Lua `test_successor_accepts_bounded_publisher_metadata`, `test_legacy_rejects_publisher_coordinate_substitution` | `bdf7055156759ff4f066fd82ab830aad6353c25f`; amendment originals and current-head execution unavailable | `unverified` |
| Only Runtime resolves executable code; publisher-named modules are not loaded (`#806`, `#810`) | Verifier `executionTest`, `executeVerified`; Runtime boundary in `contracts/testing-package-release.v1.md` | Python `assert_successor_walking_skeleton` publisher-coordinate substitution and rejection sentinels | `bdf7055156759ff4f066fd82ab830aad6353c25f`; source shows local resolution; execution unavailable | `unverified` |
| Full amended rejection matrix prevents effects before each applicable gate (`#800`, `#806`, `#808`, `#810`) | Verifier closed-profile, canonicalization, binding, provenance, policy, containment, and execution checks | Python `assert_rejection_matrix`, `assert_generator_rejections`, `assert_expected_release_first_gate`, `assert_successor_walking_skeleton` | `bdf7055156759ff4f066fd82ab830aad6353c25f`; matrix inspected; no current-head run or Hosted job available | `unverified` |
| Passing executor and complete `ResultAuthority` receipt validation precede success (`#800`, `#806`) | Verifier `executionTest` validates closed receipt fields, identifiers, digests, outcome, facts, and receipt digest; `executeVerified` invokes the local executor | Python `assert_successor_walking_skeleton`, positive legacy run, receipt mutation loop, success stages; `packages/testing-runner/tests/testing_result_authority_contract_test.lua` | `bdf7055156759ff4f066fd82ab830aad6353c25f`; implementation/mutations inspected; execution unavailable | `unverified` |
| Signed release, authorization, bundle, manifest, schema publication, and successor catalog artifacts are immutable and bound (`#800`, `#806`) | `package-release/testing-package-*.json`; verifier binding functions | Python committed digest constants, `assert_rejection_matrix`, positive verifier run, signed-artifact drift checks | `bdf7055156759ff4f066fd82ab830aad6353c25f`; `sha256sum` reproduced committed digests; signature/verifier execution unavailable | `unverified` |
| Repository and dependency inputs use exact real commit pins (`#800`, `#806`) | Generator `repository_commit`, `pinned_commit`, `source_file`, `unsigned_outputs`; `.fkst/conformance/fkst-packages.pin`; `.fkst/substrate-ref`; release source-commit file | Python `assert_bundle_uses_pinned_git_tree`, provenance substitution, generator pin rejection | `bdf7055156759ff4f066fd82ab830aad6353c25f`; pins inspected as `317cd38bd0e3f193e8732454063c6ae8f9c6ba1d`, `549caa0fb921a3f7702a0726d6cc2fa6034d05d0`, `1e21b9b57fcfe0b09521c16d77c85e693e755718`; execution unavailable | `unverified` |
| Generation is deterministic, complete, contained, and free of ambient source fallback (`#800`, `#806`, `#810`) | Generator `canonical_timestamp`, `exact_commit`, `signing_seed`, `signed_artifacts`, `unsigned_outputs`, `main` | Python `assert_generator_rejections`, repeated-signature equality, generated-tree equality, incomplete-authority and containment cases | `bdf7055156759ff4f066fd82ab830aad6353c25f`; generator/tests inspected; execution unavailable | `unverified` |
| Lua malformed publisher-metadata regression is repaired (`#812`, merged by `#814`) | Lua `bounded_string` and successor branches in `M.validate` | Lua `test_successor_rejects_malformed_publisher_metadata`, covering empty, non-string, UTF-8 overflow, control, and invalid-byte values | `bdf7055156759ff4f066fd82ab830aad6353c25f`; repair `1334a5066e1d20db749402f13e86696376f5db88` and `#814` reachable; Lua execution unavailable | `unverified` |

No row is `gap` because inspection found no missing implementation or named case within the categories
summarized by `#816`. Unavailable authoritative wording, `#811` merge identity, Hosted jobs, and
current-head execution require `unverified`, not a manufactured pass or product-failure claim.

## Conclusions

### Issue `#806`

The revision contains implementation and named tests for authenticated read order, poison proofs,
authority policy, catalog binding, Runtime-only resolution, legacy compatibility, executor success,
and receipt validation. Acceptance is not yet supported because current-head execution, authoritative
amendments, the `#811` merge identity, and Hosted evidence were unavailable. Status: `unverified`; no
source-inspection product gap found.

### Issue `#800`

The revision contains generator, immutable-artifact, provenance-pin, deterministic-output,
containment, schema, verifier, and walking-skeleton evidence matching the `#816` summary. Acceptance
is not yet supported because current-head generation/verifier execution and authoritative amendment
text were unavailable. Status: `unverified`; no source-inspection product gap found.

## Production-signing boundary

Deterministic seeds and temporary Ed25519 test keys demonstrate reproducible test tooling only. They
do not prove production signing, authorization publication, key custody, rotation, revocation
publication, or release publication under `#745` or `#789`. Historical assistant-local patches were
discarded and are not merged evidence; none is cited here.

## Closeout recommendation

Do not close `#800` or `#806` from this local record alone. On a provenance-matched Hosted runner,
execute the focused release test and package test at the current revision, retain the exact job URL and
SHA, inspect the authoritative amendments and merged pull requests, and record the exact `#811` merge
commit and reachability. If those checks pass without revealing an omitted criterion, this mapping
supports recommending acceptance. If they expose a missing case or failed behavior, mark the row
`gap` and address it in a separately scoped product change.
