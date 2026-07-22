local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "module_loop_keepalive_tick" },
  produces = { "module_loop_request", "testing-runner.module_test_request", "module_loop_terminal" },
  stall_window = "30s",
  retry = false,
}

local function act(event)
  local actions = core.redrive(event.payload or {}, event.test_ports)
  for _, item in ipairs(actions) do raise(item.queue, item.payload) end
  log.info("module-test-loop dept=seam tag=REDRIVE actions=" .. tostring(#actions))
end

return saga.department(spec, { done = function() return false end, act = act, name = "seam" })
