local ai = require("ai_orchestration")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"

local function memory_io()
  local writes = {}
  return {
    writes = writes,
    ports = {
      read = function(path)
        local body = writes[path]
        if body == nil then error("missing artifact " .. tostring(path)) end
        return body
      end,
      write = function(path, body)
        writes[path] = body
        return true
      end,
    },
  }
end

local function decode(model, path)
  return ai.json_decode(assert(model.writes[path], "missing write " .. path))
end

local function all_writes(model)
  local parts = {}
  for path, body in pairs(model.writes) do
    table.insert(parts, path .. "\n" .. body)
  end
  return table.concat(parts, "\n")
end

local function module_start(overrides)
  local payload = {
    schema = "testing-pipeline.module-start.v1",
    module = "module-a",
    backend = "fkst-native",
    dry_run = false,
    ui_loop = {
      base_url = fixture_base_url .. "?token=secret#frag",
      allowed_origins = { fixture_origin .. "?token=secret" },
      mutation_policy = "read-only",
      browser_readiness_ref = ".testing/runs/readiness/module-a",
      cdp_readiness_ref = "cdp-ready",
      gap_ref = ".testing/runs/gap/module-a",
    },
    module_discovery = {
      schema = "testing-runner.module-discovery.v1",
      observations = {
        {
          id = "dashboard",
          name = "Dashboard",
          entry_url = fixture_base_url .. "/dashboard?token=secret#state",
          visible_label = "Dashboard",
          discovery_source = "navigation",
          confidence = "high",
          evidence_pointer = ".testing/runs/evidence/dashboard",
        },
      },
      limitations = { "Visible-session coverage only." },
    },
    preflight_result = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "admin", status = "ready", cdp_url = "http://127.0.0.1:9222" },
        { role = "external", status = "ready", cdp_url = "http://browser.example:9222" },
      },
      request = { raw_dom = "must not persist" },
    },
    cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 8,
      case_priorities = { "P0", "P1" },
      generated_cases = { unsafe = true },
      ai_agent_generation = { unsafe = true },
      generated_case_agent_review = { unsafe = true },
      ai_generation = {
        schema = "testing-runner.ai-case-generation.request.v1",
        mode = "autonomous-reviewed",
        case_budget = 1,
      },
    },
    artifact_root = ".testing/runs/module-a-ai-orchestration",
    source_ref = { kind = "external", ref = "module-a" },
    trace_id = "trace-module-a-ai",
    dedup_key = "module-a-ai-run",
  }
  for key, item in pairs(overrides or {}) do payload[key] = item end
  return payload
end

local function consensus_reached(proposal, decision)
  return {
    schema = "consensus.consensus_reached.v1",
    proposal_id = proposal.proposal_id,
    decision = decision or "approve",
    body = "raw_prompt token password raw_response must not persist",
    source_ref = proposal.source_ref,
    angle_results = {
      { angle = "teleology", verdict = decision or "approve" },
      { angle = "parsimony", verdict = decision or "approve" },
    },
  }
end

local function consensus_converge(proposal)
  return {
    schema = "consensus.consensus_converge.v1",
    proposal_id = proposal.proposal_id,
    source_ref = proposal.source_ref,
    narrowed_question = "bounded follow-up",
  }
end

local function start(model, payload)
  local action = ai.start(payload or module_start(), model.ports)
  t.eq(action.kind, "generation-proposal")
  return action.proposal
end

local function approve_generation(model, generation_proposal)
  local action = ai.handle_consensus_reached(consensus_reached(generation_proposal), model.ports)
  t.eq(action.kind, "review-proposal")
  return action.proposal
end

