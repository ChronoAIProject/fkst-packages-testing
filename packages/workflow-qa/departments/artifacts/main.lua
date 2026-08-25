local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "test-artifacts.artifact_summary" },
  produces = {
    "test-publication.qa_checkpoint_request",
    "test-publication.defect_preparation_request",
    "environment-factory.environment_finalize",
    "environment-factory.environment_interrupt",
  },
  fanout = { "test-artifacts.artifact_summary" },
  stall_window = "10m",
  retry = false,
}

local function accept(event)
  local payload = (event or {}).payload or {}
  return payload.schema == "test-artifacts.summary.v1"
    and (payload.job == "structured-execution" or payload.job == "ai-browser-control")
    and type(payload.source_ref) == "table"
    and payload.source_ref.kind == "workflow-qa"
end

local function act(event)
  local raised = core.handle_artifact_summary(event.payload or {}, nil, event.test_ports)
  log.info("workflow-qa dept=artifacts tag=ADVANCE actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "workflow-qa.artifacts" })
