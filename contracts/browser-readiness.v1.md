# Browser readiness v1

`browser-readiness.browser_readiness_check` accepts the closed
`browser-readiness.check.v1` contract. A request contains a bounded local base URL, one or more
credential-free browser harness or CDP session descriptors, an optional execution request context,
an optional source reference, and bounded correlation metadata.

The result is `browser-readiness.result.v1` with `ready`, `blocked`, or test-only `planned` status.
It returns bounded per-session checks and exactly preserves the request `source_ref`,
`request_context`, and `correlation`. Resolved CDP URLs must remain loopback URLs. Correlation data
must not contain credentials, cookies, browser storage, raw output, bodies, screenshots, or other
unbounded evidence.

Workflow-QA treats the post-design readiness result as an authorization input. It compares the
returned context and correlation to its persisted request, writes the result as an immutable
artifact, and carries that artifact pointer and digest through planning, execution, finalization,
and terminal publication.
