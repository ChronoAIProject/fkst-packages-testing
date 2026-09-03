# Agentic browser execution v1

Agentic browser execution is a separate `testing-runner` path for one reviewed browser case and one exact ready CDP target. It does not modify or replace structured API/CLI execution.

The distinction is explicit:

- Deterministic mode executes an AI-authored, reviewed fixed plan of CLI and HTTP effects.
- Agentic mode asks AI to choose one selector-free typed browser action per turn while deterministic runner code remains the only effect authority and the only success authority.

## Public schemas and queue

- Request queue: `testing-runner.ai_browser_control_request`
- Request: `testing-runner.ai-browser-control.request.v1`
- Grant artifact: `testing-runner.ai-browser-control.grant.v1`
- Observation: `testing-runner.ai-browser-control.observation.v1`
- Candidate action: `testing-runner.ai-browser-control.action.v1`
- Step receipt: `testing-runner.ai-browser-control.step-receipt.v1`
- Terminal receipt: `testing-runner.ai-browser-control.receipt.v1`
- Result: normal `testing-runner.result.v1` with `job = "ai-browser-control"`

The pointer-only request binds the immutable repository commit, ready Environment Factory receipt digest, reviewed plan digest, browser grant digest, artifact root, source reference, trace ID, and dedup key. The reviewed `testing-structured-plan.v2` must declare `execution_mode = "agentic-browser"` and contain exactly one `kind = "browser"` case. Mixed browser, HTTP, and CLI execution is invalid.

## Browser grant

The host-authenticated, single-use browser grant binds:

- the exact parent preauthorization digest;
- immutable repository and reviewed plan digest;
- ready Environment Factory receipt digest;
- exact readiness attempt ID and digest;
- exact CDP target ID and digest;
- exact credential-free HTTPS authentication origins;
- one exact loopback HTTP callback origin and query-free path;
- allowed typed actions and approved opaque secret-reference names;
- step and wall-time budgets;
- authority and evidence references, policy revision, validity window, trace ID, dedup key, and `max_uses = 1`.

The runner authenticates the grant and atomically claims it before observation can lead to a browser effect. Completed claims return the prior summary without observing or acting again.

## Observation boundary

The Node runtime attaches only to the approved target ID. It never selects the first available page and never creates or navigates a target.

Each observation contains only:

- turn number, exact target ID, and a document token derived from target, time origin, sanitized origin, and path;
- sanitized origin and query-free path;
- document readiness;
- at most 32 visible controls with one-turn opaque handles, role, control kind, safe label, and focus state;
- callback, MFA, CAPTCHA, target-change, and popup signals;
- bounded console and network event counts.

The model and persisted receipts never receive selectors, DOM, HTML, form values, hidden values, storage, cookies, request or response bodies, userinfo, URL query or fragment text, account identifiers, high-entropy strings, or raw browser state. A changed document token, target, control fingerprint, or handle fails closed.

## Typed actions

The first release permits only:

- `click(handle)`
- `type(handle, secret_ref)`
- `submit(handle)`
- `press_tab`
- `finish(advisory_status)`

Unknown fields, literal secrets, selectors, arbitrary URLs, JavaScript, coordinates, arbitrary keys, stale handles, and unapproved secret refs are invalid. `finish` is advisory and performs no browser effect.

The portable Draft 2020-12 schema `testing-runner.ai-browser-control.action.v1` validates only this standalone wire structure and its per-kind argument rules. Contextual authorization against the caller's allowed actions and approved secret references remains authoritative in `contract.browser_control.validate_action`. Actions have no independent canonicalization or digest contract; any canonicalization is owned by the containing artifact contract.

Approved secret refs are resolved only by a host `exec_argv_with_secret_stdin` capability. The secret value travels over stdin to the runtime for the one `type` effect. It must never enter argv, environment variables, FKST events, Lua values, prompts, stdout, stderr, logs, receipts, or artifacts.

## Turn loop and terminal authority

For each bounded turn, the controller observes, asks `workflow.codex.dispatch` for one action, validates the closed action contract, re-observes the exact target and document, executes one authorized effect, and validates the before/after step receipt.

The controller stops immediately on malformed or repeated actions, stale handles or documents, unexpected origin or callback path, target change, popup, MFA, CAPTCHA, runtime failure, interrupt, ambiguous state, or budget exhaustion.

A pass requires all deterministic host completion signals:

- exact callback observed;
- supervised login process exit code is zero;
- identity CLI check succeeds;
- status CLI check reports authenticated.

The reviewed browser case binds these signals through explicit `completion_assertions`. Each entry
declares the stable assertion ID, assertion type, requiredness, and exact Host completion field.
The runner evaluates only that reviewed authority; it never infers assertion identity from prose.

AI `finish=success` cannot satisfy or override these checks.

The runner writes bounded `test-plan.json`, canonical `case-result-set.json`, canonical
`evidence-manifest.json`, `browser-agent-execution.json`, and `metadata.json` artifacts. Browser
outcomes do not fabricate `case-results.json` because the unchanged
`testing-structured-case-results.v1` kind vocabulary is limited to CLI and HTTP cases.
Step receipts contain sanitized before/after observations and typed actions only. Raw model prompts,
responses, and transcripts are not persisted.
Canonical evidence includes the browser receipt and per-observation sanitized JSON. When the browser
runtime exposes a run-scoped screenshot or runner-output pointer, it must also provide exact digest
and byte metadata; the controller emits the corresponding manifest entry or fails closed.
The host runtime also supplies SHA-256 over bounded canonical bytes so result, repository, and
manifest bindings are content-addressed rather than inferred from paths or process success.
