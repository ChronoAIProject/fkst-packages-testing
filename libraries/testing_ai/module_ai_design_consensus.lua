local strings = require("contract.strings")
local design_loop = require("testing_ai.module_ai_design_loop")

local M = {}

function M.copy_request(value)
  if value == nil then return nil end
  design_loop.validate_request(value)
  return {
    schema = value.schema,
    artifact_root = value.artifact_root,
    seed_cases_ref = { artifact_pointer = value.seed_cases_ref.artifact_pointer, artifact_digest = value.seed_cases_ref.artifact_digest },
    coverage_scope_ref = { artifact_pointer = value.coverage_scope_ref.artifact_pointer, artifact_digest = value.coverage_scope_ref.artifact_digest },
    deterministic_cases_ref = { artifact_pointer = value.deterministic_cases_ref.artifact_pointer, artifact_digest = value.deterministic_cases_ref.artifact_digest },
    max_rounds = value.max_rounds,
    case_budget = value.case_budget,
    action_budget = value.action_budget,
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
  }
end

function M.round_proposal(state, result)
  local digest = result.refs.round_plan_ref.artifact_digest
  return {
    schema = "consensus.proposal.v1",
    proposal_id = "testing-ai/design-round/" .. tostring(result.round) .. "/" .. strings.decimal_checksum(digest),
    title = "Review FKST test-design coverage round " .. tostring(result.round),
    body = table.concat({
      "Review the persisted FKST test-design round and publish one structured supplementation patch artifact.",
      "Do not return inline test cases, requirements, repository content, browser state, or narrative as execution authority.",
      "State: " .. tostring(result.refs.state_ref.artifact_pointer),
      "Coverage matrix: " .. tostring(result.refs.coverage_matrix_ref.artifact_pointer),
      "Round plan: " .. tostring(result.refs.round_plan_ref.artifact_pointer),
      "The consensus result must carry patch_ref with artifact_pointer and artifact_digest.",
    }, "\n"),
    context = "artifact_root=" .. tostring(state.artifact_root) .. " round=" .. tostring(result.round),
    dedup_key = "testing-ai/design-round/" .. strings.decimal_checksum(tostring(state.module_start.dedup_key or "") .. ":" .. digest),
    source_ref = { kind = "testing-ai-design-round", ref = state.artifact_root },
    verdict_mode = "converge",
  }
end

return M
