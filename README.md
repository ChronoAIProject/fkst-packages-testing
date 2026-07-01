# fkst-packages-testing

Testing and QA building-block packages for the **fkst** ecosystem.

This repository is intentionally separate from [`fkst-packages`](https://github.com/ChronoAIProject/fkst-packages). It owns the testing / QA domain boundary: test runner orchestration, browser readiness, testing artifact contracts, publication handoff, module and platform test-loop lifecycle, and online regression entry points.

The runtime adapter now has an explicit `fkst-native` backend alongside the legacy [`ChronoAIProject/agentic-testing`](https://github.com/ChronoAIProject/agentic-testing) Python CLI compatibility backend. Native coverage is being expanded incrementally without changing queue contracts; unsupported native live paths return `blocked` rather than falling back to the legacy CLI.

This repository contains no engine Rust and no host application state.

## Package catalog

| Package | Shape | What it does | Status |
| --- | --- | --- | --- |
| `testing-runner` | flat adapter | Runs configured testing jobs through `fkst-native` or the legacy `agentic-testing-cli` backend and emits normalized testing result payloads. | migrating |
| `browser-readiness` | flat adapter | Checks local browser-harness/CDP/base URL readiness and can carry bounded execution context through the readiness gate. | migrating |
| `test-artifacts` | flat library package | Defines the normalized `.testing` artifact summary contract. | skeleton |
| `test-publication` | flat adapter | Converts testing publication handoff artifacts into publication requests, intended to compose with `github-proxy`. | skeleton |
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
libraries/
  contract/ workflow/ testkit/
```

## Downstream usage

Host repositories compose these packages and provide their own app-specific defaults. This repository should not encode product modules, fixed base URLs, browser roles, or environment variable names.

A typical host flow is:

1. Produce a `browser-readiness.check.v1` request with host-provided sessions, local base URL, and optional bounded `request_context`.
2. Feed the `browser-readiness.result.v1` into a `module-test-loop.start.v1` request.
3. Let `module-test-loop` emit `testing-runner.module-test-loop.request.v1`.
4. Run it through `testing-runner` with `backend = "fkst-native"` or the legacy `agentic-testing-cli` backend.

Product-specific profiles belong in the downstream host repository. This repository only provides reusable testing/QA building blocks and neutral contracts.

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
