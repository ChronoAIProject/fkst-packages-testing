local strings = require("contract.strings")
local results = require("contract.testing_results")
local manifests = require("contract.testing_evidence_manifest")
local compat = require("contract.testing_results_compat")
local json = require("testing_runtime.json")
local real_sha256 = require("tests.fixtures.sha256_helpers")
local t = fkst.test

local root = ".testing/runs/semantic-run-id"
local plan_sha256 = string.rep("a", 64)
local trace_id, dedup_key = "trace-compat", "dedup-compat"
local function digest(char) return string.rep(char, 64) end
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}; for key, item in pairs(value) do out[copy(key)] = copy(item) end; return out
end
local function legacy_fixture()
  return {
    schema=compat.schema, plan_sha256=plan_sha256, cases={
      {case_id="cli-pass",kind="cli",status="passed",classification="passed",assertions={{type="exit-code",passed=true}},evidence_ref=root .. "/evidence/cli-pass.json"},
      {case_id="http-fail",kind="http",status="failed",classification="product-defect",assertions={{type="status-code",passed=true},{type="body-contains",passed=false}},evidence_ref=root .. "/evidence/http-fail.json"},
      {case_id="cli-skip",kind="cli",status="skipped",classification="not-executed-risk",assertions={},evidence_ref=root .. "/evidence/cli-skip.json"},
      {case_id="http-error",kind="http",status="error",classification="environment-session-issue",assertions={},evidence_ref=root .. "/evidence/http-error.json"},
    },
  }
end
local function plan()
  return {
    schema="testing-structured-plan.v2", execution_mode="structured-api-cli",
    repository={url="https://github.com/owner/repo.git",commit_sha=string.rep("1",40)},
    environment_receipt_sha256=digest("2"), browser_readiness_sha256=digest("3"), case_catalog_sha256=digest("4"), module_plan_sha256=digest("5"),
    cases={
      {case_id="cli-pass",kind="cli",argv={"fixture","pass"},timeout_seconds=10,assertions={{type="exit-code",expected=0}}},
      {case_id="http-fail",kind="http",request={method="GET",url="http://127.0.0.1:4173/fail",headers={}},timeout_seconds=10,assertions={{type="status-code",expected=200},{type="body-contains",expected="ready"}}},
      {case_id="cli-skip",kind="cli",argv={"fixture","skip"},timeout_seconds=10,assertions={{type="exit-code",expected=0}},skip_reason="fixture unavailable",skip_classification="not-executed-risk"},
      {case_id="http-error",kind="http",request={method="GET",url="http://localhost:4173/error",headers={}},timeout_seconds=10,assertions={{type="status-code",expected=200}}},
    },
    residual_risk_case_ids={}, trace_id=trace_id, dedup_key=dedup_key,
  }
end
local function context()
  local value = {
    artifact_root=root, plan_sha256=plan_sha256, plan=plan(),
    repository={id="repository-identity",source_ref={kind="git",ref="https://github.com/owner/repo.git@" .. string.rep("1",40)},source_sha256=digest("6")},
    run_id="semantic-run-id", plan_ref={kind="artifact",ref=root .. "/test-plan.json"}, trace_id=trace_id, dedup_key=dedup_key,
    case_metadata={}, sha256_bytes=real_sha256,
  }
  for index, case in ipairs(legacy_fixture().cases) do
    local completed = string.format("2026-08-13T00:00:0%dZ", index)
    table.insert(value.case_metadata, {
      case_id=case.case_id, timing={started_at="2026-08-13T00:00:00Z",completed_at=completed,duration_ms=index * 1000},
      evidence={evidence_id="evidence-" .. index,role="sanitized-json",sha256=digest(string.format("%x", index + 6)),media_type="application/json",size_bytes=10 + index,producer="testing-runner",producer_version="structured-execution.v1",created_at=completed,sensitivity="internal",redaction_classification="bounded-excerpts",policy_version="structured-evidence-policy.v1",policy_status="redacted",provenance={source_kind="artifact",source_ref=case.evidence_ref,source_sha256=digest(string.format("%x", index + 6))}},
      error_message=case.status == "error" and "environment request failed" or nil,
    })
  end
  return value
end
local function bundle()
  local value, ctx = legacy_fixture(), context()
  return value, ctx, compat.canonicalize_v1(value, ctx)
end

