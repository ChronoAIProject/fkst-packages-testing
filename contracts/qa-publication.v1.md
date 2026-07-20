# Durable QA publication v1

`test-publication.qa_checkpoint_request` accepts
`test-publication.qa-checkpoint.request.v1`. The pointer-only request binds repository slug,
immutable source commit, QA run ID, GitHub issue number, stage, attempt, status, artifact root,
artifact pointer and digest, ledger pointer, trace ID, and dedup key.

Supported ordered stages are `intake`, `sandbox-ready`, `environment-ready`, `design-round`,
`design-closure`, `execution-batch`, `defect-publication`, `cleanup`, and `aggregate-report`.
The durable `test-publication.qa-run-ledger.v1` uses compare-and-swap versions, rejects stale stage
transitions, and rejects replay that changes an immutable stage/attempt artifact or status.

Before a checkpoint becomes pending, the host `publish_artifact` capability must return a GitHub URL,
matching digest, matching source commit, and durable publication receipt pointer. The package then
emits `test-publication.github_issue_comment_request` with a bounded `github-proxy.v1` payload. The
host routes this seam to `github-proxy.github_issue_comment_request` and routes the resulting
`github-proxy.comment-written.v1` payload back through
`test-publication.github_comment_written`.

The canonical comment uses one `fkst:qa-run-summary` replacement marker plus a checkpoint dedup
marker. Acknowledgement writes `test-publication.qa-publication-receipt.v1` under
`<artifact_root>/publication-receipts/` and emits `test-publication.qa_publication_receipt`. Replayed
acknowledgements return the existing receipt without a second effective write.

## Final aggregate report

`test-publication.qa_finalize_request` accepts `test-publication.qa-finalize.request.v1` with
immutable pointers and digests for the structured test plan, case results, ready environment receipt,
verified cleanup receipt, aggregate report destination, and optional #99 defect-publication receipt.

Finalization:

- requires every planned `case_id` to have exactly one terminal `passed`, `failed`, `skipped`, or
  `error` result;
- refuses completion when environment readiness or cleanup finalization is not verified;
- publishes GitHub-visible immutable URLs for the plan, case results, environment, and cleanup
  receipts;
- records counts, classifications, evidence pointers, defect issue links, residual risks, trace ID,
  and dedup key in `test-publication.qa-aggregate-report.v1`;
- publishes the aggregate report as the terminal `aggregate-report` checkpoint.

Events and comments never contain credentials, cookies, browser storage, raw environments, request or
response bodies, or unbounded logs. Detailed evidence remains in immutable artifact publications.

## Host runtime boundary

The package expects `qa_publication_runtime` with `load_ledger`, compare-and-swap `save_ledger`,
`load_artifact`, deterministic-path idempotent `write_artifact` and `write_report`, and idempotent
`publish_artifact` capabilities. A completed aggregate checkpoint is loaded and reused without another
report write or GitHub request. The package does not invoke GitHub CLI commands, shells, or network
clients directly.
