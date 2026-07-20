local saga = require("workflow.saga")

local spec = {
  consumes = { "github_pr_comment_request" }, published_seam = { "github_pr_comment_request" },
  produces = { "github-proxy.github_pr_comment_request" },
  stall_window = "2m", retry = false,
}

local function act(event)
  raise("github-proxy.github_pr_comment_request", event.payload or {})
end

return saga.department(spec, { done = function() return false end, act = act, name = "github_pr_comment_out" })
