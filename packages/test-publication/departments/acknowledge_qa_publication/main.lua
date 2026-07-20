local qa_publication = require("qa_publication")
local saga = require("workflow.saga")

local spec = {
  consumes = { "github_comment_written" },
  published_seam = { "github_comment_written" },
  produces = { "qa_publication_receipt" },
  stall_window = "10m",
  retry = false,
}

local function accept(event)
  local handoff = ((event or {}).payload or {}).handoff
  return type(handoff) == "table" and handoff.kind == "test-publication.qa-checkpoint"
end

local function done(_event)
  return false
end

local function act(event)
  local receipt = qa_publication.acknowledge_comment(event.payload or {}, event.test_ports or qa_publication.production_ports())
  log.info("test-publication dept=acknowledge_qa_publication tag=PUBLISHED stage=" .. tostring(receipt.stage))
  raise("qa_publication_receipt", receipt)
end

local M = saga.department(spec, { accept = accept, done = done, act = act, name = "acknowledge_qa_publication" })
M.pipeline = _G.pipeline
return M
