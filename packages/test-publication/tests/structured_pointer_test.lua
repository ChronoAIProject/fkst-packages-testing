local core = require("core")
local t = fkst.test

return {
  test_rejects_foreign_structured_execution_pointer = function()
    local root = ".testing/runs/structured-publication"
    t.raises(function()
      core.publication_request({
        schema = "test-artifacts.summary.v1", job = "structured-execution", status = "passed",
        artifact_root = root, metadata_path = root .. "/metadata.json",
        source_ref = { kind = "workflow-qa", ref = "run" }, trace_id = "trace", dedup_key = "dedup",
        native_summary = {
          schema = "testing-runner.structured-execution-summary.v1",
          test_plan_path = root .. "/test-plan.json", execution_path = root .. "/execution.json",
          case_results_path = ".testing/runs/foreign/case-results.json",
        },
      })
    end)
  end,
}
