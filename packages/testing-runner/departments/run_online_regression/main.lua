local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "online_regression_request" },
  published_seam = { "online_regression_request" },
  produces = { "testing_result" },
  stall_window = "30m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local result = core.run("online_regression", payload)
  log.info("testing-runner dept=run_online_regression tag=" .. string.upper(result.status))
  raise("testing_result", result)
end

local M = saga.department(spec, { done = done, act = act, name = "run_online_regression" })
M.pipeline = _G.pipeline
return M
