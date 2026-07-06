# testing-runner.v1

`testing-runner` is the adapter boundary between fkst testing events and concrete testing execution backends.

## Request queues

- `testing-runner.module_test_request`
  - `schema`: `testing-runner.module-test-loop.request.v1`
  - required: `module`
  - optional: `backend`, `config`, `e2e_driver`, `no_browser`, `dry_run`, `dry_run_github`, `native_argv`, `ui_loop`, `module_discovery`, `preflight_result`, `artifact_root`, `agentic_testing_repo_root`, `source_ref`, `trace_id`, `dedup_key`
- `testing-runner.platform_test_request`
  - `schema`: `testing-runner.platform-test-loop.request.v1`
  - optional: `backend`, `modules`, `priority`, `config`, `e2e_driver`, `no_browser`, `dry_run`, `dry_run_github`, `preflight_result`, `artifact_root`, `agentic_testing_repo_root`, `source_ref`, `trace_id`, `dedup_key`
- `testing-runner.online_regression_request`
  - `schema`: `testing-runner.online-regression.request.v1`
  - optional: `backend`, `config`, `driver`, `heartbeat_url`, `final_summary`, `no_browser`, `dry_run`, `dry_run_github`, `preflight_result`, `artifact_root`, `agentic_testing_repo_root`, `source_ref`, `trace_id`, `dedup_key`

`backend` may be `fkst-native` or `agentic-testing-cli`. Omitted `backend` currently preserves legacy compatibility and resolves to `agentic-testing-cli`; production profiles should pass `fkst-native` when they want the final fkst-native execution path. `agentic_testing_repo_root` is legacy-only for `agentic-testing-cli` and must be ignored by `fkst-native`.

`preflight_result` is optional small status metadata from an upstream readiness gate. For `fkst-native`, any provided preflight status other than `ready` must return `blocked` before native execution planning; the legacy CLI backend ignores this field.

When `preflight_result` comes from `browser-readiness.result.v1`, it may include a bounded `request_context` copied from the original readiness check. This context is only for restoring host-provided execution intent after readiness gating. Supported fields are `native_argv`, `dry_run`, and `no_browser`; unknown fields must be rejected by the readiness package. `request_context` must remain small control metadata and must not carry reports, evidence bodies, browser state, credentials, cookies, or tokens.

`native_argv` is optional for module requests only and is a bounded argument vector for native module execution. It is ignored by the legacy CLI backend. When present with `backend = "fkst-native"`, `dry_run = false`, and either `no_browser = true` or `e2e_driver` is present, it may be executed directly by the native adapter without constructing `agentic_testing.cli`.

`ui_loop` is optional for module requests only and is the FKST-native module UI loop control envelope. It may contain only small control fields: required `base_url` and non-empty `allowed_origins`; optional `browser_readiness_ref`, `cdp_readiness_ref`, `artifact_root`, `dry_run`, `priority`, `mutation_policy`, `gap_ref`, and `backlog_ref`. `allowed_origins` and `priority` are dense bounded lists of at most 16 items. `mutation_policy` is `read-only`, `dry-run`, or `host-approved`. Pointer fields must be bounded strings and `artifact_root`, when present inside `ui_loop`, must also be a safe `.testing/runs/...` path. Unknown `ui_loop` fields are malformed; inline screenshots, traces, browser storage, credentials, cookies, tokens, report bodies, or browser state must not be accepted.

`module_discovery` is optional for module requests only and uses `testing-runner.module-discovery.v1`. It requires the existing `ui_loop` scope for `base_url` and `allowed_origins`; it must not redefine runtime scope. It may contain optional bounded `observations` and `limitations`. Observations are host-supplied deterministic route, navigation, or accessibility-visible discoveries with bounded `id`/`name`, `entry_url`, visible label or route, discovery source, confidence, and `evidence_pointer`. Unknown fields and inline browser state, screenshots, traces, credentials, cookies, tokens, or report bodies are malformed.

