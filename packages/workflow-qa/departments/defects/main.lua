local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "test-publication.defect_publication_terminal" },
  produces = { "environment-factory.environment_finalize", "environment-factory.environment_interrupt" },
  stall_window = "10m", retry = false,
}

local function act(event)
  local raised = core.handle_defect_terminal(event.payload or {}, nil, event.test_ports)
  log.info("workflow-qa dept=defects tag=CLEANUP actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { done = function() return false end, act = act, name = "defects" })
