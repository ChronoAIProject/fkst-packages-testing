local core = require("core")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "ai_consensus_result" },
  produces = {
    "ai_consensus_request",
    "module-test-loop.module_loop_request",
    "testing_result",
  },
  stall_window = "5m",
  retry = false,
}

local function done(event)
  return not core.is_testing_ai_consensus(event.payload or {})
end

local function raise_action(action)
  if action.kind == "review-proposal" then
    raise("ai_consensus_request", action.proposal)
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
  log.info("module-testing-pipeline dept=ai_consensus tag=" .. tostring(action.kind))
  raise_action(action)
end

local M = saga.department(spec, { done = done, act = act, wrap = workflow_logging.wrap_pipeline_failure, name = "module-testing-pipeline.ai_consensus" })
M.pipeline = _G.pipeline
return M
