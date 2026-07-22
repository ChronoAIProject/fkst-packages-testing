local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "browser-readiness.browser_readiness_result" },
  produces = { "module-testing-pipeline.module_start" },
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
  local starts = core.module_starts(plan, payload)
  log.info("testing-discovery dept=emit_modules tag=EMIT modules=" .. tostring(#starts))
  for _, start in ipairs(starts) do
    raise("module-testing-pipeline.module_start", start)
  end
end

local M = saga.department(spec, { accept = is_discovery_result, done = done, act = act, name = "emit_modules" })
M.pipeline = _G.pipeline
return M
