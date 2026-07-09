local core = require("core")
local saga = require("workflow.saga")

local spec = {
  consumes = { "consensus.consensus_reached", "consensus.consensus_converge" },
  produces = {
    "consensus.proposal",
    "module-test-loop.module_loop_request",
    "testing_result",
  },
  fanout = { "consensus.consensus_reached", "consensus.consensus_converge" },
  stall_window = "5m",
  retry = false,
}

local function done(event)
  return not core.is_testing_ai_consensus(event.payload or {})
end

local function raise_action(action)
  if action.kind == "review-proposal" then
    raise("consensus.proposal", action.proposal)
    return
  end
  if action.kind == "module-loop-request" then
    raise("module-test-loop.module_loop_request", action.request)
    return
  end
  if action.kind == "blocked-result" then
    raise("testing_result", action.result)
    return
  end
end

local function act(event)
  local payload = event.payload or {}
  local action
  if payload.schema == "consensus.consensus_reached.v1" then
    action = core.handle_ai_consensus_reached(payload)
  elseif payload.schema == "consensus.consensus_converge.v1" then
    action = core.handle_ai_consensus_converge(payload)
  else
    return
  end
  log.info("testing-pipeline dept=ai_consensus tag=" .. tostring(action.kind))
  raise_action(action)
end

local M = saga.department(spec, { done = done, act = act, name = "ai_consensus" })
M.pipeline = _G.pipeline
return M
