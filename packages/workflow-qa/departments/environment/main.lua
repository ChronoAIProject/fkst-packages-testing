local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "environment-factory.environment_result" },
  produces = {
    "test-publication.qa_checkpoint_request", "testing-design.analysis_request",
    "test-publication.qa_finalize_request", "workflow_qa_terminal_request",
  },
  fanout = { "environment-factory.environment_result" }, stall_window = "10m", retry = false,
}

local function accept(event)
  local payload = (event or {}).payload or {}
  return type(payload.source_ref) ~= "table" or payload.source_ref.kind ~= "foreign-workflow"
end

local function act(event)
  local raised = core.handle_environment_event(event.payload or {}, event.test_ports)
  log.info("workflow-qa dept=environment tag=ADVANCE actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, name = "environment" })
