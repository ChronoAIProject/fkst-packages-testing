local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "artifact_summary" },
  published_seam = { "artifact_summary" },
  produces = { "publication_request" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local request = core.publication_request(event.payload or {})
  log.info("test-publication dept=prepare_publication tag=REQUEST status=" .. tostring(request.status))
  raise("publication_request", request)
end

local M = saga.department(spec, { done = done, act = act, name = "prepare_publication" })
M.pipeline = _G.pipeline
return M
