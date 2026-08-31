local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "test-publication.qa_publication_receipt" },
  produces = {
    "environment-factory.environment_start", "testing-design.analysis_request",
    "browser-readiness.browser_readiness_check", "module-testing-pipeline.module_start",
    "testing-runner.structured_plan_request", "test-publication.defect_preparation_request",
    "environment-factory.environment_finalize", "environment-factory.environment_interrupt",
    "test-publication.qa_finalize_request", "workflow_qa_terminal_request",
  },
  fanout = { "test-publication.qa_publication_receipt" }, stall_window = "10m", retry = false,
}

local function accept(event)
  local payload = (event or {}).payload or {}
  return payload.schema == "test-publication.qa-publication-receipt.v2"
end

local function act(event)
  local raised = core.handle_publication_receipt(event.payload or {}, nil, event.test_ports)
  log.info("workflow-qa dept=publication tag=ADVANCE actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "workflow-qa.publication" })
