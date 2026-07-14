local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "module_test_request" },
  published_seam = { "module_test_request" },
  produces = { "testing_result" },
  stall_window = "30m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  local result, replayed = core.run("module", payload)
  log.info("testing-runner dept=run_module_loop tag=" .. string.upper(result.status) .. " module=" .. tostring(payload.module))
  if not replayed then raise("testing_result", result) end
  return result
end

local M = saga.department(spec, { done = done, act = act, name = "run_module_loop" })
M.pipeline = _G.pipeline
return M
