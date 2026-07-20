local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "analysis_request" },
  published_seam = { "analysis_request" },
  produces = { "analysis_result" },
  stall_window = "10m",
  retry = false,
}

local function done(_event) return false end

local function act(event)
  local result = core.analyze(event.payload or {})
  log.info("testing-design dept=start tag=" .. string.upper(result.status)
    .. " replayed=" .. tostring(result.replayed))
  raise("analysis_result", result)
end

local M = saga.department(spec, { done = done, act = act, name = "start" })
M.pipeline = _G.pipeline
return M
