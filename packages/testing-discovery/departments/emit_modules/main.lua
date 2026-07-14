local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "browser-readiness.browser_readiness_result" },
  produces = { "platform-test-loop.platform_loop_request" },
  fanout = { "browser-readiness.browser_readiness_result" },
  stall_window = "5m",
  retry = false,
}

local function is_discovery_result(event)
  local ref = ((event or {}).payload or {}).source_ref
  return type(ref) == "table" and ref.kind == "testing-discovery-plan"
end

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local plan = core.read_plan(payload.source_ref.ref)
  local graph, err = core.write_relation_graph(plan, payload)
  if graph == nil then error("testing-discovery: relation-graph-write-failed: " .. tostring(err)) end
  log.info("testing-discovery dept=emit_modules tag=SCHEDULE modules=" .. tostring(graph.node_count))
  raise("platform-test-loop.platform_loop_request", core.schedule_request(graph))
end

local M = saga.department(spec, { accept = is_discovery_result, done = done, act = act, name = "emit_modules" })
M.pipeline = _G.pipeline
return M
