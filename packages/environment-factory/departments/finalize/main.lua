local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "environment_finalize" },
  published_seam = { "environment_finalize" },
  produces = { "environment_result" },
  stall_window = "10m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local result = core.finalize(event.payload or {})
  log.info("environment-factory dept=finalize tag=" .. string.upper(result.status))
  raise("environment_result", result)
end

local M = saga.department(spec, { done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "environment-factory.finalize" })
M.pipeline = _G.pipeline
return M
