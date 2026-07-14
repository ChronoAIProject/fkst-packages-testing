local saga = require("workflow.saga")

local spec = {
  consumes = { "testing-runner.final_report_rendered" },
  produces = { "test-artifacts.testing_result" },
  fanout = { "testing-runner.final_report_rendered" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  log.info("platform-test-loop dept=persist_final_report tag=DELEGATE")
  raise("test-artifacts.testing_result", event.payload or {})
end

local M = saga.department(spec, { done = done, act = act, name = "persist_final_report" })
M.pipeline = _G.pipeline
return M
