local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "browser-readiness.browser_readiness_result" },
  produces = {
    "environment_result",
    "testing-pipeline.module_start",
  },
  fanout = { "browser-readiness.browser_readiness_result" },
  stall_window = "5m",
  retry = false,
}

local function accept(event)
  local source = ((event or {}).payload or {}).source_ref
  return type(source) == "table"
    and source.kind == "artifact"
    and tostring(source.ref or ""):sub(-21) == "/operation-state.json"
end

local function done(_event)
  return false
end

local function act(event)
  local action = core.handle_browser_readiness(event.payload or {})
  if action.module_start ~= nil then
    log.info("environment-factory dept=handoff tag=TESTING_READY")
    raise("testing-pipeline.module_start", action.module_start)
  elseif action.result ~= nil then
    log.info("environment-factory dept=handoff tag=BROWSER_BLOCKED")
    raise("environment_result", action.result)
  else
    log.info("environment-factory dept=handoff tag=DEDUP")
  end
end

local M = saga.department(spec, { accept = accept, done = done, act = act, name = "handoff" })
M.pipeline = _G.pipeline
return M
