local qa_publication = require("qa_publication")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "qa_checkpoint_request" },
  published_seam = { "qa_checkpoint_request" },
  produces = { "github_issue_comment_request", "qa_publication_receipt" },
  stall_window = "10m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local prepared = qa_publication.prepare_checkpoint(event.payload or {}, event.test_ports or qa_publication.production_ports())
  log.info("test-publication dept=record_qa_checkpoint tag=" .. string.upper(prepared.status))
  if prepared.comment_request ~= nil then
    raise("github_issue_comment_request", prepared.comment_request)
  elseif prepared.receipt ~= nil then
    raise("qa_publication_receipt", prepared.receipt)
  end
end

local M = saga.department(spec, { done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "test-publication.record_qa_checkpoint" })
M.pipeline = _G.pipeline
return M
