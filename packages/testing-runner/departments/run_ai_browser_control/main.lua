local browser_control = require("ai_browser_control")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "ai_browser_control_request" },
  published_seam = { "ai_browser_control_request" },
  produces = { "testing_result" },
  stall_window = "30m",
  retry = false,
}

local function act(event)
  local result = browser_control.result_payload(event.payload or {}, event.test_ports)
  log.info("testing-runner dept=run_ai_browser_control tag=" .. string.upper(result.status))
  raise("testing_result", result)
end

return saga.department(spec, {
  done = function() return false end,
  act = act,
  wrap = workflow_logging.wrap_pipeline_failure, name = "testing-runner.run_ai_browser_control",
})
