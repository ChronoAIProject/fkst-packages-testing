# Structured API/CLI execution v1

`testing-runner.structured_execution_request` accepts
`testing-runner.structured-execution.request.v1`. The event is pointer-only and binds one immutable
repository commit, authenticated ready Environment Factory receipt, immutable test-plan artifact,
single-use execution approval, artifact root, source reference, trace ID, and dedup key. Inline plans,
approvals, environment bodies, credentials, headers, response bodies, command strings, mutable refs,
unknown fields, and paths outside `.testing/runs/...` are rejected before artifact reads or effects.

The referenced `testing-structured-plan.v1` contains at most 64 deterministically ordered cases. The
first slice supports:

- `cli`: bounded direct argv, timeout, and `exit-code` assertions;
- `http`: explicit method and credential-free URL, empty inline headers, timeout, and `status-code` or
  `body-contains` assertions.

Shell executables and legacy agentic-testing wrappers are unsupported. HTTP requests must match an
approved origin, method, and path prefix. CLI argv must match an approved argv prefix.

## Execution approval

`testing-structured-execution-approval.v1` is a separate host-controlled artifact. It binds the exact
plan digest, Environment Factory receipt digest, repository and commit, bounded CLI/HTTP capabilities,
authority and evidence references, policy revision, validity window, trace ID, dedup key, and
`max_uses = 1`.

The host runtime must provide an approval verifier that returns an attestation binding the approval
digest, authority, policy revision, and evidence reference. A boolean, digest knowledge, a ready
environment receipt, or a valid plan is not authorization. An atomic replay guard must claim the
approval/run tuple before the first target effect. Completed claims return their existing execution
artifact; they do not execute cases or write effective artifacts again.

## Results and artifacts

Cases produce `passed`, `failed`, `skipped`, or `error` status and use the non-passing classifications
`product-defect`, `environment-session-issue`, `data-fixture-gap`, `harness-tooling-issue`, or
`not-executed-risk`. A typed `skip_reason` with `data-fixture-gap` or `not-executed-risk` performs no
target effect and produces a durable skipped case result.

The runner writes bounded artifacts under the request artifact root:

- `test-plan.json`
- `execution.json`
- `case-results.json`
- `evidence/<case_id>.json`
- `metadata.json`

FKST events carry only the aggregate status/counts and these pointers through
`testing-runner.result.v1`, `test-artifacts.summary.v1`, and
`test-publication.publication-request.v1`.

## Host capability boundary

The package expects the host to install `structured_execution_runtime` with authenticated artifact
loading/digest verification, current time, approval verification, atomic replay claim/completion,
direct `exec_argv`, bounded HTTP request, artifact writing, and completed-result loading. The package
does not create sandboxes, resolve secrets, start Docker, invoke a shell, require root, assume private
network access, or weaken Environment Factory cleanup contracts.
