local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "github-proxy.github_comment_written" },
  produces = { "test-publication.github_comment_written" },
  fanout = { "github-proxy.github_comment_written" }, stall_window = "2m", retry = false,
}

local function accept(event)
  local payload = (event or {}).payload
  if type(payload) ~= "table" or type(payload.handoff) ~= "table" then return false end
  return payload.handoff.kind == "test-publication.qa-checkpoint"
end

local function act(event)
  raise("test-publication.github_comment_written", event.payload or {})
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "workflow-qa.github_comment_in" })
