local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "test-publication.qa_publication_receipt" },
  produces = { "workflow_qa_terminal_request" },
  fanout = { "test-publication.qa_publication_receipt" }, stall_window = "10m", retry = false,
}

local function accept(event)
  local payload = (event or {}).payload or {}
  return payload.stage == "aggregate-report"
end

local function act(event)
  local raised = core.handle_publication_receipt(event.payload or {}, nil, event.test_ports)
  log.info("workflow-qa dept=publication tag=TERMINAL actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, name = "publication" })
