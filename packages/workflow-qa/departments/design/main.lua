local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "testing-runner.testing_result" },
  produces = {
    "test-publication.qa_checkpoint_request", "testing-runner.structured_execution_request",
    "environment-factory.environment_finalize",
  },
  fanout = { "testing-runner.testing_result" }, stall_window = "10m", retry = false,
}

local function accept(event)
  local payload = (event or {}).payload or {}
  return payload.job ~= "structured-execution" and type(payload.source_ref) == "table"
    and payload.source_ref.kind == "workflow-qa"
end

local function act(event)
  local raised = core.handle_design_result(event.payload or {}, nil, event.test_ports)
  log.info("workflow-qa dept=design tag=EXECUTE actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, name = "design" })