return {
  test_strict_artifact_descendants_reject_ambiguous_and_foreign_paths = function()
    t.eq(strings.is_artifact_descendant(root .. "/evidence/result.json", root), true)
    for _, path in ipairs({
      root, root .. "-sibling/evidence/result.json", ".testing/runs/other/evidence/result.json",
      root .. "/../result.json", root .. "/evidence//result.json", root .. "/evidence/./result.json",
      root .. "/evidence/result name.json", root .. "/evidence/result?.json", root .. "/evidence/result#fragment.json", root .. "\\evidence\\result.json", "/tmp/result.json",
    }) do t.eq(strings.is_artifact_descendant(path, root), false) end
    for _, bad_root in ipairs({".testing/runs/", ".testing/runs/run/", ".testing/runs//run", "/.testing/runs/run"}) do
      t.eq(strings.is_artifact_descendant(bad_root .. "/result.json", bad_root), false)
    end
  end,

  test_explicit_root_requires_semantic_run_identity_and_verifies_digest = function()
    local _, ctx, canonical = bundle(); local set, manifest = canonical.result_set, canonical.evidence_manifest
    t.eq(set.run_id, "semantic-run-id"); t.eq(manifest.run_id, "semantic-run-id")
    t.eq(set.evidence_manifest_ref.ref, root .. "/evidence-manifest.json")
    t.eq(manifests.validate(manifest, set, real_sha256, {artifact_root=root}), manifest)
    t.eq(manifest.canonical_sha256, real_sha256(manifests.canonicalize(manifest, {artifact_root=root})))
    t.eq(results.validate_case_result_set(set, nil, manifest, real_sha256, {artifact_root=root}), set)
    local bad_manifest, bad_set = copy(manifest), copy(set); bad_manifest.canonical_sha256=digest("f"); bad_set.evidence_manifest_sha256=digest("f")
    t.raises(function() results.validate_case_result_set(bad_set, nil, bad_manifest, real_sha256, {artifact_root=root}) end)
    t.eq(ctx.run_id, strings.artifact_run_id(root))
    local divergent=copy(ctx); divergent.run_id="foreign-run"
    t.raises(function() compat.canonicalize_v1(legacy_fixture(), divergent) end)
  end,

  test_root_repository_provenance_and_correlation_bindings_fail_closed = function()
    local _, _, canonical = bundle(); local set, manifest = canonical.result_set, canonical.evidence_manifest
    for _, path in ipairs({root .. "-sibling/evidence/x.json", ".testing/runs/other/evidence/x.json", root .. "/evidence/../x.json"}) do
      local bad=copy(manifest); bad.entries[1].artifact_ref.ref=path
      t.raises(function() manifests.validate(bad, set, nil, {artifact_root=root}) end)
    end
    local bad=copy(manifest); bad.entries[1].provenance.source_ref=root .. "/evidence/other.json"
    t.raises(function() manifests.validate(bad, set, nil, {artifact_root=root}) end)
    bad=copy(manifest); bad.entries[1].provenance.source_sha256=digest("f")
    t.raises(function() manifests.validate(bad, set, nil, {artifact_root=root}) end)
    local bad_manifest,bad_set=copy(manifest),copy(set); bad_manifest.plan_ref.ref=".testing/runs/other/test-plan.json"; bad_set.plan_ref.ref=bad_manifest.plan_ref.ref
    t.raises(function() manifests.validate(bad_manifest, bad_set, nil, {artifact_root=root}) end)
    bad_manifest,bad_set=copy(manifest),copy(set); bad_manifest.plan_ref.kind="plan"; bad_set.plan_ref.kind="plan"
    t.raises(function() manifests.validate(bad_manifest, bad_set, nil, {artifact_root=root}) end)
    bad_set=copy(set); bad_set.plan_ref.sha256=plan_sha256
    t.raises(function() manifests.validate(manifest, bad_set, nil, {artifact_root=root}) end)
    bad_set=copy(set); bad_set.evidence_manifest_ref.ref=root .. "-sibling/evidence-manifest.json"
    t.raises(function() manifests.validate(manifest, bad_set, nil, {artifact_root=root}) end)
    bad_set=copy(set); bad_set.cases[1].repository.source_ref.ref="git@foreign"
    t.raises(function() results.validate_case_result_set(bad_set, nil, manifest, nil, {artifact_root=root}) end)
    bad_set=copy(set); bad_set.cases[1].trace_id="foreign-trace"
    t.raises(function() results.validate_case_result_set(bad_set, nil, manifest, nil, {artifact_root=root}) end)
    bad_set=copy(set); bad_set.cases[1].dedup_key="foreign-dedup"
    t.raises(function() results.validate_case_result_set(bad_set, nil, manifest, nil, {artifact_root=root}) end)
  end,

  test_v1_round_trip_is_exact_and_preserves_historical_empty_assertions = function()
    local value, ctx, canonical = bundle()
    local projected = compat.project_v1(canonical.result_set, canonical.evidence_manifest, ctx)
    t.eq(json.encode(projected), json.encode(value))
    t.eq(#canonical.result_set.cases[3].assertions, 1); t.eq(#canonical.result_set.cases[4].assertions, 1)
    t.eq(canonical.result_set.cases[3].assertions[1].status, "skipped")
    t.eq(canonical.result_set.cases[4].assertions[1].status, "skipped")
    t.eq(#projected.cases[3].assertions, 0); t.eq(#projected.cases[4].assertions, 0)
    projected.cases[1].assertions[1].passed=false
    t.eq(value.cases[1].assertions[1].passed, true)
  end,

  test_project_v1_normalizes_bounded_canonical_non_execution_reasons = function()
    local _, ctx, canonical = bundle()
    canonical.result_set.cases[3].classification="skipped"
    canonical.result_set.cases[3].assertions[1].classification="skipped"
    canonical.result_set.cases[3].non_execution_reason="policy-deferred"
    canonical.result_set.cases[4].error.code="provider-timeout"
    local projected=compat.project_v1(canonical.result_set, canonical.evidence_manifest, ctx)
    t.eq(projected.cases[3].classification,"not-executed-risk")
    t.eq(projected.cases[4].classification,"harness-tooling-issue")
  end,

  test_projection_support_is_explicit_and_does_not_expand_v1 = function()
    local _, ctx, canonical = bundle()
    t.eq(compat.projection_supported(canonical.result_set), true)
    canonical.result_set.cases[1].execution_status = "lost"
    canonical.result_set.cases[1].classification = "lost"
    canonical.result_set.cases[1].non_execution_reason = "runner-disconnected"
    canonical.result_set.cases[1].assertions[1].status = "skipped"
    canonical.result_set.cases[1].assertions[1].classification = "skipped"
    t.eq(compat.projection_supported(canonical.result_set), false)
    t.raises(function()
      compat.project_v1(canonical.result_set, canonical.evidence_manifest, ctx)
    end)
    local _, browser_ctx, browser_canonical = bundle()
    local completion_assertions = browser_ctx.plan.cases[1].assertions
    for index, assertion in ipairs(completion_assertions) do
      assertion.assertion_id = "assertion-" .. index
      assertion.required = true
    end
    browser_ctx.plan.cases[1].kind = "browser"
    browser_ctx.plan.cases[1].completion_assertions = completion_assertions
    browser_ctx.plan.cases[1].assertions = nil
    browser_canonical.result_set.cases[1].execution_mode = "browser"
    t.eq(compat.projection_supported(browser_canonical.result_set), false)
    t.raises(function()
      compat.project_v1(browser_canonical.result_set, browser_canonical.evidence_manifest, browser_ctx)
    end)
    t.eq(compat.projection_supported({}), false)
  end,

  test_v1_rejects_bad_status_plan_order_assertions_and_duplicates = function()
    local value, ctx = legacy_fixture(), context()
    t.eq(compat.validate_v1(value, ctx), value)
    local bad=copy(value); bad.cases[1].classification="product-defect"; t.raises(function() compat.validate_v1(bad, ctx) end)
    bad=copy(value); bad.cases[1].kind="browser"; t.raises(function() compat.validate_v1(bad, ctx) end)
    bad=copy(value); bad.cases[1].assertions={}; t.raises(function() compat.validate_v1(bad, ctx) end)
    bad=copy(value); table.insert(bad.cases[1].assertions, {type="optional-note",passed=false}); local no_plan=copy(ctx); no_plan.plan=nil
    t.raises(function() compat.validate_v1(bad, no_plan) end); t.raises(function() compat.canonicalize_v1(bad, no_plan) end)
    bad=copy(value); bad.cases[2].assertions[2].passed=true; t.raises(function() compat.validate_v1(bad, ctx) end)
    bad=copy(value); bad.cases[3].assertions={{type="exit-code",passed=false}}; t.raises(function() compat.validate_v1(bad, ctx) end)
    bad=copy(value); table.insert(bad.cases, copy(bad.cases[1])); t.raises(function() compat.validate_v1(bad, ctx) end)
    local foreign=copy(ctx); foreign.plan_sha256=digest("b"); t.raises(function() compat.validate_v1(value, foreign) end)
    foreign=copy(ctx); foreign.repository.source_ref.sha256=digest("b"); t.raises(function() compat.validate_v1(value, foreign) end)
    foreign=copy(ctx); foreign.plan_ref.sha256=digest("b"); t.raises(function() compat.validate_v1(value, foreign) end)
    foreign=copy(ctx); foreign.plan.cases[1],foreign.plan.cases[2]=foreign.plan.cases[2],foreign.plan.cases[1]; t.raises(function() compat.validate_v1(value, foreign) end)
    bad=copy(value); bad.cases[2].assertions[1].type="body-contains"; t.raises(function() compat.validate_v1(bad, ctx) end)
    bad=copy(value); bad.cases[1].evidence_ref=root .. "-sibling/evidence/x.json"; t.raises(function() compat.validate_v1(bad, ctx) end)
    bad=copy(value); bad.extra=true; t.raises(function() compat.validate_v1(bad, ctx) end)
  end,
}
