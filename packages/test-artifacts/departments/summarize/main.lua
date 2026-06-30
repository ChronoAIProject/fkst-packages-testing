local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "testing_result" },
  published_seam = { "testing_result" },
  produces = { "artifact_summary" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local summary = core.from_testing_result(event.payload or {})
  log.info("test-artifacts dept=summarize tag=SUMMARY status=" .. tostring(summary.status))
  raise("artifact_summary", summary)
end

local M = saga.department(spec, { done = done, act = act, name = "summarize" })
M.pipeline = _G.pipeline
return M
