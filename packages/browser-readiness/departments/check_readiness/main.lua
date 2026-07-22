local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "browser_readiness_check" },
  published_seam = { "browser_readiness_check" },
  produces = { "browser_readiness_result" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local opts = event.test_probe and { probe = event.test_probe } or nil
  local result = core.result(event.payload or {}, opts)
  log.info("browser-readiness dept=check_readiness tag=" .. string.upper(result.status) .. " sessions=" .. tostring(#result.sessions))
  raise("browser_readiness_result", result)
end

local M = saga.department(spec, { done = done, act = act, name = "check_readiness" })
M.pipeline = _G.pipeline
return M
