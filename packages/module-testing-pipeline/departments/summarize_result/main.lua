local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "testing-runner.testing_result", "testing_result" },
  produces = { "test-artifacts.testing_result" },
  fanout = { "testing-runner.testing_result", "testing_result" },
  stall_window = "5m",
  retry = false,
}

local function accept(event)
  local payload = (event or {}).payload or {}
  local source = payload.source_ref
  if type(source) == "table" and source.kind == "module-test-loop-attempt" then return false end
  if type(source) == "table" and source.kind == "workflow-qa" then return false end
  return true
end

local function done(_event)
  return false
end

local function act(event)
  local result = core.validate_testing_result(event.payload or {})
  log.info("module-testing-pipeline dept=summarize_result tag=DELEGATE status=" .. tostring(result.status))
  raise("test-artifacts.testing_result", result)
end

local M = saga.department(spec, { accept = accept, done = done, act = act, name = "summarize_result" })
M.pipeline = _G.pipeline
return M
