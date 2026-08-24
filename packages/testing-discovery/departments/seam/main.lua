local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "discovery_keepalive_tick" },
  produces = { "app_scope" },
  stall_window = "30s",
  retry = false,
}

local function done(_event)
  return false
end

local function act(_event)
  return
end

return saga.department(spec, { done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "testing-discovery.seam" })