`artifact_root`, when provided, must be a safe relative path under `.testing/runs/...`; paths outside that prefix, parent traversal, NUL bytes, or empty values are malformed. If omitted, the runner derives a safe `.testing/runs/...` pointer from request identity fields.

`trace_id` and `dedup_key`, when provided, must be bounded strings. `trace_id` identifies one logical testing trace across runner, artifacts, and publication. `dedup_key` is the stable idempotency key that downstream write boundaries can use to collapse replays. If omitted, packages derive deterministic generic values from stable source/artifact fields; timestamps, randomness, product names, and host-specific defaults must not be used.

## Host-owned native module profiles

A native module profile is downstream-owned configuration, not a new fkst event schema. A host profile may translate each module entry into the existing readiness and module-start events with these neutral fields:

- `module`: bounded logical module identifier.
- `native_argv`: dense non-empty argv list of bounded strings.
- `artifact_root`: safe `.testing/runs/...` path for that module's result metadata.
- `trace_id`: bounded logical trace identifier.
- `dedup_key`: bounded stable idempotency key for that module handoff.
- `source_ref`: optional bounded source reference; generic examples default to `{ kind = "host-module", ref = module }`.

The executable no-browser posture is `backend = "fkst-native"`, `dry_run = false`, and `no_browser = true`. If readiness gating is used, `browser-readiness.result.v1.request_context` may carry only `native_argv`, `dry_run`, and `no_browser`; later lifecycle packages restore those fields from the preflight result. Product module names, product URLs, host environment variable names, credentials, browser state, large reports, and publication destinations belong in the downstream host repository, not in this package set.

## Result queue

All request types emit `testing-runner.testing_result` with:

- `schema`: `testing-runner.result.v1`
- `job`: `module-test-loop`, `platform-test-loop`, or `online-regression`
- `status`: `planned`, `passed`, `failed`, `blocked`, or `degraded`
- `artifact_root`: stable pointer under `.testing/runs/...`
- `source_ref`: bounded source reference
- `trace_id`: bounded logical trace identifier
- `dedup_key`: bounded stable idempotency key
- `adapter`: bounded adapter metadata, including `name`; `agentic-testing-cli` may include `command`, while `fkst-native` uses small capability/mode fields instead.

`fkst-native` writes `.testing/runs/.../metadata.json` with schema `testing-runner.native-metadata.v1` for native results. Metadata includes `job`, `status`, `artifact_root`, `source_ref`, `trace_id`, `dedup_key`, bounded `adapter` metadata, and optional `native_summary`. Artifact write failure must return a `blocked` result with an `artifact write failed` stderr excerpt.

`fkst-native` metadata may include `native_summary` for implemented native paths. Online heartbeat summaries use `testing-runner.online-heartbeat-summary.v1`, include only small status fields and a sanitized `target` without query or fragment text. Module no-browser summaries use `testing-runner.module-no-browser-summary.v1`, include only the module name, mode, and status. Module UI loop summaries use `testing-runner.module-ui-loop-summary.v1`, include only module, status, classification, mode, `artifact_root`, `metadata_path`, and optional bounded `gap_ref`/`backlog_ref`; they must not embed screenshots, traces, browser state, credentials, cookies, tokens, or inline report data. Module inventory summaries use `testing-runner.module-inventory-summary.v1`, include only module, status, discovery status, `artifact_root`, `inventory_path`, optional `feature_inventory_path`/`test_plan_path`/`plan_status`, `module_count`, and `coverage`; detailed module inventory, feature inventory, test plan cases, and evidence pointers stay in `<artifact_root>/module-inventory.json`, `<artifact_root>/feature-inventory.json`, and `<artifact_root>/test-plan.json`. Browser driver summaries use `testing-runner.browser-driver-summary.v1`, include only module, driver, mode, status, and optional bounded readiness audit fields (`status` plus per-session role/status). Missing browser `native_argv` produces a `planned` readiness-gated plan; provided browser `native_argv` runs directly through `fkst-native` and maps exit code `0` to `passed`, non-zero/unavailable execution to `failed`.

