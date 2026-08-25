local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "testing-runner.testing_result" },
  produces = { "test-artifacts.testing_result" },
  fanout = { "testing-runner.testing_result" },
  stall_window = "10m",
  retry = false,
}

local function accept(event)
  local payload = (event or {}).payload or {}
  return payload.schema == "testing-runner.result.v1"
    and (payload.job == "structured-execution" or payload.job == "ai-browser-control")
    and type(payload.source_ref) == "table"
    and payload.source_ref.kind == "workflow-qa"
end

local function act(event)
  local raised = core.handle_execution_result(event.payload or {}, nil, event.test_ports)
  log.info("workflow-qa dept=execution tag=SUMMARIZE actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "workflow-qa.execution" })
