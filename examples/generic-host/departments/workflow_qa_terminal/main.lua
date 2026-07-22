local adapter = require("host_workflow_qa_adapter")
local saga = require("workflow.saga")

local spec = {
  consumes = { "workflow_qa_terminal_request" },
  fanout = { "workflow_qa_terminal_request" },
  produces = {},
  stall_window = "2m",
  retry = false,
}

local function act(event)
  local terminal = adapter.handle_terminal(event.payload or {}, event.test_ports)
  log.info("generic-host dept=workflow_qa_terminal tag=RECORDED run_id=" .. tostring(terminal.run_id))
end

return saga.department(spec, {
  done = function() return false end,
  act = act,
  name = "workflow_qa_terminal",
})
