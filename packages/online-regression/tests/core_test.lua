local core = require("core")
local t = fkst.test

return {
  test_builds_online_runner_request = function()
    local request = core.runner_request({
      schema = "online-regression.start.v1",
      driver = "ego_browser",
      heartbeat_url = "http://localhost:8080/",
      dry_run_github = true,
      backend = "fkst-native",
      preflight_result = { status = "ready" },
      trace_id = "trace-online",
      dedup_key = "dedup-online",
    })
    t.eq(request.schema, "testing-runner.online-regression.request.v1")
    t.eq(request.driver, "ego_browser")
    t.eq(request.heartbeat_url, "http://localhost:8080/")
    t.eq(request.dry_run_github, true)
    t.eq(request.backend, "fkst-native")
    t.eq(request.preflight_result.status, "ready")
    t.eq(request.trace_id, "trace-online")
    t.eq(request.dedup_key, "dedup-online")
  end,

  test_requires_schema = function()
    t.raises(function()
      core.runner_request({ driver = "ego_browser" })
    end)
  end,
}
