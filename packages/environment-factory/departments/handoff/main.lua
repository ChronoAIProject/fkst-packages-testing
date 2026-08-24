local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "browser-readiness.browser_readiness_result" },
  produces = { "environment_result" },
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
  if action.result == nil then
    error("environment-factory: malformed-readiness-action: browser readiness produced no result")
  end
  log.info("environment-factory dept=handoff tag=" .. string.upper(action.result.status))
  raise("environment_result", action.result)
end

local M = saga.department(spec, { accept = accept, done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "environment-factory.handoff" })
M.pipeline = _G.pipeline
return M
