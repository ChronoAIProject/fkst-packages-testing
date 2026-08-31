local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "local_qa_host_tick" },
  produces = { "qa_run_request" },
  stall_window = "30s",
  retry = false,
}

local function act(_event)
  return
end

return saga.department(spec, {
  done = function() return false end,
  act = act,
  wrap = workflow_logging.wrap_pipeline_failure, name = "local-qa-host-adapter.seam",
})
