# testing-discovery.v1

`testing-discovery` is a generic FKST-native discovery lifecycle. A downstream host supplies local scope and policy plus bounded AI/browser/navigation/accessibility observations; this package derives module starts and feeds the existing readiness, runner, artifact, and publication pipeline.

It must not encode product modules, product URLs, credentials, browser storage, or application defaults.

## Input queue

- `testing-discovery.app_scope`
  - `schema`: `testing-discovery.app-scope.v1`
  - required: `base_url`, `allowed_origins`, `sessions`, `observations`, `artifact_root`
  - optional: `mutation_policy`, `budgets`, `source_ref`, `trace_id`, `dedup_key`

`base_url` must be local HTTP only: `localhost`, `127.0.0.1`, or `[::1]`. Query strings and fragments are stripped before downstream emission. `allowed_origins` must be a bounded dense list of local HTTP origins and must include the base URL origin.

`sessions` use the existing browser-readiness session shape: bounded `role` plus one readiness source such as `browser_harness_command`, `browser_harness_command_env`, `cdp_endpoint_env`, or local `cdp_url`.

`observations` are bounded facts, not test cases or report bodies. Each accepted observation may contain only `id`, `name`, `entry_url`, `route`, `visible_label`, `discovery_source` or `source`, `confidence`, and `evidence_pointer`. Supported sources are `route`, `route-manifest`, `navigation`, `nav-link`, `accessibility`, `a11y-visible`, `browser`, and `browser-visible`. Observations outside the base scope or allowed origins, or without evidence pointers, are omitted from the plan.

`mutation_policy` defaults to `read-only` and may be `read-only`, `dry-run`, or `host-approved`. The policy is passed through to the runner; it does not authorize unsafe mutation by itself.

`budgets` may include:

- `module_limit`: integer 1-64, default 16.
- `observation_limit`: integer 1-64, default 64.
- `step_budget`: integer 1-32, default 8.
- `case_priorities`: dense list of `P0`, `P1`, `P2`, default `P0`/`P1`.

## Plan artifact

`testing-discovery.plan.v1` is written to:

```text
<artifact_root>/testing-discovery-plan.json
```

The plan contains sanitized scope, accepted modules, accepted observations, rejected counts, limitations, trace/dedup fields, and artifact pointers only. If no observation is accepted, the package emits an `app-discovery` gap module so downstream artifacts record the harness gap instead of silently doing nothing.

## Emitted events

`testing-discovery.start` emits:

- queue: `browser-readiness.browser_readiness_check`
- payload schema: `browser-readiness.check.v1`
- `source_ref = { kind = "testing-discovery-plan", ref = artifact_root }`

The readiness `request_context` remains limited to fields accepted by `browser-readiness`; discovery plans or observation bodies are not stored there.

`testing-discovery.emit_modules` consumes `browser-readiness.browser_readiness_result` only when its source reference points to a discovery plan, reads the plan artifact, and emits one event per discovered module:

- queue: `module-testing-pipeline.module_start`
- payload schema: `module-testing-pipeline.module-start.v1`
- `backend = "fkst-native"`
- `preflight_result` copied from readiness
- `ui_loop` with base scope, allowed origins, readiness pointers, and mutation policy
- `module_discovery` with bounded observations using `testing-runner.module-discovery.v1`
- `cdp_execution` with bounded step budget and case priorities
- module-specific `artifact_root`, `source_ref`, `trace_id`, and `dedup_key`

## Guardrails

Events and plan artifacts must not contain screenshots, DOM bodies, traces, browser storage, cookies, credentials, raw model prompts/responses, or report bodies. Large evidence remains in downstream artifacts addressed by bounded pointers.

Discovery is local-scope only. Cross-origin, out-of-scope, query/fragment-specific, or evidence-free observations are rejected or omitted with limitations. Blocked readiness flows through as an environment/session issue in the existing runner path, not as a product-defect claim.
