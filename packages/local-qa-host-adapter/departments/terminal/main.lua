local adapter = require("adapter")
local saga = require("workflow.saga")

local spec = {
  consumes = { "workflow-qa.workflow_qa_terminal_request" },
  fanout = { "workflow-qa.workflow_qa_terminal_request" },
  produces = {},
  stall_window = "5m",
  retry = false,
}

local function act(event)
  adapter.handle_terminal(event.payload or {}, event.test_ports)
end

return saga.department(spec, {
  done = function() return false end,
  act = act,
  name = "terminal",
})
