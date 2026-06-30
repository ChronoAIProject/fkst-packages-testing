local core = require("core")
local t = fkst.test

return {
  test_builds_testing_runner_request = function()
    local request = core.runner_request({
      schema = "module-test-loop.start.v1",
      module = "module-a",
      e2e_driver = "browser_harness",
      dry_run_github = true,
    })
    t.eq(request.schema, "testing-runner.module-test-loop.request.v1")
    t.eq(request.module, "module-a")
    t.eq(request.e2e_driver, "browser_harness")
    t.eq(request.dry_run_github, true)
  end,

  test_requires_module = function()
    t.raises(function()
      core.runner_request({ schema = "module-test-loop.start.v1" })
    end)
  end,
}
