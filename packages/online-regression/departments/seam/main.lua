local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "online_regression_keepalive_tick" },
  produces = { "online_regression_start" },
  stall_window = "30s",
  retry = false,
}

local function done(_event)
  return false
end

local function act(_event)
  return
end

return saga.department(spec, { done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "online-regression.seam" })
