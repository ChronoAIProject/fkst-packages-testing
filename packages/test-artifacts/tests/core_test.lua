local core = require("core")
local t = fkst.test

return {
  test_summary_from_testing_result = function()
    local summary = core.from_testing_result({
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "passed",
      artifact_root = ".testing/runs/module-a",
    })
    t.eq(summary.schema, "test-artifacts.summary.v1")
    t.eq(summary.job, "module-test-loop")
    t.eq(summary.status, "passed")
    t.eq(summary.artifact_root, ".testing/runs/module-a")
  end,

  test_unknown_result_status_fails_closed_to_blocked = function()
    local summary = core.from_testing_result({
      schema = "testing-runner.result.v1",
      job = "module-test-loop",
      status = "unexpected",
      artifact_root = ".testing/runs/module-a",
    })
    t.eq(summary.status, "blocked")
  end,

  test_summary_requires_artifact_pointer = function()
    t.raises(function()
      core.validate_summary({ schema = "test-artifacts.summary.v1", status = "passed" })
    end)
  end,
}