return {
  test_start_writes_pointer_only_context_and_state = function()
    local model = memory_io()
    local proposal = start(model)
    t.eq(proposal.schema, "consensus.proposal.v1")
    t.eq(proposal.verdict_mode, "converge")
    t.eq(proposal.angles, nil)
    t.eq(proposal.source_ref.kind, "testing-ai-generation")

    local context = decode(model, ".testing/runs/module-a-ai-orchestration/ai-context-manifest.json")
    t.eq(context.schema, "testing-runner.ai-context-manifest.v1")
    t.eq(context.base_url, fixture_base_url)
    t.eq(context.modules[1].entry_url, fixture_base_url .. "/dashboard")

    local state = decode(model, ".testing/runs/module-a-ai-orchestration/ai-orchestration-state.json")
    t.eq(state.schema, "testing-pipeline.ai-orchestration-state.v1")
    t.eq(state.phase, "generation-proposed")
    t.eq(state.module_start.ui_loop.base_url, fixture_base_url)
    t.eq(state.module_start.module_discovery.observations[1].entry_url, fixture_base_url .. "/dashboard")
    t.eq(state.module_start.preflight_result.sessions[2].cdp_url, "http://127.0.0.1:9222")
    t.eq(state.module_start.preflight_result.sessions[3].cdp_url, nil)
    t.eq(state.module_start.cdp_execution.generated_cases, nil)
    t.eq(state.module_start.cdp_execution.ai_agent_generation, nil)
    t.eq(state.module_start.cdp_execution.generated_case_agent_review, nil)
    t.eq(all_writes(model):find("secret", 1, true), nil)
    t.eq(all_writes(model):find("token", 1, true), nil)
    t.eq(all_writes(model):find("raw_dom", 1, true), nil)
  end,

  test_start_preserves_only_explicit_bounded_consensus_angles = function()
    local model = memory_io()
    local payload = module_start()
    payload.cdp_execution.ai_generation.consensus_angles = { "teleology", "parsimony" }
    local proposal = start(model, payload)
    t.eq(#proposal.angles, 2)
    t.eq(proposal.angles[1], "teleology")

    local blocked_model = memory_io()
    payload = module_start()
    payload.cdp_execution.ai_generation.consensus_angles = { "a", "b", "c", "d", "e" }
    local action = ai.start(payload, blocked_model.ports)
    t.eq(action.kind, "blocked-result")
    t.eq(action.result.status, "blocked")
  end,

  test_generation_approval_writes_cases_gate_and_review_proposal = function()
    local model = memory_io()
    local generation_proposal = start(model)
    local review_proposal = approve_generation(model, generation_proposal)
    t.eq(review_proposal.schema, "consensus.proposal.v1")
    t.eq(review_proposal.verdict_mode, "gate")
    t.eq(review_proposal.source_ref.kind, "testing-ai-review")

    local generated = decode(model, ".testing/runs/module-a-ai-orchestration/generated-test-cases.json")
    local gate = decode(model, ".testing/runs/module-a-ai-orchestration/generated-case-gate.json")
    local agent_generation = decode(model, ".testing/runs/module-a-ai-orchestration/ai-agent-generation.json")
    local state = decode(model, ".testing/runs/module-a-ai-orchestration/ai-orchestration-state.json")
    t.eq(generated.schema, "testing-runner.generated-test-cases.v1")
    t.eq(generated.case_count, 1)
    t.eq(gate.schema, "testing-runner.generated-case-gate.v1")
    t.eq(gate.executable_count, 1)
    t.eq(agent_generation.schema, "testing-runner.ai-agent-generation.v1")
    t.eq(agent_generation.generated_case_count, generated.case_count)
    t.eq(agent_generation.seat_count, 2)
    t.eq(state.phase, "review-proposed")
  end,

  test_review_approval_writes_review_closure_and_resumes_module_loop = function()
    local model = memory_io()
    local generation_proposal = start(model)
    local review_proposal = approve_generation(model, generation_proposal)
    local action = ai.handle_consensus_reached(consensus_reached(review_proposal), model.ports)
    t.eq(action.kind, "module-loop-request")
    local request = action.request
    t.eq(request.schema, "module-test-loop.start.v1")
    t.eq(request.module, "module-a")
    t.eq(request.cdp_execution.generated_cases.schema, "testing-runner.generated-test-cases.v1")
    t.eq(request.cdp_execution.ai_agent_generation.schema, "testing-runner.ai-agent-generation.v1")
    t.eq(request.cdp_execution.generated_case_agent_review.schema, "testing-runner.generated-case-agent-review.v1")
    t.eq(request.cdp_execution.generated_case_agent_review.approved_case_count, 1)

    local closure = decode(model, ".testing/runs/module-a-ai-orchestration/ai-test-design-loop.json")
    local state = decode(model, ".testing/runs/module-a-ai-orchestration/ai-orchestration-state.json")
    t.eq(closure.schema, "testing-runner.ai-test-design-loop.v1")
    t.eq(closure.status, "reviewed")
    t.eq(closure.execution_eligible_generated_case_count, 1)
    t.eq(state.phase, "resumed")
  end,

  test_review_approval_recomputes_missing_generated_and_gate_artifacts = function()
    local model = memory_io()
    local generation_proposal = start(model)
    local review_proposal = approve_generation(model, generation_proposal)
    model.writes[".testing/runs/module-a-ai-orchestration/generated-test-cases.json"] = nil
    model.writes[".testing/runs/module-a-ai-orchestration/generated-case-gate.json"] = nil
    local action = ai.handle_consensus_reached(consensus_reached(review_proposal), model.ports)
    t.eq(action.kind, "module-loop-request")
    t.eq(decode(model, ".testing/runs/module-a-ai-orchestration/generated-test-cases.json").case_count, 1)
    t.eq(decode(model, ".testing/runs/module-a-ai-orchestration/generated-case-gate.json").executable_count, 1)
  end,

  test_generation_and_review_reject_or_converge_fail_closed = function()
    local model = memory_io()
    local generation_proposal = start(model)
    local rejected = ai.handle_consensus_reached(consensus_reached(generation_proposal, "reject"), model.ports)
    t.eq(rejected.kind, "blocked-result")
    t.eq(rejected.result.status, "blocked")
    t.eq(decode(model, ".testing/runs/module-a-ai-orchestration/ai-orchestration-state.json").phase, "blocked")

    model = memory_io()
    generation_proposal = start(model)
    local converged = ai.handle_consensus_converge(consensus_converge(generation_proposal), model.ports)
    t.eq(converged.kind, "blocked-result")
    t.eq(converged.result.status, "blocked")

    model = memory_io()
    generation_proposal = start(model)
    local review_proposal = approve_generation(model, generation_proposal)
    local review_rejected = ai.handle_consensus_reached(consensus_reached(review_proposal, "reject"), model.ports)
    t.eq(review_rejected.kind, "blocked-result")
    t.eq(review_rejected.result.status, "blocked")
  end,

  test_consensus_body_forbidden_terms_are_not_persisted = function()
    local model = memory_io()
    local generation_proposal = start(model)
    local review_proposal = approve_generation(model, generation_proposal)
    local action = ai.handle_consensus_reached(consensus_reached(review_proposal), model.ports)
    t.eq(action.kind, "module-loop-request")
    local body = all_writes(model)
    t.eq(body:find("raw_prompt", 1, true), nil)
    t.eq(body:find("raw_response", 1, true), nil)
    t.eq(body:find("password", 1, true), nil)
    t.eq(body:find("token", 1, true), nil)
  end,
}
