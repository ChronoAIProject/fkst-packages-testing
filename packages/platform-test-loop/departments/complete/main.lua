local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "platform_aggregate" },
  published_seam = { "platform_aggregate" },
  produces = { "testing-runner.platform_test_request" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local request = core.completion_request(event.payload or {})
  if request == nil then
    log.info("platform-test-loop dept=complete tag=WAITING_COMPLETION_BARRIER")
    return
  end
  log.info("platform-test-loop dept=complete tag=FINALIZE status=" .. tostring(request.aggregate.status))
  raise("testing-runner.platform_test_request", request)
end

local M = saga.department(spec, { done = done, act = act, name = "complete" })
M.pipeline = _G.pipeline
return M
