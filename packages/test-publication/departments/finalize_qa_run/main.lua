local qa_publication = require("qa_publication")
local saga = require("workflow.saga")

local spec = {
  consumes = { "qa_finalize_request" },
  published_seam = { "qa_finalize_request" },
  produces = { "github_issue_comment_request" },
  stall_window = "10m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local prepared = qa_publication.prepare_final_report(event.payload or {}, event.test_ports or qa_publication.production_ports())
  log.info("test-publication dept=finalize_qa_run tag=" .. string.upper(prepared.report.status))
  if prepared.comment_request ~= nil then
    raise("github_issue_comment_request", prepared.comment_request)
  end
end

local M = saga.department(spec, { done = done, act = act, name = "finalize_qa_run" })
M.pipeline = _G.pipeline
return M
