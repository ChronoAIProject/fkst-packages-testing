local M = {}

local default_base_url = "http://localhost:8080/"

function M.default_base_url()
  return default_base_url
end

function M.local_browser_sessions()
  return {
    { role = "admin", cdp_endpoint_env = "ORNN_ADMIN_CDP_ENDPOINT", browser_harness_command_env = "ORNN_ADMIN_BROWSER_HARNESS_COMMAND" },
    { role = "user1", cdp_endpoint_env = "ORNN_USER1_CDP_ENDPOINT", browser_harness_command_env = "ORNN_USER1_BROWSER_HARNESS_COMMAND" },
    { role = "user2", cdp_endpoint_env = "ORNN_USER2_CDP_ENDPOINT", browser_harness_command_env = "ORNN_USER2_BROWSER_HARNESS_COMMAND" },
  }
end

function M.module_loop_defaults(module)
  return {
    schema = "module-test-loop.start.v1",
    module = module,
    config = "config/current-online-regression.yaml",
    e2e_driver = "multi_session_browser_harness",
    dry_run_github = true,
  }
end

function M.browser_readiness_check()
  return {
    schema = "browser-readiness.check.v1",
    base_url = default_base_url,
    sessions = M.local_browser_sessions(),
  }
end

return M
