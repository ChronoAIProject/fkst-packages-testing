local testing = require("testkit.testing")
local dept = require("departments.run_platform_loop.main")
local t = fkst.test

local root = ".testing/runs/testing-runner-final-department"

local function reset_artifacts()
  local removed = os.execute("rm -rf '" .. root .. "'")
  assert(removed == true or removed == 0)
end

return {
  test_platform_department_renders_final_aggregate_request = function()
    reset_artifacts()
    local trace = testing.run_fake(dept, {
      queue = "platform_test_request",
      payload = {
        schema = "testing-runner.final-aggregate-report-request.v1",
        aggregate = {
          schema = "platform-test-loop.aggregate.v1",
          status = "passed",
          counts = { total = 1, planned = 0, passed = 1 },
          modules = {
            {
              module = "module-a",
              status = "passed",
              module_report_path = ".testing/runs/module-a/stage-report.md",
            },
          },
          artifact_root = root,
          metadata_path = root .. "/metadata.json",
          source_ref = { kind = "platform", ref = "platform-final" },
          trace_id = "trace-platform-final",
          dedup_key = "platform-final-run",
          completion_barrier = {
            schema = "platform-test-loop.completion-barrier.v1",
            satisfied = true,
          },
        },
        coverage_matrix = {
          schema = "platform-test-loop.coverage-matrix.v1",
          rows = {
            {
              id = "module-a-covered",
              module = "module-a",
              claim = "Module A is covered",
              evidence_pointer = ".testing/runs/module-a/evidence/covered.json",
            },
          },
        },
        publication = { mode = "artifact-only", dry_run = true },
      },
    })
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "final_report_rendered")
    t.eq(trace.raises[1].payload.schema, "testing-runner.final-aggregate-report.v1")
    local handle = assert(io.open(root .. "/.rendered/final-aggregate-report.md", "r"))
    local report = handle:read("*a")
    handle:close()
    t.is_true(report:find("module report", 1, true) ~= nil)
    t.is_true(report:find("Module A is covered", 1, true) ~= nil)
  end,
}
