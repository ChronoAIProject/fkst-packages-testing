local core = require("core")
local t = fkst.test

local function summary(root)
  return {
    schema = "test-artifacts.summary.v1", job = "structured-execution", status = "passed",
    artifact_root = root, metadata_path = root .. "/metadata.json",
    source_ref = { kind = "workflow-qa", ref = "run" }, trace_id = "trace", dedup_key = "dedup",
    native_summary = {
      schema = "testing-runner.structured-execution-summary.v1",
      test_plan_path = root .. "/test-plan.json", execution_path = root .. "/execution.json",
      case_results_path = root .. "/case-results.json",
    },
  }
end

return {
  test_copies_structured_execution_canonical_pointer_pair = function()
    local root = ".testing/runs/structured-publication"
    local value = summary(root)
    value.native_summary.case_result_set_path = root .. "/case-result-set.json"
    value.native_summary.case_result_set_artifact_sha256 = string.rep("a", 64)
    value.native_summary.evidence_manifest_path = root .. "/evidence-manifest.json"
    value.native_summary.evidence_manifest_artifact_sha256 = string.rep("b", 64)
    local request = core.publication_request(value)
    t.eq(request.test_plan_path, root .. "/test-plan.json")
    t.eq(request.execution_path, root .. "/execution.json")
    t.eq(request.case_results_path, root .. "/case-results.json")
    t.eq(request.case_result_set_path, root .. "/case-result-set.json")
    t.eq(request.case_result_set_artifact_sha256, string.rep("a", 64))
    t.eq(request.evidence_manifest_path, root .. "/evidence-manifest.json")
    t.eq(request.evidence_manifest_artifact_sha256, string.rep("b", 64))
  end,

  test_accepts_historical_structured_execution_summary_without_canonical_pointers = function()
    local root = ".testing/runs/structured-publication-historical"
    local request = core.publication_request(summary(root))
    t.eq(request.test_plan_path, root .. "/test-plan.json")
    t.eq(request.case_result_set_path, nil)
    t.eq(request.evidence_manifest_path, nil)
  end,

  test_rejects_partial_or_foreign_structured_execution_pointers = function()
    local root = ".testing/runs/structured-publication-invalid"
    for _, mutate in ipairs({
      function(native) native.case_results_path = ".testing/runs/foreign/case-results.json" end,
      function(native) native.case_result_set_path = root .. "/case-result-set.json" end,
      function(native) native.evidence_manifest_path = root .. "/evidence-manifest.json" end,
      function(native)
        native.case_result_set_path = ".testing/runs/foreign/case-result-set.json"
        native.evidence_manifest_path = root .. "/evidence-manifest.json"
      end,
      function(native)
        native.case_result_set_path = root .. "/case-result-set.json"
        native.evidence_manifest_path = ".testing/runs/foreign/evidence-manifest.json"
      end,
    }) do
      local value = summary(root)
      mutate(value.native_summary)
      t.raises(function() core.publication_request(value) end)
    end
  end,
}
