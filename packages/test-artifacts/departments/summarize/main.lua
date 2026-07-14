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
  local payload = event.payload or {}
  local summary
  if payload.schema == "testing-runner.final-aggregate-report.v1" then
    summary = core.persist_final_report(payload)
  else
    summary = core.from_testing_result(payload)
  end
  log.info("test-artifacts dept=summarize tag=SUMMARY status=" .. tostring(summary.status))
  raise("artifact_summary", summary)
end

local M = saga.department(spec, { done = done, act = act, name = "summarize" })
M.pipeline = _G.pipeline
return M
