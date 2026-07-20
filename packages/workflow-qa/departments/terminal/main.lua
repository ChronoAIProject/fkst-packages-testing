local saga = require("workflow.saga")

local spec = {
  consumes = { "workflow_qa_terminal_request" }, published_seam = { "workflow_qa_terminal_request" },
  produces = { "github-proxy.github_issue_label_request" },
  stall_window = "2m", retry = false,
}

local function act(event)
  local payload = event.payload or {}
  raise("github-proxy.github_issue_label_request", {
    schema = "github-proxy.label.v1", repo = payload.repository, issue_number = payload.issue_number,
    add_labels = { "fkst-qa:terminal" }, remove_labels = { "fkst-qa" },
    label_colors = { ["fkst-qa:terminal"] = "0E8A16" },
    dedup_key = tostring(payload.dedup_key) .. "/terminal-label/" .. tostring(payload.status),
    source_ref = { kind = "workflow-qa", ref = tostring(payload.run_id) },
  })
end

return saga.department(spec, { done = function() return false end, act = act, name = "terminal" })
