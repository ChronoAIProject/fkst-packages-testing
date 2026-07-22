local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "module-test-loop.module_loop_terminal" },
  produces = {
    "test-publication.qa_checkpoint_request",
    "testing-runner.structured_plan_request",
    "environment-factory.environment_finalize",
    "environment-factory.environment_interrupt",
  },
  fanout = { "module-test-loop.module_loop_terminal" },
  stall_window = "10m",
  retry = false,
}

local function accept(event)
  local payload = (event or {}).payload or {}
  return payload.schema == "module-test-loop.terminal.v1"
    and type(payload.source_ref) == "table" and payload.source_ref.kind == "workflow-qa"
end

local function act(event)
  local raised = core.handle_module_terminal(event.payload or {}, nil, event.test_ports)
  log.info("workflow-qa dept=module_terminal tag=PLAN actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, name = "module_terminal" })
