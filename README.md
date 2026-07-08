# fkst-packages-testing

Testing and QA building-block packages for the **fkst** ecosystem.

This repository is intentionally separate from [`fkst-packages`](https://github.com/ChronoAIProject/fkst-packages). It owns the testing / QA domain boundary: test runner orchestration, browser readiness, testing artifact contracts, publication handoff, module and platform test-loop lifecycle, and online regression entry points.

The runtime adapter is FKST-native by default. The old `agentic-testing` Python CLI and host wrapper are no longer executable backends; legacy requests are blocked rather than silently falling back.

This repository contains no engine Rust and no host application state.

## Package catalog

| Package | Shape | What it does | Status |
| --- | --- | --- | --- |
| `testing-runner` | flat adapter | Runs configured testing jobs through the FKST-native runtime boundary and emits normalized testing result payloads; legacy `agentic-testing` requests are blocked. | migrating |
| `browser-readiness` | flat adapter | Checks local browser-harness/CDP/base URL readiness and can carry bounded execution context through the readiness gate. | migrating |
| `test-artifacts` | flat library package | Defines the normalized `.testing` artifact summary contract. | skeleton |
| `test-publication` | flat adapter | Converts testing publication handoff artifacts into publication requests, intended to compose with `github-proxy`. | skeleton |
| `testing-pipeline` | composed lifecycle | Composes module loop, runner, artifact summary, and publication handoff for graph-level testing flows. | skeleton |
| `testing-discovery` | composed lifecycle | Converts bounded local app-scope observations into FKST-native module starts without a hand-authored product module catalog. | experimental |
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

Set `BIN` to a built `fkst-framework`, then run:

```sh
scripts/run.sh check
scripts/run.sh test
scripts/run.sh test testing-runner
```

CI builds `fkst-framework` from `fkst-substrate` pinned by `.fkst-substrate-ref` and runs `scripts/run.sh check && scripts/run.sh test`.

## Runtime posture

Testing packages are dry-run by default. Runner packages must not store credentials, cookies, tokens, browser storage, test account passwords, media bytes, or raw provider responses in fkst events. Payloads carry small control fields and stable artifact pointers; consumers fetch large reports from the referenced source.

⟦AI:FKST⟧
