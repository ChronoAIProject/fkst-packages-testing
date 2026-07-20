local saga = require("workflow.saga")

local spec = {
  consumes = { "test-publication.github_issue_comment_request" },
  produces = { "github-proxy.github_issue_comment_request" },
  stall_window = "2m", retry = false,
}

local function act(event)
  raise("github-proxy.github_issue_comment_request", event.payload or {})
end

return saga.department(spec, { done = function() return false end, act = act, name = "github_comment_out" })
