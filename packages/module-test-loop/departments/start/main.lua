local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "module_loop_request" },
  published_seam = { "module_loop_request" },
  produces = { "testing-runner.module_test_request" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local request = core.runner_request(event.payload or {})
  log.info("module-test-loop dept=start tag=DELEGATE module=" .. tostring(request.module))
  raise("testing-runner.module_test_request", request)
end

local M = saga.department(spec, { done = done, act = act, name = "start" })
M.pipeline = _G.pipeline
return M
