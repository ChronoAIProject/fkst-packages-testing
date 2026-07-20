# fkst-packages-testing

Testing and QA building-block packages for the **fkst** ecosystem.

This repository is intentionally separate from [`fkst-packages`](https://github.com/ChronoAIProject/fkst-packages). It owns the testing / QA domain boundary: test runner orchestration, browser readiness, testing artifact contracts, publication handoff, module and platform test-loop lifecycle, and online regression entry points.

The runtime adapter is FKST-native by default. The old `agentic-testing` Python CLI and host wrapper are no longer executable backends; legacy requests are blocked rather than silently falling back.

This repository contains no engine Rust and no host application state.

## Package catalog

| Package | Shape | What it does | Status |
| --- | --- | --- | --- |
| `testing-runner` | flat adapter | Runs configured jobs plus approval-bound structured API/CLI plans through the FKST-native runtime boundary and emits normalized testing result payloads; legacy `agentic-testing` requests are blocked. | migrating |
| `browser-readiness` | flat adapter | Checks local browser-harness/CDP/base URL readiness and can carry bounded execution context through the readiness gate. | migrating |
| `test-artifacts` | flat library package | Defines the normalized `.testing` artifact summary contract. | skeleton |
| `test-publication` | durable adapter | Converts testing handoffs into pointer-only publication requests, publishes verified product defects as deduplicated development Issues, and provides replay-safe QA checkpoints, immutable GitHub artifact receipts, and reconciled aggregate reports through host-routed `github-proxy` seams. | migrating |
| `testing-pipeline` | composed lifecycle | Composes module loop, runner, artifact summary, and publication handoff for graph-level testing flows. | skeleton |
| `testing-discovery` | composed lifecycle | Converts bounded local app-scope observations into FKST-native module starts without a hand-authored product module catalog. | experimental |
| `environment-factory` | composed lifecycle | Uses an approved project-profile snapshot to prepare an exact disposable loopback environment, hand it to browser readiness and the testing pipeline, and finalize it through an opaque cleanup reference. | experimental |
| `module-test-loop` | composed lifecycle | Module-level testing lifecycle orchestration that delegates runner execution to `testing-runner`. | migrating |
| `platform-test-loop` | composed lifecycle | Platform-level multi-module testing lifecycle orchestration. Initially delegates to `module-test-loop` / `testing-runner`. | skeleton |
| `online-regression` | flat adapter | Online regression / heartbeat entry point with a first native no-browser heartbeat path. | migrating |

## Layout

```text
packages/<name>/
  fkst.toml
  core.lua
  departments/<department>/main.lua
  tests/*_test.lua
contracts/
  defect-publication.v1.md
  environment-factory.v1.md
  project-profile.v1.md
  qa-publication.v1.md
  structured-execution.v1.md
  testing-runner.v1.md
  testing-discovery.v1.md
libraries/
  contract/ workflow/ testkit/
```

## Downstream usage

Host repositories compose these packages and provide their own app-specific defaults. This repository should not encode product modules, fixed base URLs, browser roles, or environment variable names.

A typical host flow is:

1. Produce a `browser-readiness.check.v1` request with host-provided sessions, local base URL, and optional bounded `request_context`.
2. Feed the `browser-readiness.result.v1` into a `module-test-loop.start.v1` request.
3. Let `module-test-loop` emit `testing-runner.module-test-loop.request.v1`.
4. Run it through `testing-runner`; omitted `backend` resolves to `fkst-native`, the only executable backend.

Product-specific profiles belong in the downstream host repository. This repository only provides reusable testing/QA building blocks and neutral contracts. The neutral fixtures under `examples/generic-host/` show how host-owned native module, browser-driver, and UI-loop profiles can translate into these existing events without adding product facts to this repo.

For headless API/CLI plans, hosts publish the pointer-only
`testing-runner.structured-execution.request.v1` seam documented in
`contracts/structured-execution.v1.md`. A separate authenticated single-use approval binds the exact
plan digest to positive argv and HTTP capabilities. The runner performs direct argv/HTTP effects only
after point-of-use verification and an atomic replay claim, then forwards aggregate pointers through
the existing artifact and publication packages.

Durable GitHub-visible QA reporting uses the checkpoint and finalization seams in
`contracts/qa-publication.v1.md`. `test-publication` maintains a compare-and-swap run ledger,
publishes immutable artifact receipts through host capabilities, reconciles terminal case results and
verified cleanup, and emits bounded `github-proxy.v1` comment intents. The host maps the package's
outbound and acknowledgement seams to the pinned `github-proxy`; raw GitHub credentials and commands
never enter the testing packages.

Verified structured-execution product defects use the pointer-only request, issue-draft artifact,
GitHub Issue intent, acknowledgement, and per-case receipt protocol in
`contracts/defect-publication.v1.md`. Only `product-defect` cases emit Issue intents; environment,
fixture, harness, passed, and not-executed outcomes remain summary-only. The host maps the outbound
Issue seam and durable issue-written acknowledgement to the pinned `github-proxy` package.

For sandbox-hosted QA, `examples/opensandbox-host/` provides the provider-specific downstream adapter: it binds a pinned OpenSandbox image or snapshot, approved capability pointers, bounded resources and network policy, one idempotent sandbox receipt, artifact hashing/publication, and teardown. OpenSandbox details remain outside the reusable packages and do not change `environment-factory.v1`.

Project startup configuration uses the separate `testing-project-profile.v1` and
`testing-project-profile-approval.v1` contracts documented in `contracts/project-profile.v1.md`.
Profile validity and canonical digest identity never grant execution permission: a host trust root must
authenticate the exact approval, and `contract.project_profile.authorize_execution` must recheck the
profile, immutable repository commit, approval, validation receipt, freshness, and replay claim
immediately before checkout or command execution. The controlled JSON fixture lives under
`examples/generic-host/project-profile/`.

`environment-factory` accepts only pointer-based start events and binds every immutable request
field. Its host runtime re-enters `authorize_execution` through a serialized durable exact-port
lease; the lease is the immediate first target effect, preflights OS availability, and returns the
trusted deep-copied snapshot used by checkout and direct argv phases. Post-start readiness proves the
exact loopback listener set belongs to the supervised process group. Authenticated durable state,
immutable per-status receipts, provisioning/resource budgets, frozen dependency enforcement, reverse
cleanup, cancellation, and interruption are part of the contract. The package reuses the existing
`browser-readiness` -> `testing-pipeline` interfaces and redelivers one idempotent handoff payload
until terminal acknowledgement. Its production adapter is
`packages/environment-factory/runtime.lua`, backed by the shell-free Node effect runner at
`packages/environment-factory/bin/environment-factory-runtime.js`; the hermetic package test drives
that adapter through real Git, process, readiness, receipt, handoff, and cleanup effects.

Terminal Environment Factory results include an immutable typed cleanup-receipt pointer. The receipt
lists attempted resources, verified removals, and remaining owner-bound cleanup handles; cross-run
workspace and cleanup references fail closed, and a run cannot report completion without verified
cleanup publication.

For autonomous coverage, a host can submit `testing-discovery.app-scope.v1` with local scope, sessions, policy, and bounded AI/browser/navigation/accessibility observations. `testing-discovery` derives module starts automatically, writes a sanitized discovery plan under `.testing/runs/...`, and reuses the existing `browser-readiness` -> `testing-pipeline` -> `module-test-loop` -> `testing-runner` -> artifact/publication path. Hosts provide only bootstrap scope and safety policy; product-specific module catalogs are not required in this package set.

### Generic downstream integration example

A host repository can keep its app-specific choices outside this package set and submit only bounded control metadata:

```lua
-- 1. Host-provided readiness gate.
{
  schema = "browser-readiness.check.v1",
  base_url = host_base_url,
  sessions = host_browser_sessions,
  request_context = {
    no_browser = true,
    dry_run = false,
    native_argv = host_module_check_argv,
  },
}

-- 2. Convert a ready result into a generic pipeline start event.
{
  schema = "testing-pipeline.module-start.v1",
  module = host_module_name,
  backend = "fkst-native",
  preflight_result = readiness_result,
  artifact_root = ".testing/runs/" .. host_run_key,
  source_ref = { kind = "host-module", ref = host_module_name },
  trace_id = host_trace_id,
  dedup_key = host_run_key,
}

-- 3. Generic consumers read the final handoff event.
-- queue: test-publication.publication_request
-- payload schema: test-publication.publication-request.v1
```

For multi-module flows, a host may pass module result pointers to `platform-test-loop.aggregate.v1`; the aggregate keeps per-module status/pointers and derives a platform status of `planned`, `passed`, `failed`, `blocked`, or `mixed`.

### No-browser native constraints

The executable native paths are intentionally narrow: module UI-loop requests use bounded `ui_loop`, `module_discovery`, and `cdp_execution` facts; module no-browser requests run with `dry_run = false`, `no_browser = true`, and bounded `native_argv`; module browser requests run with `dry_run = false`, `e2e_driver`, and bounded `native_argv`. Missing module `native_argv` returns `planned`; `native_argv` targeting the legacy `agentic-testing` CLI or host wrapper returns `blocked`; `agentic_testing_repo_root` is not an active field. Online regression supports native no-browser HTTP heartbeat only when `heartbeat_url` is present. Other unsupported native live paths return `blocked` and must not fall back to legacy code.

### Minimal downstream consumption

Publishers should consume `test-publication.publication-request.v1`; aggregators may consume `test-artifacts.summary.v1`. Minimal generic consumers need only `schema`, `status`, `job`, `artifact_root`, `metadata_path`, `source_ref`, `trace_id`, and `dedup_key`. `native_summary` is optional diagnostics and must not be required by generic consumers. Downstream/product-specific profiles, module sets, browser roles, URLs, environment names, and publication policies belong in host repositories.

`trace_id` groups one logical testing flow. Downstream publishers should treat `(publication_kind, channel, dedup_key)` as the idempotency key; replaying the same artifact summary must produce the same publication request.

## Build / test

Configure a local `fkst-framework` binary:

```sh
cp env.example .env
$EDITOR .env
```

Set `BIN` to a built `fkst-framework`, then run package verification:

```sh
scripts/run.sh check
scripts/run.sh test
scripts/run.sh ai-pipeline-smoke
scripts/run.sh test testing-runner
```

Every `check`, `test`, `host`, and `supervise` launch verifies the selected `fkst-framework` build-time
source pin against `.fkst/substrate-ref` before executing runtime work. A mismatched explicit `BIN` or
`.fkst/env` entry fails closed. Stale PATH and sibling-checkout binaries are skipped without modifying
their source trees, then the exact content-addressed pinned binary is reused or built. Startup prints
the expected and observed full pin, selected binary, and normalized `ENGINE_VER` invariant.

`scripts/run.sh test` writes a canonical Lua coverage artifact to `.fkst/run/lua-coverage/coverage.json`
and enforces the shrink-only `migration/coverage-uncovered.allowlist` ratchet during full-repository
runs. `scripts/run.sh ai-pipeline-smoke` is a hermetic smoke for the AI-authored test case path:
AI authoring, consensus review, pointer-only resume, CDP execution handoff, and publication handoff.
CI uploads the canonical coverage artifact and any `.testing/runs/**` smoke artifacts when a run
finishes, including failed runs.

To verify the live local-browser runtime path, start a local app and a Chrome/Chromium instance with
remote debugging, then run:

```sh
FKST_LIVE_BASE_URL=http://127.0.0.1:8317 \
FKST_LIVE_CDP_URL=http://127.0.0.1:9222 \
scripts/run.sh live-cdp-smoke
```

The repository host topology is separate from package verification. It loads the pinned `fkst-packages` development control plane and defaults `FKST_WORKFLOW_CATALOG_ROOT` to `.fkst/workflow`:

```sh
scripts/run.sh host -- check
scripts/run.sh host -- test
scripts/run.sh host -- supervise --durable-root "$FKST_DURABLE_ROOT" --restart
```

CI builds `fkst-framework` from the full SHA in `.fkst/substrate-ref` and runs host-topology
verification, package verification, Lua coverage ratchet enforcement, and the hermetic AI pipeline
smoke. The live CDP smoke is intentionally local/environment-gated because it requires a running
loopback app and browser debugging endpoint. A separate manual `live-cdp-smoke` GitHub Actions
workflow starts a loopback fixture app and Chrome CDP on the runner, then uploads the resulting
`.testing/runs/**` artifacts.

## Runtime posture

Testing packages are dry-run by default. Runner packages must not store credentials, cookies, tokens, browser storage, test account passwords, media bytes, or raw provider responses in fkst events. Payloads carry small control fields and stable artifact pointers; consumers fetch large reports from the referenced source.

⟦AI:FKST⟧
