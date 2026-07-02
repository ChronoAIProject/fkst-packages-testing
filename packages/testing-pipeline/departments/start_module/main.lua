local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "module_start" },
  published_seam = { "module_start" },
  produces = { "module-test-loop.module_loop_request" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local request = core.module_loop_request(event.payload or {})
  core.write_planning_artifacts(event.payload or {}, request)
  log.info("testing-pipeline dept=start_module tag=DELEGATE module=" .. tostring(request.module))
  raise("module-test-loop.module_loop_request", request)
end

local M = saga.department(spec, { done = done, act = act, name = "start_module" })
M.pipeline = _G.pipeline
return M
