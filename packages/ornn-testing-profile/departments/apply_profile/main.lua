local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "ornn_profile_request" },
  published_seam = { "ornn_profile_request" },
  produces = { "module-test-loop.module_loop_request", "browser-readiness.browser_readiness_check" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local module = payload.module or "ornn_redemption_code"
  log.info("ornn-testing-profile dept=apply_profile tag=DEFAULTS module=" .. tostring(module))
  raise("browser-readiness.browser_readiness_check", core.browser_readiness_check())
  raise("module-test-loop.module_loop_request", core.module_loop_defaults(module))
end

local M = saga.department(spec, { done = done, act = act, name = "apply_profile" })
M.pipeline = _G.pipeline
return M
