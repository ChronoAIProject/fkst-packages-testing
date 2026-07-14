local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "platform_loop_request" },
  published_seam = { "platform_loop_request" },
  produces = { "testing-runner.module_test_request", "testing-runner.platform_test_request" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  if payload.schema == core.schedule_schema then
    core.validate_schedule_request(payload)
    local graph = core.read_relation_graph(payload.relation_graph_path)
    local action = core.coordinate(graph, {})
    log.info("platform-test-loop dept=start tag=WAVE modules=" .. tostring(#action.wave))
    for _, request in ipairs(action.wave) do raise("testing-runner.module_test_request", request) end
    return
  end
  local request = core.runner_request(payload)
  log.info("platform-test-loop dept=start tag=DELEGATE")
  raise("testing-runner.platform_test_request", request)
end

local M = saga.department(spec, { done = done, act = act, name = "start" })
M.pipeline = _G.pipeline
return M
