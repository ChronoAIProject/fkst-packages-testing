local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "testing-runner.testing_result" },
  produces = { "testing-runner.module_test_request", "module_loop_terminal" },
  fanout = { "testing-runner.testing_result" },
  stall_window = "5m",
  retry = false,
}

local function accept(event)
  local source = ((event or {}).payload or {}).source_ref
  return type(source) == "table" and source.kind == "module-test-loop-attempt"
end

local function act(event)
  local actions = core.handle_result(event.payload or {}, event.test_ports)
  for _, item in ipairs(actions) do raise(item.queue, item.payload) end
  log.info("module-test-loop dept=result tag=ADVANCE actions=" .. tostring(#actions))
end

return saga.department(spec, { accept = accept, done = function() return false end, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "module-test-loop.result" })
