local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "artifact_summary" },
  published_seam = { "artifact_summary" },
  produces = { "publication_request" },
  stall_window = "5m",
  retry = false,
}

local function accept(event)
  local source = ((event or {}).payload or {}).source_ref
  return type(source) ~= "table" or source.kind ~= "workflow-qa"
end

local function done(_event)
  return false
end

local function act(event)
  local request = core.publication_request(event.payload or {})
  log.info("test-publication dept=prepare_publication tag=REQUEST status=" .. tostring(request.status))
  raise("publication_request", request)
end

local M = saga.department(spec, { accept = accept, done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "test-publication.prepare_publication" })
M.pipeline = _G.pipeline
return M
