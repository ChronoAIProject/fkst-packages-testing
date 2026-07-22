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
  local action = core.start(event.payload or {})
  if action.readiness_check ~= nil then
    log.info("environment-factory dept=start tag=READINESS_PENDING")
    raise("browser-readiness.browser_readiness_check", action.readiness_check)
  elseif action.result ~= nil then
    log.info("environment-factory dept=start tag=" .. string.upper(action.result.status))
    raise("environment_result", action.result)
  else
    error("environment-factory: malformed-start-action: start produced no event")
  end
end

local M = saga.department(spec, { done = done, act = act, name = "start" })
M.pipeline = _G.pipeline
return M
