local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "qa_run_request" }, published_seam = { "qa_run_request" },
  produces = { "test-publication.qa_checkpoint_request", "environment-factory.environment_start" },
  stall_window = "5m", retry = false,
}

local function act(event)
  local raised = core.start(event.payload or {}, event.test_ports)
  log.info("workflow-qa dept=start tag=CLAIMED actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { done = function() return false end, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "workflow-qa.start" })
