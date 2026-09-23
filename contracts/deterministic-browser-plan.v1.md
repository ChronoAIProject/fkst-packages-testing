# Fixed Browser Plan v1 (unpublished fixture slice)

This is the upstream implementation for PQL #88 / Testing #853. It is not a
published package entrypoint, production Host authority, or Promotion route.
Existing published schemas and the agentic Browser route retain their semantics.

## Node API

`libraries/testing_runtime/lib/deterministic_browser.js` exports:

- `compile(candidate, hostPolicy)` -> immutable-by-content Browser Plan JSON.
- `run({candidate, plan, execution_id}, hostContext)` -> result envelope.
- `validate_result({candidate, plan, execution_id}, hostContext)` -> the same
  verified result envelope, read-only, never starts a Browser or creates records.

The fixture Host adapter is `examples/generic-host/bin/deterministic-browser.js`.
CLI commands are `compile --candidate FILE --host-config FILE`,
`run --request FILE --host-config FILE`, and
`validate-result --request FILE --host-config FILE`. JSON goes to stdout; errors
are classified and return nonzero. `request` contains exactly `candidate`, `plan`,
and `execution_id`. This is a subprocess integration surface, not PQL execution.

## Candidate and independent Host authority

The candidate is the original `pql.browser-host-candidate.v1` with exactly:
`schema_version`, `artifact_type=browser_host_candidate`, `artifact_id`,
`project_id`, `source_binding`, `case_design`, `catalog`, `bundle_digest`,
`staging_update_digest`, `staged_project_pack_digest`, `staging_approval_digest`,
`authority={execution_authorized:false,promotion_authorized:false,gate_effect:false}`,
and `content_digest`. PQL verifies/reproduces Browser Bundle v2 and staged approval
before exporting it. Testing verifies content digests and the closed executable
subset; it does not reinterpret staging as execution approval.

`hostPolicy` has exactly these fields:

```json
{
  "schema_version": "testing.fixed-browser-host-policy.v1",
  "policy_id": "fixture-policy",
  "candidate_digest": "sha256:<64hex>",
  "case_content_digest": "sha256:<64hex>",
  "target_repository": {"identity":"repo:owner/repo","exact_commit":"<40hex>"},
  "origin_ref": "origin:example-web",
  "origin": "http://127.0.0.1:12345",
  "path": "/results",
  "query_policy": "forbidden",
  "fragment_policy": "forbidden",
  "account_policy": "none",
  "capabilities": ["testing.deterministic-browser-plan"],
  "secret_ref_allowlist": [],
  "fixture_sha256": "<64hex>",
  "timeout_ms": 10000,
  "target_resolution": {
    "target_ref": "target:results-region",
    "accessible_name_ref": "text-ref:results",
    "accessible_name": "Results"
  }
}
```

`fixture_sha256` binds the exact trusted, credential-free HTML response bytes.
Only literal loopback HTTP and one exact path are accepted. Query/fragment,
account refs, secrets, selector/XPath/code inputs, other actions/assertions, and
unsupported evidence requests fail before Browser effects. The only accepted
sequence is one explicit `navigate` and one `title` assertion whose expected
value is resolved from the reviewed catalog. The sole semantic target must be a
`page-region` with `role=region` and exactly `state_predicates=[state:visible]`.
Host `target_resolution` independently resolves its exact `accessible_name_ref`
to a literal name; ref suffixes are never parsed as text. Chromium's computed
accessibility tree must contain exactly one non-ignored region with that exact
name and positive visible geometry. Missing, ambiguous, hidden or unsupported
targets fail closed. No selector, XPath or input-provided code is accepted.

The compiled Plan has `schema_version=testing.fixed-browser-plan.v1`, `binding`,
`action`, `assertion`, `timeout_ms`, and `content_digest`. `binding` is exactly:
`candidate_digest`, `case_content_digest`, `catalog_digest`, `target_digests`
(ordered array), `target_repository`, and `host_policy_digest` (canonical digest
of the complete policy). Action is `{kind:"navigate",action_id,url}`; assertion
is `{kind:"title",assertion_id,target_ref,expected}`. Digests use PQL canonical
JSON (UTF-8, sorted keys, compact, no newline), with a `sha256:` prefix; a
`content_digest` excludes only itself. Existing Testing result SHA fields remain
unprefixed and retain their existing canonicalization semantics.

