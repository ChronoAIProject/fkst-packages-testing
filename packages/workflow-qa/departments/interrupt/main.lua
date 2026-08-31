local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "qa_interrupt_request" }, published_seam = { "qa_interrupt_request" },
  produces = { "environment-factory.environment_finalize", "environment-factory.environment_interrupt" },
  stall_window = "5m", retry = false,
}

local function act(event)
  local raised = core.handle_interrupt(event.payload or {}, event.test_ports)
  log.info("workflow-qa dept=interrupt tag=CLEANUP actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { done = function() return false end, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "workflow-qa.interrupt" })
