local adapter = require("host_workflow_qa_adapter")
local saga = require("workflow.saga")

local spec = {
  consumes = { "workflow_qa_execution_grant_request" },
  produces = { "workflow-qa.execution_grant_result" },
  stall_window = "5m",
  retry = false,
}

local function act(event)
  local result = adapter.handle_execution_grant(event.payload or {}, event.test_ports)
  log.info("generic-host dept=workflow_qa_grant tag=GRANTED")
  raise(result.queue, result.payload)
end

return saga.department(spec, {
  done = function() return false end,
  act = act,
  name = "workflow_qa_grant",
})
