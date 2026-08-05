# Structured execution v2

`testing-runner.structured_plan_request` compiles one reviewed module plan into an immutable `testing-structured-plan.v2`. `workflow-qa` then obtains an external single-use grant before dispatching an executor.

The plan declares exactly one execution mode:

- `structured-api-cli`: one or more bounded `cli` and `http` cases;
- `agentic-browser`: exactly one bounded `browser` case.

Mixed browser and API/CLI execution is invalid. Browser plans never enter the fixed API/CLI executor.

## Planning

`testing-runner.structured-plan.request.v1` binds the immutable repository, module-plan pointer and digest, host case-catalog pointer and digest, ready Environment Factory receipt pointer and digest, output plan pointer, artifact root, source reference, trace ID, and dedup key.

The compiler intersects reviewed executable design cases with host-authorized case mappings. Unmapped reviewed cases remain sorted residual risk. Shell execution, inline headers, credential-bearing URLs, unknown fields, and malformed receipt bindings fail closed.

The compiler emits `testing-runner.structured-plan.result.v1` with the immutable plan pointer, digest, and residual-risk count.

## Grant request

`workflow-qa.execution-grant.request.v1` binds the plan execution mode, preauthorization pointer and digest, plan pointer and digest, ready environment receipt pointer and digest, requested grant pointer, repository, source reference, trace ID, and dedup key.

The grant signer is host-owned and outside this repository. A ready environment or valid plan is not authorization.

For `structured-api-cli`, the signer publishes `testing-structured-execution-grant.v1`. It binds the parent authorization, exact plan and environment digests, repository, positive CLI argv-prefix and HTTP origin/method/path-prefix capabilities, authority and evidence references, policy revision, validity window, trace ID, dedup key, and `max_uses = 1`.

For `agentic-browser`, the signer publishes the separate browser grant documented in `agentic-browser-execution.v1.md`.

## Fixed API/CLI executor

`testing-runner.structured_execution_request` accepts `testing-runner.structured-execution.request.v3`. The request is pointer-only and binds the validated Project Profile, profile validation receipt, preauthorization, one immutable repository commit, ready Environment Factory receipt-v2, plan-v2, single-use structured grant, artifact root, source reference, trace ID, and dedup key.

The fixed executor accepts only `execution_mode = "structured-api-cli"` and supports:

- `cli`: bounded direct argv, timeout, and `exit-code` assertions;
- `http`: explicit method, credential-free query-free URL, empty inline headers, timeout, and `status-code` or `body-contains` assertions.

Shell executables are unsupported. HTTP requests and CLI argv must match the positive capabilities in the authenticated grant. Every executable effect is a closed `testing-action-envelope.v1` derived from persisted authority artifacts. The envelope carries the common immutable profile, validation, preauthorization, repository, run, environment, workspace, plan, grant, trace, dedup, expiry, and replay-fence bindings plus one typed effect payload. The legacy `testing-cli-action-envelope.v1` remains accepted by the CLI compatibility boundary.

The Host-owned Local PEP reloads the bound artifacts immediately before each effect and issues one bounded `testing-effect-authorization-receipt.v1`. Both physical gateways authenticate and atomically consume that single-use receipt before opening a process or connection. Canonical HTTP execution is limited to one exact planned and granted numeric-loopback request with a supported method, normalized query-free path, empty headers, bounded timeout/output, disabled proxy routing, no DNS alias, and no redirect following. The ready receipt, Project Profile, preauthorization, exact plan case, grant, owned workspace/process listener, and replay claim must all authorize the same target. A missing, denied, malformed, expired, foreign, or replayed receipt performs no target effect. The default generic-host fixture further narrows this generic contract to `GET http://127.0.0.1:<ready-port>/health`.

The reference runtime executes direct argv in the approved working directory of the exact-commit disposable local checkout and rejects tracked-file changes before a test effect; untracked install/build outputs remain allowed. It never falls back to the Host process current directory. The host verifier returns an attestation bound to the grant digest, authority, policy revision, and evidence reference. An atomic replay guard grants execution to exactly one caller before the first target effect. The durable Host binds an incomplete replay to a Host-observed delivery owner and versioned owner generation: concurrent redelivery while that owner remains live observes `in-progress`, performs no effects or effective writes, and publishes no downstream result; only a CAS takeover from a dead or PID-reused owner may recover. Durable effect journals establish an at-most-once boundary, not a cross-system transaction: a persisted `started` effect has an indeterminate physical outcome and is never retried automatically, while a `completed` effect reuses its persisted result without another process or request. Completion validates the bound execution artifact and stores its digest. Completed claims return that exact result pointer and digest and perform no effects or effective writes.

## Results

Cases produce `passed`, `failed`, `skipped`, or `error` with bounded classifications. Typed `skip_reason` values perform no target effect.

The runner writes:

- `test-plan.json`
- `execution.json`
- `case-results.json`
- `evidence/<case_id>.json`
- `metadata.json`

FKST events carry only aggregate status, counts, and artifact pointers through `testing-runner.result.v1`, `test-artifacts.summary.v1`, and publication contracts.

The host installs `structured_execution_runtime` with authenticated artifact loading, current time, grant verification, atomic replay claim/completion, generic `authorize_effect`, owner-bound receipt-consuming direct argv and bounded loopback HTTP gateways, artifact writing, and completed-result loading. `authorize_cli_effect` and the `authorize-cli-effect` runtime operation remain compatibility aliases for legacy CLI envelopes; canonical hosts use `authorize-effect`. `testing_runtime.structured_execution.production()` and `libraries/testing_runtime/bin/fkst-structured-execution-runtime.js` provide the reference physical-host implementation. The package does not create sandboxes, resolve secrets, invoke shells, or weaken Environment Factory cleanup.
