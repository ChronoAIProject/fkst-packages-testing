local adapter = require("adapter")
local saga = require("workflow.saga")

local spec = {
  consumes = { "qa_run_request" },
  published_seam = { "qa_run_request" },
  produces = { "workflow-qa.qa_run_request" },
  stall_window = "5m",
  retry = false,
}

local function act(event)
  local result = adapter.qa_run_event(event.payload or {}, event.test_ports)
  local tag = result.accepted == false and "REPLAYED" or "ROUTED"
  log.info("local-qa-host dept=intake tag=" .. tag .. " run_id=" .. tostring(result.payload.run_id))
  raise(result.queue, result.payload)
end

return saga.department(spec, {
  done = function() return false end,
  act = act,
  name = "intake",
})
