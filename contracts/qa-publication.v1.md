# Durable QA publication v1

`test-publication.qa_checkpoint_request` accepts
`test-publication.qa-checkpoint.request.v1`. The pointer-only request binds repository slug,
immutable source commit, QA run ID, GitHub issue number, stage, attempt, status, artifact root,
artifact pointer and digest, ledger pointer, trace ID, dedup key, and an optional `channel`
discriminator. Omitted `channel` retains the legacy `github-comment-v1` behavior; new filesystem
requests must explicitly use `filesystem-dry-run-v1`. The artifact root is exactly
`.testing/runs/<run_id>`, and every request, ledger, materialization, report, and receipt pointer must
remain below that run root.

Supported ordered stages are `intake`, `sandbox-ready`, `environment-ready`, `design-round`,
`browser-readiness`, `design-closure`, `execution-batch`, `defect-publication`, `cleanup`, and
`aggregate-report`.
The durable `test-publication.qa-run-ledger.v1` uses compare-and-swap versions, rejects stale stage
transitions, and rejects replay that changes an immutable stage/attempt artifact or status.

For `github-comment-v1`, before a checkpoint becomes pending the host `publish_artifact` capability
must return `status=published`, a GitHub URL, matching digest, matching source commit, and a durable
publication receipt pointer below the run root. The package then emits
`test-publication.github_issue_comment_request` with a bounded `github-proxy.v1` payload. The host
routes this seam to `github-proxy.github_issue_comment_request` and routes the resulting
`github-proxy.comment-written.v1` payload back through `test-publication.github_comment_written`.
This path is unchanged for requests that omit `channel`.

For `filesystem-dry-run-v1`, the same host `publish_artifact` port is the materialization boundary. It
must return `status=materialized`, echo the exact local `artifact_ref`, matching digest, matching source
commit, no `remote_url`, and a durable materialization receipt pointer plus receipt digest below the run
root. Before advancing the ledger, the package loads that digest-bound
`test-publication.qa-materialization-receipt.v1` and verifies its schema, status, channel, run, stage,
attempt, artifact pointer and digest, source commit, trace ID, dedup key, and self pointer. The package
then writes the deterministic `test-publication.qa-publication-receipt.v2`, marks the checkpoint
complete in the CAS ledger, and emits `test-publication.qa_publication_receipt` directly. It emits no
GitHub comment or issue intent and never constructs a `github.com` URL for local artifacts.

The canonical GitHub comment uses one `fkst:qa-run-summary` replacement marker plus a checkpoint
dedup marker. Both channels write `test-publication.qa-publication-receipt.v2` under
`<artifact_root>/publication-receipts/` and emit `test-publication.qa_publication_receipt`. The receipt
preserves the run `dedup_key` and records the distinct checkpoint identity as `request_dedup_key`.
Filesystem receipts additionally record `channel=filesystem-dry-run-v1`, the local `artifact_ref`, the
host materialization receipt pointer and digest, and `github_publication_occurred=false`; they omit comment IDs and
remote URLs. Replayed acknowledgements or filesystem requests return the existing receipt without a
second effective materialization, receipt write, or ledger transition.

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
  plan/results when `channel=github-comment-v1`, preserving legacy behavior;
- materializes digest-bound local pointers for those artifacts when
  `channel=filesystem-dry-run-v1`, without constructing GitHub URLs;
- records counts, classifications, evidence pointers, defect issue links, residual risks, trace ID,
  and run dedup key in `test-publication.qa-aggregate-report.v1`; filesystem reports also record their
  channel and `github_publication_occurred=false` so terminal lifecycle consumers can state that no
  GitHub publication occurred;
- writes and publishes the aggregate report as the terminal `aggregate-report` checkpoint on both
  full and early-terminal paths.

Events and comments never contain credentials, cookies, browser storage, raw environments, request or
response bodies, or unbounded logs. Detailed evidence remains in immutable artifact publications.

## Host runtime boundary

The package expects `qa_publication_runtime` with `load_ledger`, compare-and-swap `save_ledger`,
`load_artifact`, deterministic-path idempotent `write_artifact` and `write_report`, and idempotent
`publish_artifact` capabilities. `publish_artifact` must implement the selected channel contract and
must make repeated filesystem materialization requests for the same run/stage/attempt/digest converge
on the same acknowledgement. A completed aggregate checkpoint is loaded and reused without another
report write, materialization, or GitHub request. The package does not invoke filesystem APIs, GitHub
CLI commands, shells, or network clients directly.
