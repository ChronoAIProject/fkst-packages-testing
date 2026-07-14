local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "testing-runner.testing_result" },
  produces = { "testing-runner.module_test_request", "platform_result" },
  fanout = { "testing-runner.testing_result" },
  stall_window = "5m",
  retry = false,
}

local function is_scheduled_module_result(event)
  local payload = (event or {}).payload or {}
  local ref = payload.source_ref
  return payload.job == "module-test-loop"
    and type(ref) == "table"
    and ref.kind == "testing-discovery-relation-graph"
end

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local graph = core.read_relation_graph(payload.source_ref.ref)
  local results = core.results_from_artifacts(graph, payload)
  local action = core.coordinate(graph, results)
  local queue = "testing-runner.module_test_request"
  local payloads = action.wave
  local tag = "WAVE"
  local count = #payloads
  if action.aggregate ~= nil then
    assert(core.write_aggregate_result(action.aggregate), "platform-test-loop: aggregate-write-failed")
    queue = "platform_result"
    payloads = { action.aggregate }
    tag = "COMPLETE"
    count = action.aggregate.counts.total
  end
  log.info("platform-test-loop dept=collect_module_result tag=" .. tag .. " modules=" .. tostring(count))
  for _, item in ipairs(payloads) do raise(queue, item) end
end

local M = saga.department(spec, {
  accept = is_scheduled_module_result,
  done = done,
  act = act,
  name = "collect_module_result",
})
M.pipeline = _G.pipeline
return M
