local core = require("core")
local t = fkst.test

local function failed_result(overrides)
  local result = {
    schema = "testing-runner.result.v1",
    job = "module-test-loop",
    status = "failed",
    artifact_root = ".testing/runs/module-a",
    source_ref = { kind = "host", ref = "module-a" },
    trace_id = "trace-module-a",
    dedup_key = "dedup-module-a",
    adapter = { name = "fkst-native", mode = "browser-driver" },
    native_summary = {
      schema = "testing-runner.browser-driver-summary.v1",
      module = "module-a",
      driver = "multi_session_browser_harness",
      status = "failed",
      mode = "argv",
      readiness = {
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready" },
          { role = "admin", status = "ready" },
        },
      },
    },
    exit_code = 1,
    stderr_excerpt = "check failed",
  }
  for key, value in pairs(overrides or {}) do
    result[key] = value
  end
  return result
end

return {
  test_product_defect_requires_reproducible_user_facing_evidence = function()
    local classification = core.classify_testing_result(failed_result({
      evidence_refs = {
        { kind = "artifact", ref = ".testing/runs/module-a/evidence/product.json", user_facing = true, reproducible = true },
      },
    }))
    t.eq(classification.schema, "testing-pipeline.outcome-classification.v1")
    t.eq(classification.category, "product_defect")
    t.eq(classification.reason, "failed run has reproducible user-facing evidence refs")
    t.eq(classification.evidence_refs[1].ref, ".testing/runs/module-a/evidence/product.json")
  end,

  test_stale_product_evidence_ref_is_not_product_defect = function()
    local classification = core.classify_testing_result(failed_result({
      adapter = { name = "fkst-native", mode = "module-no-browser" },
      native_summary = {
        schema = "testing-runner.module-no-browser-summary.v1",
        module = "module-a",
        status = "failed",
        mode = "argv",
      },
      evidence_refs = {
        { kind = "artifact", ref = ".testing/runs/other/evidence/product.json", user_facing = true, reproducible = true },
      },
    }))
    t.eq(classification.category, "not_executed_risk")
    t.eq(#classification.evidence_refs, 0)
  end,

  test_product_defect_validation_rejects_unbound_evidence_refs = function()
    t.raises(function()
      core.validate_outcome_classification({
        schema = "testing-pipeline.outcome-classification.v1",
        category = "product_defect",
        status = "failed",
        job = "module-test-loop",
        module = "module-a",
        reason = "failed run has reproducible user-facing evidence refs",
        artifact_root = ".testing/runs/module-a",
        source_ref = { kind = "host", ref = "module-a" },
        trace_id = "trace-module-a",
        dedup_key = "dedup-module-a",
        evidence_refs = {
          { kind = "artifact", ref = ".testing/runs/other/evidence/product.json", user_facing = true, reproducible = true },
        },
      })
    end)
  end,

  test_failed_browser_driver_without_evidence_is_harness_tooling = function()
    local classification = core.classify_testing_result(failed_result())
    t.eq(classification.category, "harness_tooling_issue")
    t.eq(classification.reason, "harness or CDP uncertainty prevents product defect classification")
    t.eq(#classification.evidence_refs, 0)
  end,

  test_harness_uncertainty_overrides_candidate_product_evidence = function()
    local classification = core.classify_testing_result(failed_result({
      stderr_excerpt = "CDP session detached",
      evidence_refs = {
        { kind = "artifact", ref = ".testing/runs/module-a/evidence/product.json", user_facing = true, reproducible = true },
      },
    }))
    t.eq(classification.category, "harness_tooling_issue")
  end,

  test_blocked_readiness_precedes_browser_harness_uncertainty = function()
    local classification = core.classify_testing_result(failed_result({
      status = "blocked",
      native_summary = {
        schema = "testing-runner.browser-driver-summary.v1",
        module = "module-a",
        driver = "multi_session_browser_harness",
        status = "blocked",
        mode = "argv",
        readiness = {
          status = "blocked",
          sessions = {
            { role = "admin", status = "blocked" },
          },
        },
      },
    }))
    t.eq(classification.category, "environment_session_issue")
  end,

  test_blocked_readiness_is_environment_session_issue = function()
    local classification = core.classify_testing_result(failed_result({
      status = "blocked",
      adapter = { name = "fkst-native", mode = "readiness-blocked" },
      native_summary = nil,
      stderr_excerpt = "fkst-native preflight is blocked",
    }))
    t.eq(classification.category, "environment_session_issue")
    t.eq(classification.reason, "missing or blocked environment/session readiness")
  end,

  test_fixture_cleanup_rollback_gap_is_data_fixture_gap = function()
    local classification = core.classify_testing_result(failed_result({
      adapter = { name = "fkst-native", mode = "module-no-browser" },
      native_summary = {
        schema = "testing-runner.module-no-browser-summary.v1",
        module = "module-a",
        status = "failed",
        mode = "argv",
      },
      stderr_excerpt = "missing fixture cleanup rollback for safe data",
    }))
    t.eq(classification.category, "data_fixture_gap")
  end,

  test_planned_case_becomes_not_executed_risk_backlog = function()
    local classification = core.classify_testing_result(failed_result({
      status = "planned",
      adapter = { name = "fkst-native", mode = "no-browser-plan" },
      native_summary = {
        schema = "testing-runner.module-no-browser-summary.v1",
        module = "module-a",
        status = "planned",
        mode = "plan",
      },
      stderr_excerpt = nil,
    }))
    local backlog = core.gap_backlog(classification)
    t.eq(classification.category, "not_executed_risk")
    t.eq(backlog.schema, "testing-pipeline.gap-backlog.v1")
    t.eq(backlog.backlog_ref.ref, ".testing/runs/module-a/gap-backlog.json")
    t.eq(#backlog.blocked_modules, 0)
    t.eq(backlog.skipped_cases[1].category, "not_executed_risk")
    t.eq(backlog.required_follow_up[1].follow_up, "execute the planned case or add missing evidence before triage")
  end,

  test_passed_result_has_no_gap_classification = function()
    local classification = core.classify_testing_result(failed_result({
      status = "passed",
      adapter = { name = "fkst-native", mode = "module-no-browser" },
      native_summary = {
        schema = "testing-runner.module-no-browser-summary.v1",
        module = "module-a",
        status = "passed",
        mode = "argv",
      },
      exit_code = 0,
      stderr_excerpt = "",
    }))
    t.eq(classification, nil)
  end,
}
