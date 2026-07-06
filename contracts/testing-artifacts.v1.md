# testing-artifacts.v1

Testing packages exchange artifact pointers, not report bodies.

## Artifact summary

`test-artifacts.artifact_summary` uses `test-artifacts.summary.v1`:

- `job`: logical testing job name
- `status`: `planned`, `passed`, `failed`, `blocked`, `degraded`, or `mixed`
- `artifact_root`: stable local or handoff pointer, usually `.testing/runs/<run>`
- `metadata_path`: optional pointer to runner metadata, normally `<artifact_root>/metadata.json`
- `source_ref`: optional bounded source reference
- `trace_id`: bounded logical trace identifier, preserved from runner result or deterministically derived
- `dedup_key`: bounded stable idempotency key, preserved from runner result or deterministically derived
- `adapter`: optional bounded adapter metadata from the runner result
- `native_summary`: optional bounded native summary from the runner result
- `exit_code`: optional numeric process exit code
- `stderr_excerpt`: optional bounded error excerpt

Artifact summaries must carry small control metadata and pointers only. They must not embed report bodies, raw stdout/stderr bodies, screenshots, traces, browser storage, credentials, cookies, or tokens.

`native_summary` is diagnostic metadata, not a downstream consumption requirement. Accepted nested native summaries are bounded `testing-runner.module-no-browser-summary.v1`, `testing-runner.module-ui-loop-summary.v1`, `testing-runner.module-inventory-summary.v1`, `testing-runner.online-heartbeat-summary.v1`, and `testing-runner.browser-driver-summary.v1` payloads. Module UI loop summaries may include only `schema`, `module`, `status`, `classification`, `mode`, `artifact_root`, `metadata_path`, and optional bounded `gap_ref`/`backlog_ref`; `metadata_path` must equal `<artifact_root>/metadata.json`. Module inventory summaries may include only `schema`, `module`, `status`, `discovery_status`, `artifact_root`, `inventory_path`, optional `feature_inventory_path`/`test_plan_path`/`plan_status`, `module_count`, and `coverage`; artifact paths must equal `<artifact_root>/module-inventory.json`, `<artifact_root>/feature-inventory.json`, and `<artifact_root>/test-plan.json`, and detailed module lists, feature inventory, test cases, and evidence stay in those artifact files. Browser driver summaries may include only a readiness audit: `readiness.status` plus up to 16 session `{ role, status }` entries. Readiness `checks`, report bodies, module inventories, feature inventories, test plans, browser state, credentials, cookies, tokens, screenshots, traces, and arbitrary nested trees must be rejected.

## Publication handoff

`test-publication.publication_request` uses `test-publication.publication-request.v1` and forwards only stable notification fields and artifact pointers needed by a host publisher:

- `publication_kind`: `testing-summary`
- `channel`: `testing`
- `severity`: `success`, `failure`, `warning`, or `info`, derived from summary `status`
- `subject`: bounded one-line human-readable subject
- `trace_id`: bounded logical trace identifier from the artifact summary
- `dedup_key`: bounded stable key for host-side notification de-duplication
- `status`: summary status
- `job`: logical testing job name
- `artifact_root`: stable `.testing/runs/...` pointer
- `metadata_path`: optional metadata pointer, normally `<artifact_root>/metadata.json`
- `source_ref`: bounded source reference

Publication requests are handoff payloads only. They must not embed report bodies, raw stdout/stderr bodies, screenshots, traces, browser storage, credentials, cookies, or tokens.

## Generic downstream minimum

Downstream publishers should consume `test-publication.publication-request.v1`. Downstream aggregators may consume `test-artifacts.summary.v1` when they need pre-publication rollups. Minimal generic consumers only need `schema`, `status`, `job`, `artifact_root`, `metadata_path`, `source_ref`, `trace_id`, and `dedup_key`.

`adapter` and `native_summary` are optional diagnostics. Generic consumers must not require product-specific modules, browser roles, URLs, environment variable names, or publication destinations from this repository; those policies belong in host repositories.

## Trace and idempotency

`trace_id` groups runner, artifact, and publication payloads for one logical testing flow. `dedup_key` identifies the replay-safe write boundary event. If a host does not supply either field, packages derive deterministic generic values from stable source/artifact fields.

Downstream publishers should treat `(publication_kind, channel, dedup_key)` as the idempotency key. Replaying the same artifact summary must produce the same publication request. The same `trace_id` with different `dedup_key` values means separate publication events within one logical trace. Duplicate handling for the same `dedup_key`—update, replace, or ignore—is a host write-boundary policy.
