local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "github_pr_comment_request" }, published_seam = { "github_pr_comment_request" },
  produces = { "github-proxy.github_pr_comment_request" },
  stall_window = "2m", retry = false,
}

local function act(event)
  raise("github-proxy.github_pr_comment_request", event.payload or {})
end

return saga.department(spec, { done = function() return false end, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "workflow-qa.github_pr_comment_out" })
