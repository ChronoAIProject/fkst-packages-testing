local department = require("departments.run_structured_execution.main")
local fixtures = require("tests.structured_execution_helpers")
local testing = require("testkit.testing")
local t = fkst.test

return {
  test_namespaced_structured_request_raises_pipeline_testing_result = function()
    local request = fixtures.request()
    local artifacts = fixtures.artifacts(request)
    local writes = {}
    local trace = testing.run_fake(department, {
      queue = "structured_execution_request",
      test_ports = {
        load_artifact = function(path) return artifacts[path] end,
        now = function() return "2026-07-20T00:30:00Z" end,
        verify_grant = function() return fixtures.attestation() end,
        replay_guard = function() return { status = "claimed", claim_id = "claim-110" } end,
        exec_argv = function() return { exit_code = 0, stdout = "fixture 1.0", stderr = "" } end,
        http_request = function() error("unexpected HTTP request") end,
        write_artifact = function(path, value) writes[path] = value return true end,
        load_result = function() return nil end,
        complete_replay = function() return true end,
      },
      payload = request,
    })
    t.eq(trace.raises[1].queue, "testing_result")
    local result = trace.raises[1].payload
    t.eq(result.schema, "testing-runner.result.v1")
    t.eq(result.job, "structured-execution")
    t.eq(result.status, "passed")
    t.eq(result.trace_id, request.trace_id)
    t.eq(result.dedup_key, request.dedup_key)
    t.eq(result.native_summary.schema, "testing-runner.structured-execution-summary.v1")
    t.eq(result.native_summary.case_results_path, result.artifact_root .. "/case-results.json")
    t.is_true(type(writes[result.artifact_root .. "/metadata.json"]) == "table")
  end,
}
