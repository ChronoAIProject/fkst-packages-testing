local saga = require("workflow.saga")

local spec = {
  consumes = { "local_qa_host_tick" },
  produces = { "qa_run_request" },
  stall_window = "30s",
  retry = false,
}

local function act(_event)
  return
end

return saga.department(spec, {
  done = function() return false end,
  act = act,
  name = "seam",
})
