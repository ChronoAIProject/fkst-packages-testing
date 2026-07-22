# Environment Factory v1

`environment-factory` is a generic composed package that turns an approved
`testing-project-profile.v1` into a disposable local testing environment. Product names,
endpoints, argv, authority identities, and secret locations remain host-owned.

## Public schemas

- Start request: `environment-factory.start.v1`
- Finalize request: `environment-factory.finalize.v1`
- Cancellation/interruption request: `environment-factory.interrupt.v1`
- Result: `environment-factory.result.v1`
- Environment receipt artifact: `environment-factory.receipt.v2`
- Cleanup receipt artifact: `environment-factory.cleanup-receipt.v1`

Start requests contain exact repository identity, profile/approval/validation-receipt pointers,
durable state pointer, artifact root, exact loopback ports, base URL, browser session bootstrap,
trace ID, and dedup key. Environment Factory owns no testing module, mutation policy, test artifact,
or publication metadata. Source pointers contain exactly `{ kind, ref }`; extra nested metadata and
credential-bearing values are invalid.

Browser sessions reuse the existing browser-readiness forms: `browser_harness_command`,
`browser_harness_command_env`, `cdp_endpoint_env`, and local `cdp_url`. Unknown fields and inline
credentials, cookies, storage, environments, or output bodies are rejected.

Results are pointer-only terminal control payloads: status, one immutable environment receipt pointer,
an opaque cleanup reference, at most 32 deduplicated diagnostic artifact pointers, cleanup state,
trace ID, and dedup key. Ready, blocked, finalized, cancelled, and interrupted receipts use distinct
immutable paths. Later transitions never overwrite a receipt referenced by an earlier result. The
`environment-factory.receipt.v2` ready artifact carries the canonical repository shape
`{ url, commit_sha }` and the sanitized successful `browser-readiness.result.v1` under
`browser_readiness`; it never uses `resolved_commit` as public repository identity. For agentic
browser execution, the readiness correlation additionally binds the immutable readiness-attempt digest
and exact CDP target ID/digest used by the downstream single-use browser grant.

## Authorization and state integrity

The complete validated start request is stored as a closed binding. Every replay compares all
immutable fields, including repository, all authorization pointers, artifact root, base URL, ports,
and sessions. Changed replay inputs fail closed and cannot return an old result.

Plain operation-state artifacts are not authorization capabilities. The production adapter requires
a host-provided runtime-config artifact capability outside the operation artifact root. That host-
owned config supplies the state key and key revision, trusted time, exact authenticated approval
attestations, authorization-source materializations, repository mirrors, and bounded command
environment. State MACs bind the state pointer, state body, and host key revision; replacing a run
artifact or moving an authenticated envelope to another pointer fails authentication.

On every active provisioning or readiness-pending resume the factory reloads the referenced
authorization bundle and re-enters the same durable `authorize_claim_ports` effect. Replay of a
non-ready public result returns authenticated request-bound state without reacquiring already cleaned
resources. A cached invocation returns the original authenticated
profile snapshot and request binding without invoking `authorize_execution` or reclaiming the
single-use approval. Each trusted-authority callback may return `authenticated=true` only when its
host-configured approval digest, authority, policy revision, and evidence pointer exactly match the
candidate approval. The factory compares the binding, deadline, port claim, and checkout identity,
then replaces executable profile data with that trusted snapshot.

`authorize_claim_ports` invokes
`contract.project_profile.authorize_execution(profile, approval, receipt, context)` only on its
first durable attempt. A rejected authorization performs zero target effects. On success, a
serialized durable lease for the exact ports is the immediate first target effect, and an OS
availability preflight must pass before the lease is recorded. Two Environment Factory operations
cannot lease the same approved port. Because generic argv processes cannot accept inherited listener
file descriptors, readiness additionally requires exact post-start OS listener ownership; a foreign
takeover fails closed. The lease returns an opaque cleanup reference and is the first acquired
resource, therefore the last released during reverse cleanup.

Checkout is the next deduplicated effect and uses only the trusted returned profile snapshot. A
failed checkout must report any partially acquired workspace and cleanup reference. The factory
checkpoints that handle before returning a blocked result and unwinds it with the port claim.

## Lifecycle

The v1 order is:

1. Authenticate approval, serialize the exact approved loopback-port lease, and preflight availability.
2. Checkout the immutable commit and verify the resolved object ID.
3. Run optional install and build direct argv phases.
4. Start declared dependent services and run their readiness checks.
5. Run optional migrate and seed direct argv phases.
6. Start the application and run all application readiness checks.
7. Persist authenticated operation state as `readiness-pending`, persist one immutable readiness-attempt artifact, and emit `browser-readiness.check.v1`.
8. On a correlated authenticated browser success, bind the sanitized result into the immutable ready receipt and publish the pointer-only ready result. On browser failure, clean up and publish only a blocked result backed by immutable cleanup and environment receipts.
9. Finalize, cancel, or interrupt through the same idempotent reverse cleanup path. Environment Factory does not start, acknowledge, or supervise testing.

