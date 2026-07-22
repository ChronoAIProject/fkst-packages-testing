# Durable QA publication v1

`test-publication.qa_checkpoint_request` accepts
`test-publication.qa-checkpoint.request.v1`. The pointer-only request binds repository slug,
immutable source commit, QA run ID, GitHub issue number, stage, attempt, status, artifact root,
artifact pointer and digest, ledger pointer, trace ID, and dedup key.

Supported ordered stages are `intake`, `sandbox-ready`, `environment-ready`, `design-round`,
`browser-readiness`, `design-closure`, `execution-batch`, `defect-publication`, `cleanup`, and
`aggregate-report`.
The durable `test-publication.qa-run-ledger.v1` uses compare-and-swap versions, rejects stale stage
transitions, and rejects replay that changes an immutable stage/attempt artifact or status.

Before a checkpoint becomes pending, the host `publish_artifact` capability must return a GitHub URL,
matching digest, matching source commit, and durable publication receipt pointer. The package then
emits `test-publication.github_issue_comment_request` with a bounded `github-proxy.v1` payload. The
host routes this seam to `github-proxy.github_issue_comment_request` and routes the resulting
`github-proxy.comment-written.v1` payload back through
`test-publication.github_comment_written`.

The canonical comment uses one `fkst:qa-run-summary` replacement marker plus a checkpoint dedup
marker. Acknowledgement writes `test-publication.qa-publication-receipt.v2` under
`<artifact_root>/publication-receipts/` and emits `test-publication.qa_publication_receipt`. The
receipt preserves the run `dedup_key` and records the distinct GitHub checkpoint identity as
`request_dedup_key`. Replayed acknowledgements return the existing receipt without a second effective
write.

## Defect preparation

`test-publication.defect_preparation_request` accepts
`test-publication.defect-preparation.request.v1`. The publication-owned preparation step loads the
digest-bound `testing-structured-plan.v2` and `testing-structured-case-results.v1`, verifies their run
identity, deterministically writes bounded `test-publication.defect-issue-drafts.v1` under the requested
pointer, and emits the existing `test-publication.defect_publication_request`. Identical replay reuses
the persisted draft artifact; changed content at that pointer fails closed.

## Final aggregate report

`test-publication.qa_finalize_request` accepts `test-publication.qa-finalize.request.v2` with immutable
pointers and digests for `workflow-qa.terminal-summary.v2`, the real
`environment-factory.receipt.v2`, the `environment-factory.cleanup-receipt.v1`, aggregate report
destination, and optional defect-publication receipt. Full finalization also requires the structured
test plan and case results; early terminal finalization is the closed variant where both are absent.

Finalization:

- validates environment repository identity and the embedded sanitized ready browser proof when the
  environment receipt is ready;
- requires `status=complete` on the digest-bound cleanup receipt for every path;
- requires every planned `case_id` to have exactly one terminal `passed`, `failed`, `skipped`, or
  `error` result for full runs;
- publishes GitHub-visible immutable URLs for terminal summary, environment, cleanup, and full-run
  plan/results when present;
- records counts, classifications, evidence pointers, defect issue links, residual risks, trace ID,
  and run dedup key in `test-publication.qa-aggregate-report.v1`;
- writes and publishes the aggregate report as the terminal `aggregate-report` checkpoint on both
  full and early-terminal paths.

Events and comments never contain credentials, cookies, browser storage, raw environments, request or
response bodies, or unbounded logs. Detailed evidence remains in immutable artifact publications.

## Host runtime boundary

The package expects `qa_publication_runtime` with `load_ledger`, compare-and-swap `save_ledger`,
`load_artifact`, deterministic-path idempotent `write_artifact` and `write_report`, and idempotent
`publish_artifact` capabilities. A completed aggregate checkpoint is loaded and reused without another
report write or GitHub request. The package does not invoke GitHub CLI commands, shells, or network
clients directly.
