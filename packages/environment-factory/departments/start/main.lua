local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "environment_start" },
  published_seam = { "environment_start" },
  produces = {
    "environment_result",
    "browser-readiness.browser_readiness_check",
  },
  stall_window = "15m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local result = core.start(event.payload or {})
  log.info("environment-factory dept=start tag=" .. string.upper(result.status))
  raise("environment_result", result)
  if result.status == "ready" then
    local state_ref = (event.payload or {}).operation_state_ref
    raise("browser-readiness.browser_readiness_check", core.browser_readiness_check(result, {
      operation_state_ref = state_ref,
    }))
  end
end

local M = saga.department(spec, { done = done, act = act, name = "start" })
M.pipeline = _G.pipeline
return M
