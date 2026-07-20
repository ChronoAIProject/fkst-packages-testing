local saga = require("workflow.saga")

local spec = {
  consumes = { "analysis_keepalive_tick" },
  produces = { "analysis_request" },
  stall_window = "30s",
  retry = false,
}

return saga.department(spec, {
  done = function() return false end,
  act = function() return end,
  name = "seam",
})
