local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "ai_generation_request" },
  produces = {
    "consensus.proposal",
    "testing_result",
  },
  stall_window = "30m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local action = core.generate_ai_cases(event.payload or {})
  if action.kind == "generation-proposal" then
    log.info("module-testing-pipeline dept=ai_generate tag=AI_GENERATED")
    raise("consensus.proposal", action.proposal)
    return
  end
  if action.kind == "blocked-result" then
    log.info("module-testing-pipeline dept=ai_generate tag=AI_BLOCKED")
    raise("testing_result", action.result)
  end
end

local M = saga.department(spec, { done = done, act = act, name = "ai_generate" })
M.pipeline = _G.pipeline
return M
