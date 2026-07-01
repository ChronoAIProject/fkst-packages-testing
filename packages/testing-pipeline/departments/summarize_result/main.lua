local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "testing-runner.testing_result" },
  produces = { "test-artifacts.testing_result" },
  fanout = { "testing-runner.testing_result" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local result = core.validate_testing_result(event.payload or {})
  log.info("testing-pipeline dept=summarize_result tag=DELEGATE status=" .. tostring(result.status))
  raise("test-artifacts.testing_result", result)
end

local M = saga.department(spec, { done = done, act = act, name = "summarize_result" })
M.pipeline = _G.pipeline
return M
