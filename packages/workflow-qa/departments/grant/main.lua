local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "execution_grant_result" },
  published_seam = { "execution_grant_result" },
  produces = {
    "testing-runner.structured_execution_request",
    "testing-runner.ai_browser_control_request",
    "environment-factory.environment_finalize",
    "environment-factory.environment_interrupt",
  },
  stall_window = "5m",
  retry = false,
}

local function accept(event)
  local source = ((event or {}).payload or {}).source_ref
  local payload = (event or {}).payload or {}
  return payload.status ~= nil and type(source) == "table"
    and source.kind == "workflow-qa"
end

local function act(event)
  local raised = core.handle_grant_result(event.payload or {}, nil, event.test_ports)
  log.info("workflow-qa dept=grant tag=EXECUTE actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, name = "grant" })
