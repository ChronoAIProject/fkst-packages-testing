local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "module_start" },
  published_seam = { "module_start" },
  produces = {
    "ai_generation_request",
    "module-test-loop.module_loop_request",
    "testing_result",
  },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local action = core.start_module(payload)
  if action.kind == "generation-request" then
    log.info("module-testing-pipeline dept=start_module tag=AI_AUTHOR module=" .. tostring(payload.module))
    raise("ai_generation_request", action.request)
    return
  end
  if action.kind == "blocked-result" then
    log.info("module-testing-pipeline dept=start_module tag=AI_BLOCKED module=" .. tostring(payload.module))
    raise("testing_result", action.result)
    return
  end
  if action.kind == "module-loop-request" then
    log.info("module-testing-pipeline dept=start_module tag=DELEGATE module=" .. tostring(action.request.module))
    raise("module-test-loop.module_loop_request", action.request)
  end
end

local M = saga.department(spec, { done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "module-testing-pipeline.start_module" })
M.pipeline = _G.pipeline
return M
