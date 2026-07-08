local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "browser_observation_observe" },
  published_seam = { "browser_observation_observe" },
  produces = { "browser_observation_result" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local result = core.result(event.payload or {})
  log.info("browser-observation dept=observe tag=" .. string.upper(result.status) .. " observations=" .. tostring(result.observation_count))
  raise("browser_observation_result", result)
end

local M = saga.department(spec, { done = done, act = act, name = "observe" })
M.pipeline = _G.pipeline
return M
