# Product-defect publication v1

`test-publication.defect_publication_request` accepts
`test-publication.defect-publication.request.v1`. The request wraps a failed
`test-publication.publication-request.v1` for `structured-execution` and binds an immutable
repository commit, test-plan digest, case-results pointer and digest, defect issue-drafts pointer and
digest, compare-and-swap ledger pointer, receipt pointer, trace ID, and run dedup key.

The referenced case-results artifact uses `testing-structured-case-results.v1`. The referenced draft
artifact uses `test-publication.defect-issue-drafts.v1`; each bounded draft contains a stable
`case_id`, title, expected summary, actual summary, and evidence pointer under the run artifact root.
Requests, events, and drafts do not carry inline evidence, report bodies, credentials, cookies, raw
environments, browser storage, or unbounded logs.

## Classification policy

Only a case classified as `product-defect` with a matching evidence-bound draft emits
`test-publication.github_issue_create_request`. Passed, environment-session, data-fixture,
harness/tooling, and not-executed-risk outcomes are recorded as `summary-only`. A product defect
without a valid matching draft is recorded as `blocked`; it does not create an Issue.

The emitted payload is `github-proxy.issue-create.v1` with a bounded actionable title and body,
`fkst-dev:enabled` and `bug` labels, source commit, plan digest, case ID, expected and actual
summaries, classification, and evidence pointer. Its stable dedup key is derived from repository slug,
immutable source commit, plan digest, and case ID. The host routes this seam to
`github-proxy.github_issue_create_request`; the package never invokes GitHub, a shell, or a network
client directly.

## Acknowledgement and receipt

The pinned GitHub package does not currently publish an issue-created receipt, so the host must route
the durable result back through `test-publication.github_issue_written` as
`github-proxy.issue-written.v1`. The acknowledgement contains `created` or `deduplicated`, the Issue
number, the exact same-repository Issue URL, the original request dedup key, and the unchanged
`test-publication.product-defect` handoff.

The compare-and-swap `test-publication.defect-publication-ledger.v1` persists pending intents before
they are emitted. Replay returns the same pending intent and relies on `github-proxy` for the single
effective write. Independent acknowledgements can complete product-defect cases in any order.

After every product-defect acknowledgement is terminal, the package writes
`test-publication.defect-publication-receipt.v1`. Every case maps to `created`, `deduplicated`,
`summary-only`, or `blocked`, with evidence pointer and optional Issue identity. Only after this
receipt is durable does the package emit `test-publication.defect_publication_terminal`. Runs with no
required Issue writes can write the receipt and terminal event during preparation.

## Host runtime boundary

The package expects `defect_publication_runtime` with `load_ledger`, compare-and-swap `save_ledger`,
`load_artifact`, and deterministic-path idempotent `write_artifact` capabilities. Receipt persistence
can complete before the corresponding ledger compare-and-swap, so retrying the same receipt path and
content must be safe. Runtime capabilities fail closed when absent.
