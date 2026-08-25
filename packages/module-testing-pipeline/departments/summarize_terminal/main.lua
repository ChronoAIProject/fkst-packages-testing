local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "module-test-loop.module_loop_terminal" },
  produces = { "test-artifacts.testing_result" },
  fanout = { "module-test-loop.module_loop_terminal" },
  stall_window = "5m",
  retry = false,
}

local function accept(event)
  local payload = (event or {}).payload or {}
  return payload.schema == "module-test-loop.terminal.v1"
    and type(payload.runner_result) == "table"
    and type(payload.source_ref) == "table"
    and payload.source_ref.kind ~= "workflow-qa"
end

local function act(event)
  local result = core.validate_testing_result((event.payload or {}).runner_result)
  log.info("module-testing-pipeline dept=summarize_terminal tag=DELEGATE status=" .. tostring(result.status))
  raise("test-artifacts.testing_result", result)
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "module-testing-pipeline.summarize_terminal" })
