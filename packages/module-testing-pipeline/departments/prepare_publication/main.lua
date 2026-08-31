local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "test-artifacts.artifact_summary" },
  produces = { "test-publication.artifact_summary" },
  fanout = { "test-artifacts.artifact_summary" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local summary = core.validate_artifact_summary(event.payload or {})
  log.info("module-testing-pipeline dept=prepare_publication tag=DELEGATE status=" .. tostring(summary.status))
  raise("test-publication.artifact_summary", summary)
end

local M = saga.department(spec, { done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "module-testing-pipeline.prepare_publication" })
M.pipeline = _G.pipeline
return M
