local results = require("contract.testing_results")
local evidence = require("contract.testing_evidence_manifest")
local reducer = require("contract.testing_result_authority")
local sha256 = require("tests.fixtures.sha256_helpers")
local fixtures = require("tests.fixtures.conformance_runner_helpers")
local t = fkst.test

local function fixture()
  return fixtures.fixture("packages/testing-runner/tests/fixtures/fixed-browser", "canonical-result")
end

return {
  test_fixed_browser_projection_uses_existing_canonical_contracts = function()
    local f = fixture()
    local set, manifest = f.result.case_result_set, f.result.evidence_manifest
    local context = { artifact_root = ".testing/runs/" .. set.run_id }
    local authority = { plan_ref = set.plan_ref, plan_sha256 = set.plan_sha256,
      reviewed_case_id = set.cases[1].reviewed_case_id,
      assertions = { { assertion_id = f.plan.assertion.assertion_id, required = true } } }
    t.eq(results.validate_case_result_set(set, { authority }, manifest, sha256, context), set)
    t.eq(sha256(results.canonicalize(set, manifest, sha256, context)), f.result.completion.case_result_set_sha256)
    t.eq(sha256(evidence.serialize(manifest, context)), f.result.completion.evidence_manifest_sha256)
    local reduction = reducer.reduce({ outcome = "observed", expected = f.plan.assertion.expected,
      observed_title = f.result.evidence.observed_title })
    t.eq(reduction.execution_status, set.cases[1].execution_status)
    t.eq(reduction.assertion_status, set.cases[1].assertions[1].status)
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
  end,
}
