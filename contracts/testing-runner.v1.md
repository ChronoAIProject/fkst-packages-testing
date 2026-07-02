# testing-runner.v1

`testing-runner` is the adapter boundary between fkst testing events and concrete testing execution backends.

## Request queues

- `testing-runner.module_test_request`
  - `schema`: `testing-runner.module-test-loop.request.v1`
  - required: `module`
  - optional: `backend`, `config`, `e2e_driver`, `no_browser`, `dry_run`, `dry_run_github`, `native_argv`, `module_ui_loop`, `preflight_result`, `artifact_root`, `agentic_testing_repo_root`, `source_ref`, `trace_id`, `dedup_key`
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

`artifact_root`, when provided, must be a safe relative path under `.testing/runs/...`; paths outside that prefix, parent traversal, NUL bytes, or empty values are malformed. If omitted, the runner derives a safe `.testing/runs/...` pointer from request identity fields.

`trace_id` and `dedup_key`, when provided, must be bounded strings. `trace_id` identifies one logical testing trace across runner, artifacts, and publication. `dedup_key` is the stable idempotency key that downstream write boundaries can use to collapse replays. If omitted, packages derive deterministic generic values from stable source/artifact fields; timestamps, randomness, product names, and host-specific defaults must not be used.

## Native module UI loop request

`module_ui_loop` is the FKST-native module UI loop contract envelope on module requests. It is valid only with `backend = "fkst-native"` and schema `testing-runner.module-ui-loop.request.v1`.

Required fields:

- `base_url`: host-provided `http` or `https` URL.
- `allowed_origins`: non-empty dense list of HTTP origins, including the `base_url` origin.
- `readiness_ref`: small browser readiness reference, normally `browser-readiness.result.v1`, with required `status`.
- `artifact_root`: safe `.testing/runs/...` root for this loop.
- `dry_run`: boolean host mode.
- `priority`: non-empty dense list using `P0`, `P1`, and `P2`.
- `mutation_policy`: one of `read_only`, `dry_run_only`, or `allow_safe`.

Optional fields:

- `artifact_pointers`: safe `.testing/runs/...` pointers such as evidence indexes.
- `gap_pointers`: safe `.testing/runs/...` pointers for backlog/gap artifacts.

The first native module UI loop slice is contract-only. It validates and classifies the request, writes native metadata, and returns `planned` or `blocked`; it does not perform discovery, browser exploration, evidence capture, safe mutation, or report generation. Runtime inputs must be local before browser exploration: non-local `base_url` or non-local `allowed_origins` return a normalized `blocked` result with classification `blocked_unsafe_input`. Non-ready readiness returns `blocked_readiness`. Dry-run mode returns `planned` with classification `degraded_dry_run`. A ready, local, non-dry-run contract returns `planned` with classification `gap_backlog` and gap pointers for later slices to populate.

Classification vocabulary for `testing-runner.module-ui-loop-summary.v1` is `planned`, `blocked_unsafe_input`, `blocked_readiness`, `blocked_legacy_cli`, `degraded_dry_run`, and `gap_backlog`.

## Result queue

All request types emit `testing-runner.testing_result` with:

- `schema`: `testing-runner.result.v1`
- `job`: `module-test-loop`, `platform-test-loop`, or `online-regression`
- `status`: `planned`, `passed`, `failed`, or `blocked`
- `artifact_root`: stable pointer under `.testing/runs/...`
- `source_ref`: bounded source reference
- `trace_id`: bounded logical trace identifier
- `dedup_key`: bounded stable idempotency key
- `adapter`: bounded adapter metadata, including `name`; `agentic-testing-cli` may include `command`, while `fkst-native` uses small capability/mode fields instead.

`fkst-native` writes `.testing/runs/.../metadata.json` with schema `testing-runner.native-metadata.v1` for native results. Metadata includes `job`, `status`, `artifact_root`, `source_ref`, `trace_id`, `dedup_key`, bounded `adapter` metadata, and optional `native_summary`. Artifact write failure must return a `blocked` result with an `artifact write failed` stderr excerpt.

`fkst-native` metadata may include `native_summary` for implemented native paths. Online heartbeat summaries use `testing-runner.online-heartbeat-summary.v1`, include only small status fields and a sanitized `target` without query or fragment text. Module no-browser summaries use `testing-runner.module-no-browser-summary.v1`, include only the module name, mode, and status. Browser driver summaries use `testing-runner.browser-driver-summary.v1`, include only module, driver, mode, status, and optional bounded readiness audit fields (`status` plus per-session role/status). Module UI loop summaries use `testing-runner.module-ui-loop-summary.v1`, include only module, status, classification, mode, optional bounded readiness audit fields, and `.testing/runs/...` artifact/gap pointers. Missing browser `native_argv` produces a `planned` readiness-gated plan; provided browser `native_argv` runs directly through `fkst-native` and maps exit code `0` to `passed`, non-zero/unavailable execution to `failed`.

For module no-browser native execution, the executable path is intentionally narrow: `backend = "fkst-native"`, `dry_run = false`, `no_browser = true`, a module request, and bounded `native_argv`. Exit code `0` maps to `passed`; any non-zero, missing, or unavailable execution result maps to `failed` with a bounded `stderr_excerpt`. A native module request with `no_browser = true` and no `native_argv` returns `planned` instead of executing. A `native_argv` targeting `agentic_testing.cli` returns `blocked` before execution.

For native browser driver execution, the executable path is intentionally host-supplied and bounded: `backend = "fkst-native"`, `dry_run = false`, a module request, `e2e_driver`, and bounded `native_argv`. Readiness details are copied only as a small audit summary. Missing browser `native_argv` returns `planned`; a `native_argv` targeting `agentic_testing.cli` returns `blocked` before execution.

For online regression, native no-browser execution is only the HTTP heartbeat path with `heartbeat_url`; unsupported native live paths return `blocked` and must not fall back to the legacy CLI.

`fkst-native` must not construct or invoke `agentic_testing.cli`. `agentic_testing_repo_root` is ignored by `fkst-native` and remains legacy-only for `agentic-testing-cli`.

Payloads must carry small control fields and artifact pointers only; large report bodies, browser storage, credentials, cookies, and tokens stay outside fkst events.
