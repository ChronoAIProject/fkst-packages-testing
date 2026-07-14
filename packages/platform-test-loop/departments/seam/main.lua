local saga = require("workflow.saga")

local spec = {
  consumes = { "platform_loop_keepalive_tick" },
  produces = { "platform_loop_request", "platform_aggregate" },
  stall_window = "30s",
  retry = false,
}

local function done(_event)
  return false
end

local function act(_event)
  return
end

return saga.department(spec, { done = done, act = act, name = "seam" })
