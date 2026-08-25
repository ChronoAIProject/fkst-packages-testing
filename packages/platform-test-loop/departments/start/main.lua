local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "platform_loop_request" },
  published_seam = { "platform_loop_request" },
  produces = { "testing-runner.platform_test_request" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local request = core.runner_request(event.payload or {})
  log.info("platform-test-loop dept=start tag=DELEGATE")
  raise("testing-runner.platform_test_request", request)
end

local M = saga.department(spec, { done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "platform-test-loop.start" })
M.pipeline = _G.pipeline
return M
