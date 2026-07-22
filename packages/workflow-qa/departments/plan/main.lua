local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "testing-runner.structured_plan_result" },
  produces = {
    "workflow_qa_execution_grant_request",
    "environment-factory.environment_finalize",
    "environment-factory.environment_interrupt",
  },
  fanout = { "testing-runner.structured_plan_result" },
  stall_window = "5m",
  retry = false,
}

local function accept(event)
  local source = ((event or {}).payload or {}).source_ref
  local payload = (event or {}).payload or {}
  return payload.schema == "testing-runner.structured-plan.result.v1"
    and type(source) == "table" and source.kind == "workflow-qa"
end

local function act(event)
  local raised = core.handle_plan_result(event.payload or {}, nil, event.test_ports)
  log.info("workflow-qa dept=plan tag=GRANT actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, name = "plan" })
