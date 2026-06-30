# fkst-packages-testing

Testing and QA building-block packages for the **fkst** ecosystem.

This repository is intentionally separate from [`fkst-packages`](https://github.com/ChronoAIProject/fkst-packages). It owns the testing / QA domain boundary: test runner orchestration, browser readiness, testing artifact contracts, publication handoff, module and platform test-loop lifecycle, and online regression entry points.

The initial runtime adapter invokes the existing [`ChronoAIProject/agentic-testing`](https://github.com/ChronoAIProject/agentic-testing) Python CLI and consumes its `.testing` artifact contract. Packages are structured around the long-term fkst-native testing domain so adapter-backed behavior can be replaced incrementally without changing queue contracts.

This repository contains no engine Rust and no host application state.

## Package catalog

| Package | Shape | What it does | Status |
| --- | --- | --- | --- |
| `testing-runner` | flat adapter | Runs configured testing jobs through the initial `agentic-testing-cli` adapter and emits normalized testing result payloads. | seed |
| `browser-readiness` | flat adapter | Defines browser-harness/CDP readiness contracts for local browser E2E sessions. | skeleton |
| `test-artifacts` | flat library package | Defines the normalized `.testing` artifact summary contract. | skeleton |
| `test-publication` | flat adapter | Converts testing publication handoff artifacts into publication requests, intended to compose with `github-proxy`. | skeleton |
| `module-test-loop` | composed lifecycle | Module-level testing lifecycle orchestration. Initially delegates to `testing-runner`. | skeleton |
| `platform-test-loop` | composed lifecycle | Platform-level multi-module testing lifecycle orchestration. Initially delegates to `module-test-loop` / `testing-runner`. | skeleton |
| `online-regression` | flat adapter | Online regression / heartbeat entry point. Initially delegates to `testing-runner`. | skeleton |
| `ornn-testing-profile` | profile package | Ornn-specific testing profile and local safety defaults. | skeleton |

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
