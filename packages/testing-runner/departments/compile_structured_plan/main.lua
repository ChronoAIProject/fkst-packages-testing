local planning = require("structured_planning")
local saga = require("workflow.saga")

local spec = {
  consumes = { "structured_plan_request" },
  published_seam = { "structured_plan_request" },
  produces = { "structured_plan_result" },
  stall_window = "5m",
  retry = false,
}

local function act(event)
  local result = planning.compile(event.payload or {}, event.test_ports or planning.production_ports())
  log.info("testing-runner dept=compile_structured_plan tag=" .. string.upper(tostring(result.status)))
  raise("structured_plan_result", result)
end

return saga.department(spec, { done = function() return false end, act = act, name = "compile_structured_plan" })
