local actions = require("departments.actions")
local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "browser-readiness.browser_readiness_result" },
  produces = {
    "test-publication.qa_checkpoint_request",
    "module-testing-pipeline.module_start",
    "environment-factory.environment_finalize",
    "environment-factory.environment_interrupt",
  },
  fanout = { "browser-readiness.browser_readiness_result" },
  stall_window = "5m",
  retry = false,
}

local function accept(event)
  local payload = (event or {}).payload or {}
  return payload.schema == "browser-readiness.result.v1"
    and type(payload.source_ref) == "table"
    and payload.source_ref.kind == "workflow-qa"
end

local function act(event)
  local raised = core.handle_browser_readiness_result(event.payload or {}, nil, event.test_ports)
  log.info("workflow-qa dept=browser_readiness tag=GATE actions=" .. tostring(#raised))
  actions.raise_all(raised)
end

return saga.department(spec, {
  accept = accept,
  done = function() return false end,
  act = act,
  name = "browser_readiness",
})
