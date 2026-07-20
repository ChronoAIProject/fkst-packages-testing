local saga = require("workflow.saga")

local spec = {
  consumes = { "workflow_qa_tick" },
  produces = { "qa_run_request", "qa_interrupt_request", "workflow_qa_terminal_request", "github_issue_written", "github_pr_comment_request" },
  stall_window = "30s", retry = false,
}

return saga.department(spec, {
  done = function() return false end, act = function() return end, name = "seam",
})
