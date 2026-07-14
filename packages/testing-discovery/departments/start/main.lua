local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "app_scope" },
  published_seam = { "app_scope" },
  produces = { "browser-readiness.browser_readiness_check" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local plan = core.prepare_plan(event.payload or {})
  local ok, err = core.write_plan(plan)
  if not ok then error("testing-discovery: artifact-write-failed: " .. tostring(err)) end
  local request = core.readiness_check(plan)
  log.info("testing-discovery dept=start tag=PLAN modules=" .. tostring(plan.module_count))
  raise("browser-readiness.browser_readiness_check", request)
end

local M = saga.department(spec, { done = done, act = act, name = "start" })
M.pipeline = _G.pipeline
return M
