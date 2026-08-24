local adapter = require("adapter")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "workflow-qa.workflow_qa_terminal_request" },
  fanout = { "workflow-qa.workflow_qa_terminal_request" },
  produces = {},
  stall_window = "5m",
  retry = false,
}

local function act(event)
  local terminal = adapter.handle_terminal(event.payload or {}, event.test_ports)
  log.info("local-qa-host dept=terminal tag=RECORDED run_id=" .. tostring(terminal.run_id))
end

return saga.department(spec, {
  done = function() return false end,
  act = act,
  wrap = workflow_logging.wrap_pipeline_failure, name = "local-qa-host-adapter.terminal",
})
