local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "test-publication.github_issue_create_request" },
  produces = { "github-proxy.github_issue_create_request" },
  stall_window = "2m", retry = false,
}

local function act(event)
  raise("github-proxy.github_issue_create_request", event.payload or {})
end

return saga.department(spec, { done = function() return false end, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "workflow-qa.github_issue_out" })
