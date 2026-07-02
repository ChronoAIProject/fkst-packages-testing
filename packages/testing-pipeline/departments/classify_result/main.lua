local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "testing-runner.testing_result" },
  produces = { "outcome_classification", "gap_backlog" },
  fanout = { "testing-runner.testing_result" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local classification = core.classify_testing_result(event.payload or {})
  if classification == nil then
    log.info("testing-pipeline dept=classify_result tag=NO_GAP status=passed")
    return
  end
  log.info("testing-pipeline dept=classify_result tag=CLASSIFIED category=" .. tostring(classification.category))
  raise("outcome_classification", classification)
  local backlog = core.gap_backlog(classification)
  if backlog ~= nil then
    raise("gap_backlog", backlog)
  end
end

local M = saga.department(spec, { done = done, act = act, name = "classify_result" })
M.pipeline = _G.pipeline
return M
