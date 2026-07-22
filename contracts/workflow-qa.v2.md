# workflow-qa v2

`workflow-qa` is the composed orchestration package for one open GitHub issue labelled `fkst-qa`. The host supplies the approved Project Profile, authorization artifacts, external grant signer, runtime capabilities, and immutable run identity.

The formal host-owned lifecycle is:

`project profile + one-use approval -> qa_run_request -> environment ready receipt -> testing design -> browser session readiness -> module-testing-pipeline -> module-test-loop -> testing-runner -> pointer-only artifact summary -> defect/checkpoint publication -> verified environment cleanup -> aggregate report -> host terminal policy`

The durable workflow phases are:

`intake checkpoint -> environment-pending -> environment-ready checkpoint -> analysis-pending -> design checkpoint -> browser-readiness-pending -> browser-readiness checkpoint -> module-pending -> design-closure checkpoint -> structured-plan-pending -> execution-grant-pending -> selected execution -> artifact-summary-pending -> execution/defect checkpoints -> cleanup-pending -> cleanup checkpoint -> publication-pending -> terminal`

The run request binds the repository slug and credential-free URL, immutable commit, issue, run ID, artifact and state roots, user seed cases, Environment Factory start, design request, structured execution pointers, publication pointers, terminal policy, trace ID, and dedup key. Changed replay input fails closed. Product names, commands, endpoints, and credentials remain in the downstream Host project profile and approval material.

## Planning and grant

After Environment Factory publishes a ready receipt-v2, workflow-QA runs repository analysis and the reviewed design loop. It then revalidates the exact browser session through `browser-readiness`, persists the result as a digest-bound artifact, and only then dispatches `module-testing-pipeline`. This post-design gate prevents a stale environment-time session proof from authorizing module execution.

A terminal module plan is sent to `testing-runner.structured_plan_request`. The compiled `testing-structured-plan.v2` is loaded and digest-checked before workflow-QA requests an external grant. The Host signer derives that grant from the one-use preauthorization supplied before `qa_run_request`; the grant request carries the plan execution mode and immutable preauthorization, plan, and environment bindings.

No executor request is emitted before a granted result points to a digest-bound single-use grant artifact.

## Execution routing

The plan mode is a closed discriminator:

- `structured-api-cli` routes only to `testing-runner.structured_execution_request` and enters `structured-execution-pending`.
- `agentic-browser` routes only to `testing-runner.ai_browser_control_request` and enters `browser-control-pending`.

The selected job is persisted in durable state. Result and artifact-summary handlers accept only that job. A browser plan cannot enter the fixed API/CLI executor, and an API/CLI plan cannot enter browser control.

Deterministic mode executes an AI-authored fixed plan. Agentic mode lets AI choose one typed browser action per turn while the runner remains the effect and success authority. The browser contract is documented in `agentic-browser-execution.v1.md`.

## Failure, defects, and cleanup

Execution results pass through `test-artifacts`. Failed product cases enter `test-publication.defect_preparation_request`; cleanup waits for the durable defect-publication terminal receipt. Browser-control failure, interrupt, cancellation, timeout, or unsafe browser signal requests Environment Factory cleanup without another AI turn.

Every path finalizes through Environment Factory. Completion requires a complete cleanup receipt and aggregate publication receipt. `workflow_qa_terminal_request` is a bounded handoff to the downstream Host; labels, issue state, and other terminal effects are not hard-coded by this package.

Durable state retains the current phase and at-least-once pending actions. Redelivery re-emits the same downstream request. Downstream digest bindings, compare-and-swap state, grant replay claims, publication ledgers, and cleanup ownership make repeated delivery idempotent.

Workflow-QA performs no target commands, browser effects, secret resolution, or GitHub effects. Those remain owned by Environment Factory, testing-runner, test-publication, and github-proxy.
