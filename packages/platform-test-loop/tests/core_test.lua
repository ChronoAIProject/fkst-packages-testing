local core = require("core")
local t = fkst.test

return {
  test_builds_platform_runner_request = function()
    local request = core.runner_request({
      schema = "platform-test-loop.start.v1",
      modules = { "a", "b" },
      priority = { "P0", "P1" },
      e2e_driver = "browser_harness",
      backend = "fkst-native",
      preflight_result = { status = "ready" },
    })
    t.eq(request.schema, "testing-runner.platform-test-loop.request.v1")
    t.eq(request.modules[2], "b")
    t.eq(request.priority[1], "P0")
    t.eq(request.e2e_driver, "browser_harness")
    t.eq(request.backend, "fkst-native")
    t.eq(request.preflight_result.status, "ready")
  end,

  test_rejects_sparse_modules = function()
    t.raises(function()
      local modules = {}
      modules[1] = "a"
      modules[3] = "c"
      core.runner_request({ schema = "platform-test-loop.start.v1", modules = modules })
    end)
  end,
}
