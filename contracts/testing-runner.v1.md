# testing-runner.v1

`testing-runner` is the adapter boundary between fkst testing events and concrete testing execution backends.

## Request queues

- `testing-runner.module_test_request`
  - `schema`: `testing-runner.module-test-loop.request.v1`
  - required: `module`
  - optional: `backend`, `config`, `e2e_driver`, `no_browser`, `dry_run`, `dry_run_github`, `native_argv`, `preflight_result`, `artifact_root`, `agentic_testing_repo_root`, `source_ref`
- `testing-runner.platform_test_request`
  - `schema`: `testing-runner.platform-test-loop.request.v1`
  - optional: `backend`, `modules`, `priority`, `config`, `e2e_driver`, `no_browser`, `dry_run`, `dry_run_github`, `preflight_result`, `artifact_root`, `agentic_testing_repo_root`, `source_ref`
- `testing-runner.online_regression_request`
  - `schema`: `testing-runner.online-regression.request.v1`
  - optional: `backend`, `config`, `driver`, `heartbeat_url`, `final_summary`, `no_browser`, `dry_run`, `dry_run_github`, `preflight_result`, `artifact_root`, `agentic_testing_repo_root`, `source_ref`

`backend` may be `fkst-native` or `agentic-testing-cli`. Omitted `backend` currently preserves legacy compatibility and resolves to `agentic-testing-cli`; production profiles should pass `fkst-native` when they want the final fkst-native execution path. `agentic_testing_repo_root` is legacy-only for `agentic-testing-cli` and must be ignored by `fkst-native`.

`preflight_result` is optional small status metadata from an upstream readiness gate. For `fkst-native`, any provided preflight status other than `ready` must return `blocked` before native execution planning; the legacy CLI backend ignores this field.

When `preflight_result` comes from `browser-readiness.result.v1`, it may include a bounded `request_context` copied from the original readiness check. This context is only for restoring host-provided execution intent after readiness gating. Supported fields are `native_argv`, `dry_run`, and `no_browser`; unknown fields must be rejected by the readiness package. `request_context` must remain small control metadata and must not carry reports, evidence bodies, browser state, credentials, cookies, or tokens.

`native_argv` is optional for module requests only and is a bounded argument vector for the first no-browser fkst-native execution path. It is ignored by the legacy CLI backend. When present with `backend = "fkst-native"`, `dry_run = false`, and `no_browser = true`, it may be executed directly by the native adapter without constructing `agentic_testing.cli`.

`artifact_root`, when provided, must be a safe relative path under `.testing/runs/...`; paths outside that prefix, parent traversal, NUL bytes, or empty values are malformed. If omitted, the runner derives a safe `.testing/runs/...` pointer from request identity fields.

## Result queue

All request types emit `testing-runner.testing_result` with:

- `schema`: `testing-runner.result.v1`
- `job`: `module-test-loop`, `platform-test-loop`, or `online-regression`
- `status`: `planned`, `passed`, `failed`, or `blocked`
- `artifact_root`: stable pointer under `.testing/runs/...`
- `source_ref`: bounded source reference
- `adapter`: bounded adapter metadata, including `name`; `agentic-testing-cli` may include `command`, while `fkst-native` uses small capability/mode fields instead.

`fkst-native` writes `.testing/runs/.../metadata.json` with schema `testing-runner.native-metadata.v1` for native results. Metadata includes `job`, `status`, `artifact_root`, `source_ref`, bounded `adapter` metadata, and optional `native_summary`. Artifact write failure must return a `blocked` result with an `artifact write failed` stderr excerpt.

`fkst-native` metadata may include `native_summary` for implemented native paths. Online heartbeat summaries use `testing-runner.online-heartbeat-summary.v1`, include only small status fields and a sanitized `target` without query or fragment text. Module no-browser summaries use `testing-runner.module-no-browser-summary.v1`, include only the module name, mode, and status. Browser driver envelopes use `testing-runner.browser-driver-summary.v1`, include only module, driver, mode, status, and optional bounded readiness audit fields (`status` plus per-session role/status), and remain `blocked` until native browser execution is implemented.

For module no-browser native execution, exit code `0` maps to `passed`; any non-zero, missing, or unavailable execution result maps to `failed` with a bounded `stderr_excerpt`. A native module request with `no_browser = true` and no `native_argv` returns `planned` instead of executing. A `native_argv` targeting `agentic_testing.cli` returns `blocked` before execution.

`fkst-native` must not construct or invoke `agentic_testing.cli`. Unsupported native live execution must return `blocked` rather than silently falling back to the legacy CLI.

Payloads must carry small control fields and artifact pointers only; large report bodies, browser storage, credentials, cookies, and tokens stay outside fkst events.
