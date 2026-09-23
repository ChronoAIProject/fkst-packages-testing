local results = require("contract.testing_results")
local evidence = require("contract.testing_evidence_manifest")
local reducer = require("contract.testing_result_authority")
local sha256 = require("tests.fixtures.sha256_helpers")
local fixtures = require("tests.fixtures.conformance_runner_helpers")
local t = fkst.test

local function fixture(name)
  return fixtures.fixture("packages/testing-runner/tests/fixtures/fixed-browser", name or "canonical-result")
end

return {
  test_fixed_browser_projection_uses_existing_canonical_contracts = function()
    for _, name in ipairs({"canonical-result", "canonical-failed", "canonical-lost", "canonical-timeout"}) do
    local f = fixture(name)
    local set, manifest = f.result.case_result_set, f.result.evidence_manifest
    local context = { artifact_root = ".testing/runs/" .. set.run_id }
    local authority = { plan_ref = set.plan_ref, plan_sha256 = set.plan_sha256,
      reviewed_case_id = set.cases[1].reviewed_case_id,
      assertions = { { assertion_id = f.plan.assertion.assertion_id, required = true } } }
    t.eq(results.validate_case_result_set(set, { authority }, manifest, sha256, context), set)
    t.eq(sha256(results.canonicalize(set, manifest, sha256, context)), f.result.completion.case_result_set_sha256)
    t.eq(sha256(evidence.serialize(manifest, context)), f.result.completion.evidence_manifest_sha256)
    local outcome = f.result.evidence.outcome
    local reduction_input = { outcome = outcome == "timeout" and "infrastructure_failure" or outcome }
    if outcome == "observed" then
      reduction_input.expected = f.plan.assertion.expected
      reduction_input.observed_title = f.result.evidence.observed_title
    end
    local reduction = reducer.reduce(reduction_input)
    t.eq(reduction.execution_status, set.cases[1].execution_status)
    t.eq(reduction.assertion_status, set.cases[1].assertions[1].status)
    reducer.validate_reduction(reduction_input, set, manifest, sha256, context)
    if outcome == "timeout" then t.eq(set.cases[1].error.code, "provider-timeout") end
    if outcome == "lost" then t.eq(set.cases[1].non_execution_reason, "execution-lost-between-action-and-assertion") end
    end
  end,

  test_foreign_assertion_and_evidence_context_fail_closed = function()
    local f = fixture()
    local set, manifest = f.result.case_result_set, f.result.evidence_manifest
    local context = { artifact_root = ".testing/runs/" .. set.run_id }
    manifest.entries[1].case_id = "FOREIGN.CASE"
    t.raises(function() results.validate_case_result_set(set, nil, manifest, sha256, context) end)
    f = fixture()
    f.result.evidence_manifest.entries[1].artifact_ref.ref = ".testing/runs/another/effect.json"
    t.raises(function() results.validate_case_result_set(f.result.case_result_set, nil,
      f.result.evidence_manifest, sha256, context) end)
    f = fixture()
    local foreign_authority = { plan_ref = f.result.case_result_set.plan_ref,
      plan_sha256 = f.result.case_result_set.plan_sha256,
      reviewed_case_id = f.result.case_result_set.cases[1].reviewed_case_id,
      assertions = { { assertion_id = "assertion:foreign", required = true } } }
    t.raises(function() results.validate_case_result_set(f.result.case_result_set,
      { foreign_authority }, f.result.evidence_manifest, sha256, context) end)
  end,
}
