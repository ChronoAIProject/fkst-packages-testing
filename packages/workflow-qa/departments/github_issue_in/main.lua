local saga = require("workflow.saga")

local spec = {
  consumes = { "github_issue_written" }, published_seam = { "github_issue_written" },
  produces = { "test-publication.github_issue_written" },
  stall_window = "2m", retry = false,
}

local function act(event)
  raise("test-publication.github_issue_written", event.payload or {})
end

return saga.department(spec, { done = function() return false end, act = act, name = "github_issue_in" })
