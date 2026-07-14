local saga = require("workflow.saga")

local spec = {
  consumes = { "test-artifacts.artifact_summary" },
  produces = { "test-publication.artifact_summary" },
  fanout = { "test-artifacts.artifact_summary" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local summary = event.payload or {}
  log.info("platform-test-loop dept=publish_final_report tag=DELEGATE")
  raise("test-publication.artifact_summary", summary)
end

local M = saga.department(spec, { done = done, act = act, name = "publish_final_report" })
M.pipeline = _G.pipeline
return M
