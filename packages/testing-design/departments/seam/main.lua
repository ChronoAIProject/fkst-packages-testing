local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "analysis_keepalive_tick" },
  produces = { "analysis_request" },
  stall_window = "30s",
  retry = false,
}

return saga.department(spec, {
  done = function() return false end,
  act = function() return end,
  wrap = workflow_logging.wrap_pipeline_failure, name = "testing-design.seam",
})