The install runtime receives `requires_frozen_dependencies = true` and must return explicit proof
that frozen dependency resolution was enforced. The host runtime config selects the frozen policy;
the v1 npm policy authorizes exactly `npm ci --offline --ignore-scripts`, requires real
`package.json` and `package-lock.json` files, and records matching pre/post manifest and lockfile
digests. Generic Lua does not parse package-manager flags. Every runtime effect receives the approved
resource budgets, output-byte limit, per-phase timeout, total lifecycle deadline, and current
remaining budget. CPU is accounted cumulatively, readiness network requests are charged per actual
TCP/HTTP probe across effects, and process count, workspace disk use, and process-group RSS are
measured conservatively. Unsupported measurement fails closed. `total_seconds` bounds provisioning
and resumed lifecycle effects through readiness; an explicitly finalized environment does not gain an
implicit background lifetime monitor. Normal effects fail when that provisioning budget is exhausted;
cleanup still receives the remaining budget and approved cleanup timeout.

Commands are executed shell-free as the exact dense argv lists from the authorized snapshot. The
factory never substitutes or rewrites ports after authorization. Each service receives only ports
referenced by its own readiness checks; the application receives only ports referenced by its
readiness checks and allowed origins. Ambiguous or unowned port assignments fail before execution.
After readiness succeeds, Darwin/Linux listener inspection verifies that every expected listener
belongs to the spawned process group. Missing, foreign, extra, malformed, duplicate, occupied, or
unclaimed runtime ports fail closed and trigger reverse cleanup.

## Cleanup and receipts

Application, services, workspace, and port claim are recorded as one resource stack. Provisioning
failure, readiness failure, source mismatch, timeout, finalization, cancellation, and interruption
all invoke the same reverse-order cleanup function. Cleanup requests use stable effect IDs and are
safe to replay. `operation_id` is the canonical run owner for the artifact root, checkout workspace,
fixture database state under that workspace, service/process namespace, exact listener claims, and
browser session/profile capabilities. Runtime effects reject workspace or cleanup references whose
durable resource record belongs to another operation, and port release removes only exact claims
owned by the same operation and effect.

Every terminal path writes an immutable `environment-factory.cleanup-receipt.v1` before publishing
the terminal environment receipt. The cleanup receipt records every attempted resource, verified
removals, remaining resource cleanup pointers, aggregate `complete` or `incomplete` status, artifact
root, trace ID, and dedup key. Terminal `environment-factory.result.v1` payloads carry its immutable
artifact pointer. A run remains blocked and has no reusable terminal result when that receipt cannot
be persisted or when any removal cannot be verified.

A result is constructed only after its receipt write succeeds. If ready-receipt persistence fails,
the factory cleans up and may publish only a successfully persisted blocked receipt. If blocked-
receipt persistence also fails, state is saved without a public result and the call fails; no
dangling receipt pointer is emitted.

## Host runtime ports

The host adapter provides:

- authenticated `load_state` and integrity-preserving `save_state`;
- `load_authorization_bundle`;
- durably deduplicated `authorize_claim_ports`, `checkout`, and `create_readiness_attempt`;
- trusted `remaining_budget`;
- shell-free `run_argv` and typed `wait_readiness`;
- idempotent `cleanup`;
- immutable `write_receipt`.

Runtime outcomes contain control metadata and bounded artifact pointers only. Inline output,
process IDs, raw environments, credentials, cookies, and browser storage are invalid.

## Production runtime and hermetic coverage

`packages/environment-factory/runtime.lua` is the production port adapter. A host may pass
`runtime_config_ref` and `runtime_cli` providers explicitly to `runtime.production(options)`. Installed
`environment_factory_runtime_config_ref` and `environment_factory_runtime_cli` globals override those
providers, preserving the framework-installed host capability path. The adapter serializes bounded
effect requests under the operation artifact root and invokes
`packages/environment-factory/bin/environment-factory-runtime.js` through `exec_argv`. The Node
runner reads only the host-selected runtime configuration and its authorization materializations,
authenticates saved state, durably deduplicates effects, self-verifies cached immutable receipts,
executes exact argv with `shell: false` and a minimal host-approved environment, supervises child
process groups, and releases process, workspace, and exact-port resources through retryable
idempotent cleanup effects.

The hermetic package test drives the Lua core and departments through this real adapter. It creates
a local Git repository and exact commit, runs a real frozen npm install, starts a neutral stateful
loopback service, and requires migrate/seed commands to update that service before the HTTP
application can become ready. It proves no ready receipt exists while state is `readiness-pending`,
passes the actual `browser-readiness` result back into Environment Factory, verifies the immutable
ready receipt binds that sanitized proof, verifies replay returns the same pointer-only result, then
finalizes explicitly. It also proves foreign listener takeover, zero/cumulative probe accounting,
resource budget failures, clean source state, and released
checkout/listeners without an external network or service.
