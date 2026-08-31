local contract = require("contract.workflow_qa")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "workflow_qa_terminal_request" },
  published_seam = { "workflow_qa_terminal_request" },
  produces = {},
  stall_window = "2m",
  retry = false,
}

local function accept(event)
  return ((event or {}).payload or {}).schema == contract.schemas.terminal
end

local function act(event)
  local payload = event.payload or {}
  log.info("workflow-qa dept=terminal tag=HOST_HANDOFF run_id=" .. tostring(payload.run_id)
    .. " status=" .. tostring(payload.status))
end

return saga.department(spec, {
  accept = accept,
  done = function() return false end,
  act = act,
  wrap = workflow_logging.wrap_pipeline_failure, name = "workflow-qa.terminal",
})
