local authority = require("contract.testing_result_authority")
local results = require("contract.testing_results")
local sha256 = require("tests.fixtures.sha256_helpers")
local t = fkst.test
local digest = string.rep("a", 64)

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function case_result(observed, expected)
  local passed = observed == expected
  return {
    schema=results.schemas.case_result, case_id="case-1",
    repository={id="repo",source_ref={kind="git",ref="repo@commit"},source_sha256=digest},
    reviewed_case_id="case-1", plan_ref={kind="plan",ref="plan-1"}, plan_sha256=digest,
    execution_mode="browser", execution_status=passed and "passed" or "failed",
    classification=passed and "deterministic" or "assertion_failure",
    observations={{schema=results.schemas.observation,observation_id="obs-1",kind="browser-title",subject="url",
      value=observed,source_ref={kind="effect-receipt",ref="effect-1"},evidence_refs={}}},
    assertions={{schema=results.schemas.assertion_result,assertion_id="assert-1",type="title-equals",required=true,
      status=passed and "passed" or "failed",classification=passed and "deterministic" or "assertion_failure",
      observation_ids={"obs-1"},evidence_refs={}}}, evidence_refs={},
    timing={started_at="2026-09-02T00:00:00Z",completed_at="2026-09-02T00:00:01Z",duration_ms=1000},
    trace_id="trace-1",dedup_key="run-1",
  }
end

local function result_set(case)
  return {schema=results.schemas.case_result_set,set_id="set-1",run_id="run-1",
    plan_ref={kind="plan",ref="plan-1",sha256=digest},plan_sha256=digest,cases={case},
    evidence_manifest_ref={kind="artifact",ref="evidence.json",sha256=digest},
    evidence_manifest_sha256=digest,evidence_manifest_artifact_sha256=digest,trace_id="trace-1",dedup_key="run-1"}
end

local function bindings(set)
  return {
    reducer_input={outcome="observed",expected="Expected",observed_title="Expected"},case_result_set=set,
    receipt_id="authority-run-1",run_id="run-1",invocation_id="invocation-1",
    admitted_release_ref={kind="testing-package-release",ref="immutable://release/1",sha256=digest},
    admission_digest=digest,package_id="testing-runner",package_version="1.0.0",package_content_sha256=digest,
    manifest_digest=digest,executor_id="testing-package-executor.browser-title.v1",
    structured_plan_ref={kind="testing-structured-plan",ref="immutable://plan/1",sha256=digest},
    case_result_set_ref={kind="artifact",ref="result.json",sha256=digest},case_result_set_content_sha256=digest,
    evidence_manifest_ref={kind="artifact",ref="evidence.json",sha256=digest},evidence_manifest_content_sha256=digest,
    completed_execution_sha256=digest,
  }
end

return {
  test_identity_is_symbolic_versioned_and_digest_bound = function()
    local identity = authority.identity(sha256)
    t.eq(identity.reducer_id, authority.reducer_id)
    t.eq(authority.validate_identity(identity, sha256), identity)
    local changed = copy(identity); changed.policy_profile = "other"
    t.raises(function() authority.validate_identity(changed, sha256) end)
  end,

  test_receipt_replays_byte_identically_and_rejects_substitution = function()
    local set = result_set(case_result("Expected", "Expected"))
    local expected = bindings(set)
    local receipt = authority.create_receipt(expected, sha256)
    t.eq(authority.canonicalize(receipt, sha256), authority.canonicalize(authority.create_receipt(expected, sha256), sha256))
    local substituted = copy(expected); substituted.run_id = "run-2"
    t.raises(function() authority.validate_receipt(receipt, substituted, sha256) end)
  end,

  test_semantically_false_digest_consistent_result_is_rejected = function()
    local false_case = case_result("Expected", "Different")
    false_case.execution_status = "failed"; false_case.classification = "assertion_failure"
    false_case.assertions[1].status = "failed"; false_case.assertions[1].classification = "assertion_failure"
    local false_set = result_set(false_case)
    t.raises(function() authority.create_receipt(bindings(false_set), sha256) end)
  end,

  test_terminal_classifications_remain_distinct = function()
    t.eq(authority.reduce({outcome="cancelled"}).receipt_classification, "cancelled")
    t.eq(authority.reduce({outcome="infrastructure_failure"}).receipt_classification, "infrastructure_failure")
    t.eq(authority.reduce({outcome="lost"}).receipt_classification, "lost_or_inconclusive")
  end,
}
