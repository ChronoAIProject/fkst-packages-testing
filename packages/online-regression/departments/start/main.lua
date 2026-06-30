local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "online_regression_start" },
  published_seam = { "online_regression_start" },
  produces = { "testing-runner.online_regression_request" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local request = core.runner_request(event.payload or {})
  log.info("online-regression dept=start tag=DELEGATE")
  raise("testing-runner.online_regression_request", request)
end

local M = saga.department(spec, { done = done, act = act, name = "start" })
M.pipeline = _G.pipeline
return M
