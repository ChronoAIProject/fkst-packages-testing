local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "platform_test_request" },
  published_seam = { "platform_test_request" },
  produces = { "testing_result" },
  stall_window = "60m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local result = core.run("platform", payload)
  log.info("testing-runner dept=run_platform_loop tag=" .. string.upper(result.status))
  raise("testing_result", result)
end

local M = saga.department(spec, { done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "testing-runner.run_platform_loop" })
M.pipeline = _G.pipeline
return M
