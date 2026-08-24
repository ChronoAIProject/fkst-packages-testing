local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")
local structured_execution = require("structured_execution")

local spec = {
  consumes = { "structured_execution_request" },
  published_seam = { "structured_execution_request" },
  produces = { "testing_result" },
  stall_window = "30m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local result = structured_execution.result_payload(event.payload or {}, event.test_ports)
  log.info("testing-runner dept=run_structured_execution tag=" .. string.upper(result.status))
  raise("testing_result", result)
end

local M = saga.department(spec, { done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "testing-runner.run_structured_execution" })
M.pipeline = _G.pipeline
return M
