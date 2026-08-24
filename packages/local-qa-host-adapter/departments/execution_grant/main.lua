local adapter = require("adapter")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "workflow-qa.workflow_qa_execution_grant_request" },
  produces = { "workflow-qa.execution_grant_result" },
  stall_window = "5m",
  retry = false,
}

local function act(event)
  local result = adapter.handle_execution_grant(event.payload or {}, event.test_ports)
  log.info("local-qa-host dept=execution_grant tag=GRANTED")
  raise(result.queue, result.payload)
end

return saga.department(spec, {
  done = function() return false end,
  act = act,
  wrap = workflow_logging.wrap_pipeline_failure, name = "local-qa-host-adapter.execution_grant",
})
