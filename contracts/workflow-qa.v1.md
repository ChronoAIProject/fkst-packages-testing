# workflow-qa v1

`workflow-qa` is a composed orchestration package for one open GitHub issue labelled `fkst-qa`.
It does not consume the `github-devloop-intake.devloop_intake_candidate` seam and does not create a
session or sandbox. The host supplies the approved Project Profile, authorization/runtime
capabilities, and an already selected QA session.

The run request closes over the repository slug and credential-free URL, immutable commit, issue,
run ID, artifact/state roots, profile and approval pointers, trace ID, dedup key, user seed cases,
and the downstream environment, design, execution, publication, and terminal policy configuration.
Changed replay input fails closed.

The package writes bounded intake and `testing-runner.ai-seed-cases.v1` artifacts, starts
`environment-factory`, waits for its authenticated ready result, invokes `testing-design`, routes
the resulting context through the bounded testing-pipeline design loop, and executes the immutable
plan through `testing-runner.structured_execution_request`.

Failed product cases are sent to `test-publication.defect_publication_request`; cleanup does not
start until the durable defect-publication terminal receipt arrives. Every path finalizes through
Environment Factory. Completion requires `cleanup_status=complete`, the aggregate GitHub publication
receipt, and a final `workflow_qa_terminal_request` for the host's close/terminalize policy.

The host runtime provides durable state lookup, immutable artifact writes/digests, and bounded issue
draft materialization. It does not execute target commands or call GitHub; those effects remain owned
by Environment Factory, testing-runner, test-publication, and github-proxy.

Durable state retains an at-least-once outbox. Replayed input can re-emit the same downstream request,
but stable downstream dedup identities prevent a second environment, repeated completed execution,
duplicate defects, repeated effective publication, or repeated effective cleanup.

Scope is deliberately limited to approved headless API/CLI testing with bounded resources and
public or binary-bootstrappable dependencies. It assumes no Docker, root access, source builds,
private-network access, or browser-heavy workflow.