An independent grant has exactly `schema_version=testing.fixed-browser-grant.v1`,
`execution_id` (1-96 ASCII letters/digits/underscore/hyphen), `binding` (exact
Plan binding), `plan_digest`, and `expires_at` (UTC ISO timestamp). It can only be
provided by the trusted Host context. `hostContext` contains `policy`, durable
store ports, `loadGrant(execution_id)`, and the trusted Browser effect adapter.
The fixture CLI configuration contains `policy`, `grants` (array of independently
approved grants), `store_root` (absolute private Host-owned directory), and
`chrome_path` (absolute Chromium executable). Neither this configuration nor its
path may be chosen by candidate content. The caller authenticates these Host
inputs; this module does not issue grants or authenticate reviewers.

## Result and recovery

The returned object has exactly `schema_version=testing.fixed-browser-result.v1`,
`completion`, `case_result_set`, `evidence_manifest`, and `evidence`.
`completion` has `schema_version=testing.fixed-browser-completion.v1`,
`execution_id`, `binding`, `plan_digest`, `grant_digest`, `case_result_set_sha256`,
`evidence_manifest_sha256`, `evidence_sha256`, and `cleanup_status`.
The three SHA fields bind exact canonical UTF-8 bytes (without trailing newline).
`cleanup_status` is `complete` or `unknown` and must be complete for a pass.
The existing canonical CaseResultSet and EvidenceManifest are used unmodified.
The evidence is bounded structured facts, never Browser raw state or credentials.
The durable effect contains `outcome` (observed/error/timeout/lost),
`observed_title` (the reviewed literal on exact equality, otherwise the fixed
sentinel `[title differs]`, or null when unobserved), `target_status`
(unique-visible/unresolved), `cleanup_status`, binding and UTC timestamps. The
canonical reducer recomputes title equality from that bounded observation;
neither passed flags nor untrusted result classifications are authoritative.
The mismatch sentinel is outside the admitted expected-title syntax:
`^[A-Za-z0-9][A-Za-z0-9 ._-]{0,119}$`. Its brackets cannot occur in a reviewed
expected title accepted by this slice. Even with recomputed catalog, target,
Case and candidate digests, an expected `[title differs]` fails compilation
before Host store creation or Browser effects, so a mismatch cannot equal an
admitted expected title.
Consumers must verify against independently retained request/Host bindings,
never trust a self-digest as execution authority. The read-only upstream verifier
also reloads the private durable receipt and recomputes the expected canonical
results from it, rejecting tampered observations, statuses, evidence and pointers.

The fixture Host reuses `durable-host-store.js` immutable records, claims,
completion, artifact storage and crash-safe locks. A single-use execution ID
binds its grant before effects. Persist intent before starting Chrome, persist
the sanitized effect receipt after cleanup, then derive evidence/results and
complete atomically. Stored receipts resume without navigation; an intent with
no receipt becomes `lost` without retry. An active owner blocks concurrent
recovery. A crash during cleanup cannot yield a pass. Expiration applies before
first effects; replay never repeats effects or refreshes a grant.

The owned Chromium launcher waits on a release pipe until its PID and process
start identity have been journaled; parent death before release cannot launch
Chrome. A private profile directory is tracked by device/inode. Only Host
cleanup deletes that same directory after proving the worker process group is
absent. A live matching worker or Browser member must prove group ownership
before a group signal; lookup failure, recycled identities, replaced directories
and symlinks fail closed. Unverifiable groups may be waited on, never signaled.
Timeout is at most 30 seconds of Browser work plus bounded cleanup; no raw page,
accessibility tree, cookies, Browser profile or unexpected title enters artifacts.
`validate-result` requires the retained claim, intent, effect and artifact bytes;
it never creates directories, locks or Browser resources. Result artifact Plan
pointers use the existing `.testing/runs/<execution_id>/test-plan.json` convention.

## Verification

`scripts/run.sh test testing-runner` includes the Node suite and Lua canonical
context tests. The required CI step discovers Chrome and sets
`FKST_REQUIRE_FIXED_BROWSER=1` and `FKST_FIXED_BROWSER_CHROME`; missing Chrome
is a failure there. For a standalone local run:

```sh
FKST_REQUIRE_FIXED_BROWSER=1 node --test libraries/testing_runtime/tests/fixed_browser_test.js
```

The checked-in PQL candidate was generated through actual review, Case producer,
Bundle v2, staging and Host-candidate export APIs. It is an unchanged data fixture,
not evidence of Browser execution. Real Chromium tests independently exercise
title pass/fail, unique visible target enforcement, blocked scripts/subresources
and redirects, fixture digest enforcement, timeout, exact replay, concurrent
delivery and killed-Host recovery without a second navigation. Separate durable
store mutation tests reject result tamper and missing/edited intent. Lua tests
validate the projection using existing result/evidence context validators and
the existing title assertion reducer; published schemas remain unchanged.
