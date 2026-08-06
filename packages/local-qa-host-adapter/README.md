# Local QA Host Adapter

`local-qa-host-adapter` is the repository-owned, stateless package boundary between a downstream Local QA Host and `workflow-qa`. It validates and forwards public intake, delegates execution-grant and terminal semantics to `testing_runtime.workflow_qa_host_adapter`, and supplies the reliable-queue departments required to compose those callbacks.

This package does not make the downstream Local QA Host production-ready by itself. It contains no durable state, process supervision, browser automation, workspace management, cleanup orchestration, recovery policy, product URL, credential, or product-specific default.

## Public Queues

| Direction | Queue | Canonical payload |
| --- | --- | --- |
| Host to adapter | `qa_run_request` | `workflow-qa.run-request.v2` |
| Adapter to workflow | `workflow-qa.qa_run_request` | Unchanged `workflow-qa.run-request.v2` |
| Workflow to adapter | `workflow-qa.workflow_qa_execution_grant_request` | `workflow-qa.execution-grant.request.v1` |
| Adapter to workflow | `workflow-qa.execution_grant_result` | `workflow-qa.execution-grant.result.v1` |
| Workflow to adapter | `workflow-qa.workflow_qa_terminal_request` | `workflow-qa.terminal-request.v2` |

`dead_letter` is handled as reliable-queue infrastructure and produces no business event. `local_qa_host_tick` is an inert conformance seam: its department performs no polling and emits no business event.

## Runtime Contract

The downstream Host must configure `_G.local_qa_workflow_qa_runtime` or supply the same table explicitly in a test. The table must provide these six callable ports:

- `load_artifact`
- `write_artifact`
- `artifact_digest`
- `claim_preauthorization`
- `grant_values`
- `record_terminal`

Missing, malformed, or partial ports fail closed with the `local-qa-host:` error prefix. The shared adapter validates immutable artifact bindings before emitting `workflow-qa.execution_grant_result` and validates the terminal payload, aggregate publication receipt, aggregate report, and cleanup receipt before calling `record_terminal`.

The downstream Host owns durable SQLite state, process lifecycle and process groups, cancellation and timeout enforcement, Chrome/CDP, workspace ownership, Evidence quarantine and redaction, cleanup execution, and restart recovery. It must durably implement the six ports and read its own durable terminal record after `record_terminal`; those responsibilities are intentionally outside this package.

## Verification Map

| Acceptance area | Production evidence | Focused test evidence |
| --- | --- | --- |
| Thin stateless ownership | `fkst.toml`, `adapter.lua` | Repository source ratchets and package conformance |
| Intake forwarding and rejection | `departments/intake/main.lua` | `tests/walking_skeleton_test.lua` |
| Six-port grant wiring, persistence, replay, and failure atomicity | `departments/execution_grant/main.lua`, shared adapter | `tests/host_boundary_test.lua`, shared adapter tests in `testing-runner` |
| Terminal validation before recording | `departments/terminal/main.lua`, shared adapter | `tests/host_boundary_test.lua`, shared adapter tests in `testing-runner` |
| Reliable dead letter and inert seam | `departments/dead_letter/main.lua`, `departments/seam/main.lua` | `tests/department_test.lua`, `tests/raiser_test.lua` |
| Closed-world callback edges | `.fkst/conformance/composed-roots` | `tests/run_graph_edge_coverage_test.lua` and composed conformance |

Run `scripts/run.sh test local-qa-host-adapter` for focused package verification. Repository acceptance also uses `scripts/run.sh host -- check`, `scripts/run.sh check`, and the full `scripts/run.sh test` gate.
