# Testing result consumer inventory v1

`testing-result-consumers.v1.json` is the executable inventory for canonical result, evidence,
compatibility, and result-authority consumers. It applies single-source-of-truth and anti-corruption-layer
practice: canonical execution contracts own semantics, `contract.testing_results_compat` owns bounded
legacy projection, and publication owns provider policy only.

`canonical-reader` entries may derive publication facts only after public canonical validation.
`one-way-legacy-projection-reader` entries may validate legacy-only input or compare it with
`contract.testing_results_compat.project_v1`; they may not treat v1 as competing canonical authority.
`explicitly-out-of-scope` entries identify contract owners and producers so source references are not
mistaken for downstream consumers. Browser `blocked` and `lost` outcomes remain canonical-only because
v1 has no truthful status mapping, and all other Browser outcomes remain canonical-only because the
unchanged v1 kind vocabulary is limited to CLI and HTTP cases. Publication consumers accept that
canonical artifact group without requiring `case-results.json`, and validate the legacy projection only
when its pointer is supplied.

`libraries/testing_runtime/qa_publication.lua` is an artifact transport adapter and has no result
semantics; publication validation remains in `packages/test-publication/canonical_results.lua`,
`packages/test-publication/qa_publication.lua`, and `packages/test-publication/defect_publication.lua`.
No new hook is required in `contract.testing_result_authority`; its receipt validation remains scoped
to executions that produce `testing-result-authority-receipt.v1`.
