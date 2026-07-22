local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "workflow_qa_tick" },
  produces = {
    "qa_run_request",
    "qa_interrupt_request",
    "test-publication.qa_checkpoint_request",
    "environment-factory.environment_start",
    "testing-design.analysis_request",
    "browser-readiness.browser_readiness_check",
    "module-testing-pipeline.module_start",
    "testing-runner.structured_plan_request",
    "workflow_qa_execution_grant_request",
    "execution_grant_result",
    "testing-runner.structured_execution_request",
    "testing-runner.ai_browser_control_request",
    "test-artifacts.testing_result",
    "test-publication.defect_preparation_request",
    "environment-factory.environment_finalize",
    "environment-factory.environment_interrupt",
    "test-publication.qa_finalize_request",
    "workflow_qa_terminal_request",
    "github_issue_written",
    "github_pr_comment_request",
    "github-proxy.github_issue_label_request",
  },
  stall_window = "30s",
  retry = false,
}

local function act(event)
  local raised = core.redrive(event.payload or {}, event.test_ports)
  log.info("workflow-qa dept=seam tag=REDRIVE actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { done = function() return false end, act = act, name = "seam" })
