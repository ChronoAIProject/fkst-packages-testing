# OpenSandbox FKST host adapter

This is an optional, non-default provider example. The reference workflow runs on the physical local
host through `examples/generic-host/`; use this adapter only when a downstream host explicitly opts
into OpenSandbox lifecycle ownership.

This downstream example owns OpenSandbox-specific lifecycle behavior without changing the reusable
testing packages or `environment-factory.v1`.

The adapter accepts one strict `fkst-opensandbox-host.run-config.v1` document. Exactly one immutable
image digest or snapshot ID is required. The configuration also binds TTL, resource limits,
deny-by-default egress, approved repository/Profile/approval/runtime-config pointers, artifact
destination, trace ID, and dedup key. Arbitrary commands, credentials, and environment maps are not
accepted.

For one dedup key, the host creates one sandbox and immediately persists its ID. It writes a bounded
launch request to `/run/fkst/host-run-request.v1.json`, then invokes only the trusted launcher at
`/opt/fkst/bin/host-launcher`. The pinned image or snapshot must provide that launcher and the FKST
runner. The launcher resolves the approved Project Profile and runs Environment Factory, dependent
services, the target application, and browser/CDP in the same sandbox using local argv and loopback
contracts.

For agentic browser execution, the host must preserve one exact readiness attempt and CDP target,
provide the target-bound browser grant, and expose host-only secret refs through the runtime's secret
stdin capability. Identity and primary-secret values never enter the run config, FKST events, Lua,
model prompts, argv, environment variables, stdout, stderr, logs, receipts, or published artifacts.
The host also owns deterministic completion probes for the exact callback, supervised process exit,
identity CLI result, and authenticated status result. AI finish text is not a completion signal.

Required `.testing/runs/...` files are downloaded with configured byte limits, SHA-256 hashed,
published durably, and recorded in the host receipt before teardown. Lifecycle ledger entries contain
only bounded status fields; raw process output stays inside sandbox artifacts. Passed, failed,
blocked, timed-out, cancelled, interrupted, and recovered-finalization paths all attempt idempotent
sandbox destruction.

## Hermetic tests

```sh
npm test --prefix examples/opensandbox-host
```

The tests use an SDK fake and do not create a sandbox.

## Opt-in live smoke

Install the exactly pinned SDK dependency, copy and edit the example configuration, then explicitly
enable live creation:

```sh
npm ci --prefix examples/opensandbox-host
cp examples/opensandbox-host/run-config.example.json /tmp/fkst-opensandbox-run.json

FKST_OPENSANDBOX_LIVE=1 \
FKST_OPENSANDBOX_CONFIG=/tmp/fkst-opensandbox-run.json \
OPEN_SANDBOX_DOMAIN=http://127.0.0.1:8080 \
npm run live-smoke --prefix examples/opensandbox-host
```

If the endpoint requires authentication, inject `OPEN_SANDBOX_API_KEY` into the host process through
the approved credential broker. Never put its value in the run configuration, FKST events, receipts,
or artifacts. The live image/snapshot must
already contain frozen dependencies, the FKST runner, target runtime, browser tooling, trusted
launcher, and the exact pinned product CLI version and digest required by the acceptance profile; the
adapter does not install mutable packages during execution. Missing secret refs, launcher/image,
existing-account state, MFA/CAPTCHA-free account state, or a matching CLI version is a live-run blocker,
not a reason to request, fabricate, or persist credentials.
