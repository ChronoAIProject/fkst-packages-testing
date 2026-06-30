local core = require("core")
local t = fkst.test

return {
  test_builds_online_runner_request = function()
    local request = core.runner_request({
      schema = "online-regression.start.v1",
      driver = "ego_browser",
      dry_run_github = true,
    })
    t.eq(request.schema, "testing-runner.online-regression.request.v1")
    t.eq(request.driver, "ego_browser")
    t.eq(request.dry_run_github, true)
  end,

  test_requires_schema = function()
    t.raises(function()
      core.runner_request({ driver = "ego_browser" })
    end)
  end,
}
