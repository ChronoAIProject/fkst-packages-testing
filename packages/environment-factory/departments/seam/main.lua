local saga = require("workflow.saga")

local spec = {
  consumes = { "environment_control_tick" },
  produces = { "environment_start", "environment_finalize", "environment_interrupt" },
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
