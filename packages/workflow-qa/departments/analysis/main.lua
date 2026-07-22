local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "testing-design.analysis_result" },
  produces = {
    "test-publication.qa_checkpoint_request", "browser-readiness.browser_readiness_check",
    "environment-factory.environment_finalize", "environment-factory.environment_interrupt",
  },
  fanout = { "testing-design.analysis_result" }, stall_window = "10m", retry = false,
}

local function act(event)
  local raised = core.handle_analysis_result(event.payload or {}, nil, event.test_ports)
  log.info("workflow-qa dept=analysis tag=DESIGN actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { done = function() return false end, act = act, name = "analysis" })
