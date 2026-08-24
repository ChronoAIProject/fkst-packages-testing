local consensus = require("consensus")
local saga = require("workflow.saga")
local workflow_logging = require("workflow.logging")

local spec = {
  consumes = { "ai_consensus_request" },
  produces = { "ai_consensus_result" },
  stall_window = "5m",
  retry = false,
}

local function done(_event)
  return false
end

local function act(event)
  local proposal = event.payload or {}
  local ports = event.test_ports or {}
  local reach = ports.consensus_reach or consensus.reach
  local result = reach(proposal)
  if result == nil then
    return
  end

  local payload = {}
  for key, value in pairs(result) do
    if key ~= "status" then
      payload[key] = value
    end
  end
  payload.proposal_id = proposal.proposal_id
  raise("ai_consensus_result", payload)
end

local M = saga.department(spec, {
  done = done,
  act = act,
  wrap = workflow_logging.wrap_pipeline_failure,
  name = "module-testing-pipeline.ai_consensus_call",
})
M.pipeline = _G.pipeline
return M