For module no-browser native execution, the executable path is intentionally narrow: `backend = "fkst-native"`, `dry_run = false`, `no_browser = true`, a module request, and bounded `native_argv`. Exit code `0` maps to `passed`; any non-zero, missing, or unavailable execution result maps to `failed` with a bounded `stderr_excerpt`. A native module request with `no_browser = true` and no `native_argv` returns `planned` instead of executing. A `native_argv` targeting `agentic_testing.cli` returns `blocked` before execution.

For native module UI loop requests, the current FKST-native path accepts the contract envelope but does not run browser exploration in this slice. With `backend = "fkst-native"`, `dry_run = false`, a module request, and `ui_loop`, unsafe runtime input returns a normal `blocked` runner result before exploration. Runtime input is unsafe when `base_url` is not local HTTP or the exact origin is not present in `allowed_origins`. Safe runtime input returns `degraded` with adapter mode `module-ui-loop-contract`, classification `browser-exploration-deferred`, and `testing-runner.module-ui-loop-summary.v1` metadata. Unsafe runtime input returns `blocked` with adapter mode `module-ui-loop-blocked`, classification `unsafe-runtime-input`, and the same pointer-only summary shape. A `native_argv` targeting `agentic_testing.cli` returns `blocked` before any UI loop handling; the native UI loop path must not fall back to the legacy CLI.

When `module_discovery` is present, `fkst-native` writes `<artifact_root>/module-inventory.json` with schema `testing-runner.module-inventory.v1` before writing metadata. The inventory records `artifact_kind = "module-inventory"`, sanitized `base_url`, `allowed_origins`, accepted modules, `module_count`, limitations, readiness audit, and provenance. Each accepted module includes `id`, `name`, sanitized `entry_url`, visible label or route, `discovery_source`, `confidence`, and `evidence_pointer`. Discovery is deterministic and bounded to configured `ui_loop` scope; URL query and fragment details are stripped from persisted inventory URLs. Missing or blocked readiness produces a blocked/degraded runner result and degraded inventory rather than a product defect.

The same native module discovery path writes `<artifact_root>/feature-inventory.json` with schema `testing-runner.feature-inventory.v1` and `<artifact_root>/test-plan.json` with schema `testing-runner.module-test-plan.v1`. Feature inventory is derived only from accepted module inventory entries and records bounded feature signals plus evidence pointers. The test plan contains P0 entry-health cases for reachability, page loading, key visible elements, and obvious console/network health; P1 low-risk interaction cases for navigation, search/filtering, and opening details when visible; and P2 mutation/edge/negative cases as planned work. The review gate marks cases `executable`, `blocked`, or `not-executed-risk` with bounded reasons, using `ui_loop.mutation_policy` to keep write/state-change flows non-executable unless host-approved fixtures exist. The native summary remains pointer-only and must not embed module lists, feature inventory bodies, test cases, screenshots, traces, browser state, credentials, cookies, tokens, or report bodies.

For native browser driver execution, the executable path is intentionally host-supplied and bounded: `backend = "fkst-native"`, `dry_run = false`, a module request, `e2e_driver`, and bounded `native_argv`. Readiness details are copied only as a small audit summary. Missing browser `native_argv` returns `planned`; a `native_argv` targeting `agentic_testing.cli` returns `blocked` before execution.

For online regression, native no-browser execution is only the HTTP heartbeat path with `heartbeat_url`; unsupported native live paths return `blocked` and must not fall back to the legacy CLI.

`fkst-native` must not construct or invoke `agentic_testing.cli`. `agentic_testing_repo_root` is ignored by `fkst-native` and remains legacy-only for `agentic-testing-cli`.

Payloads must carry small control fields and artifact pointers only; large report bodies, browser storage, credentials, cookies, and tokens stay outside fkst events.
