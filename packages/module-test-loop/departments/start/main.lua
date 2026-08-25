local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "module_loop_request" },
  published_seam = { "module_loop_request" },
  produces = { "testing-runner.module_test_request", "module_loop_terminal" },
  stall_window = "5m",
  retry = false,
}

local function act(event)
  local actions = core.start(event.payload or {}, event.test_ports)
  for _, item in ipairs(actions) do raise(item.queue, item.payload) end
  log.info("module-test-loop dept=start tag=DISPATCH actions=" .. tostring(#actions))
end

local M = saga.department(spec, { done = function() return false end, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "module-test-loop.start" })
M.pipeline = _G.pipeline
return M
