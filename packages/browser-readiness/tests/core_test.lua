local core = require("core")
local t = fkst.test

local function request()
  return {
    schema = "browser-readiness.check.v1",
    sessions = {
      { role = "admin", browser_harness_command = "browser-harness" },
      { role = "user1", cdp_endpoint_env = "ORNN_USER1_CDP_ENDPOINT" },
    },
  }
end

return {
  test_validates_browser_harness_or_cdp_sessions = function()
    local payload = core.validate_request(request())
    t.eq(#payload.sessions, 2)
  end,

  test_rejects_empty_sessions = function()
    t.raises(function()
      core.validate_request({ schema = "browser-readiness.check.v1", sessions = {} })
    end)
  end,

  test_result_is_small_per_role_status = function()
    local result = core.result(request(), "planned")
    t.eq(result.schema, "browser-readiness.result.v1")
    t.eq(result.status, "planned")
    t.eq(result.sessions[1].role, "admin")
    t.eq(result.sessions[1].status, "planned")
  end,
}
