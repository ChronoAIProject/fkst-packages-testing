local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "module_start" },
  published_seam = { "module_start" },
  produces = { "module-test-loop.module_loop_request" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local payload = event.payload or {}
  if core.requires_ai_consensus(payload) then
    local proposal = core.ai_generation_proposal(payload)
    log.info("testing-pipeline dept=start_module tag=AI_CONSENSUS module=" .. tostring(payload.module))
    raise("consensus.proposal", proposal)
    return
  end
  local request = core.module_loop_request(payload)
  log.info("testing-pipeline dept=start_module tag=DELEGATE module=" .. tostring(request.module))
  raise("module-test-loop.module_loop_request", request)
end

local M = saga.department(spec, { done = done, act = act, name = "start_module" })
M.pipeline = _G.pipeline
return M
