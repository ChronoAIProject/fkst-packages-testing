local core = require("core")
local t = fkst.test

return {
  test_defaults_to_localhost = function()
    t.eq(core.default_base_url(), "http://localhost:8080/")
  end,

  test_browser_readiness_uses_three_roles = function()
    local request = core.browser_readiness_check()
    t.eq(request.schema, "browser-readiness.check.v1")
    t.eq(#request.sessions, 3)
    t.eq(request.sessions[1].role, "admin")
    t.eq(request.sessions[2].cdp_endpoint_env, "ORNN_USER1_CDP_ENDPOINT")
  end,

  test_module_defaults_use_browser_harness = function()
    local request = core.module_loop_defaults("ornn_redemption_code")
    t.eq(request.schema, "module-test-loop.start.v1")
    t.eq(request.module, "ornn_redemption_code")
    t.eq(request.e2e_driver, "multi_session_browser_harness")
    t.eq(request.dry_run_github, true)
  end,
}
