local ai = require("ai_orchestration")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"
local artifact_root = ".testing/runs/module-a-ai-orchestration"

local function candidate_document(overrides)
  local case = {
    module_id = "dashboard",
    priority = "P1",
    title = "Navigate the dashboard detail surface",
    objective = "Verify bounded navigation exposes the dashboard detail surface.",
    case_kind = "primary-interaction",
    actions = {
      {
        action = "bounded-navigation",
        target = fixture_base_url .. "/dashboard/detail",
        expected = "The dashboard detail surface becomes visible.",
      },
      {
        action = "open-visible-surface",
        target = "Dashboard details",
        expected = "The detail surface opens without leaving local scope.",
      },
    },
    expected_observable = "The dashboard detail surface is visible and stable.",
  }
  for key, value in pairs(overrides or {}) do case[key] = value end
  return {
    schema = "testing-runner.ai-case-candidates.v1",
    cases = { case },
  }
end

local function memory_io(candidate, exit_code)
  local writes = {}
  return {
    writes = writes,
    ports = {
      absolute_path = function(path)
        return "/repo/" .. path
      end,
      generate = function()
        return {
          exit_code = exit_code or 0,
          stdout = ai.json_encode(candidate or candidate_document()),
          stderr = "",
        }
      end,
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
  for path, body in pairs(model.writes) do table.insert(parts, path .. "\n" .. body) end
  return table.concat(parts, "\n")
end

local function module_start(overrides)
  local value = {
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
    artifact_root = artifact_root,
    source_ref = { kind = "external", ref = "module-a" },
    trace_id = "trace-module-a-ai",
    dedup_key = "module-a-ai-run",
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function consensus_reached(proposal, decision)
  local verdict = decision or "approve"
  return {
    schema = "consensus.consensus_reached.v1",
    proposal_id = proposal.proposal_id,
    decision = verdict,
    body = "raw_prompt token password raw_response must not persist",
    source_ref = proposal.source_ref,
    angle_results = {
      { angle = "teleology", verdict = verdict },
      { angle = "parsimony", verdict = verdict },
      { angle = "fidelity", verdict = verdict },
      { angle = "natural-ownership", verdict = verdict },
      { angle = "proportional-containment", verdict = verdict },
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

local function author(model)
  local start = ai.start(module_start(), model.ports)
  t.eq(start.kind, "generation-request")
  local generated = ai.generate(start.request, model.ports)
  t.eq(generated.kind, "generation-proposal")
  return generated.proposal
end

local function approve_generation(model, generation_proposal)
  local action = ai.handle_consensus_reached(consensus_reached(generation_proposal), model.ports)
  t.eq(action.kind, "review-proposal")
  return action.proposal
end

return {
  test_start_writes_sanitized_context_and_authoring_request = function()
    local model = memory_io()
    local action = ai.start(module_start(), model.ports)
    t.eq(action.kind, "generation-request")
    t.eq(action.request.schema, "testing-pipeline.ai-generation-request.v1")
    t.eq(action.request.context_manifest_path, artifact_root .. "/ai-context-manifest.json")

    local context = decode(model, artifact_root .. "/ai-context-manifest.json")
    local state = decode(model, artifact_root .. "/ai-orchestration-state.json")
    t.eq(context.base_url, fixture_base_url)
    t.eq(context.modules[1].entry_url, fixture_base_url .. "/dashboard")
    t.eq(state.phase, "authoring")
    t.eq(state.module_start.cdp_execution.generated_cases, nil)
    t.eq(state.module_start.cdp_execution.ai_agent_generation, nil)
    t.eq(state.module_start.cdp_execution.generated_case_agent_review, nil)
    t.eq(state.module_start.preflight_result.sessions[2].cdp_url, "http://127.0.0.1:9222")
    t.eq(state.module_start.preflight_result.sessions[3].cdp_url, nil)
    t.eq(all_writes(model):find("secret", 1, true), nil)
    t.eq(all_writes(model):find("raw_dom", 1, true), nil)
  end,

  test_author_persists_non_template_cases_before_adversarial_review = function()
    local model = memory_io()
    local proposal = author(model)
    t.eq(proposal.schema, "consensus.proposal.v1")
    t.eq(proposal.verdict_mode, "converge")
    t.eq(proposal.angles, nil)
    t.eq(proposal.source_ref.kind, "testing-ai-generation")
    t.is_true(proposal.content_fetch:find("AI-authored generated cases", 1, true) ~= nil)
    t.is_true(proposal.content_fetch:find("UNTRUSTED-NOTICE.txt", 1, true) ~= nil)

    local generated = decode(model, artifact_root .. "/generated-test-cases.json")
    t.eq(generated.case_count, 1)
    t.eq(generated.cases[1].actions[1].action, "bounded-navigation")
    t.eq(generated.cases[1].actions[2].action, "open-visible-surface")
    t.eq(generated.cases[1].provenance.origin, "ai-generated")
    t.eq(generated.cases[1].id:find("dashboard:ai-", 1, true), 1)
  end,

  test_invalid_or_failed_author_output_blocks_before_consensus = function()
    local model = memory_io({ schema = "wrong", cases = {} })
    local start = ai.start(module_start(), model.ports)
    local action = ai.generate(start.request, model.ports)
    t.eq(action.kind, "blocked-result")
    t.eq(action.result.status, "blocked")

    model = memory_io(candidate_document(), 1)
    start = ai.start(module_start(), model.ports)
    action = ai.generate(start.request, model.ports)
    t.eq(action.kind, "blocked-result")
    t.eq(action.result.status, "blocked")
  end,

  test_generation_approval_runs_deterministic_gate_then_proposes_execution_review = function()
    local model = memory_io()
    local generation_proposal = author(model)
    local review_proposal = approve_generation(model, generation_proposal)
    t.eq(review_proposal.verdict_mode, "gate")
    t.eq(review_proposal.angles, nil)
    t.eq(review_proposal.source_ref.kind, "testing-ai-review")
    t.is_true(review_proposal.content_fetch:find("Deterministic generated-case gate", 1, true) ~= nil)

    local gate = decode(model, artifact_root .. "/generated-case-gate.json")
    local agent_generation = decode(model, artifact_root .. "/ai-agent-generation.json")
    local state = decode(model, artifact_root .. "/ai-orchestration-state.json")
    t.eq(gate.executable_count, 1)
    t.eq(agent_generation.generated_case_count, 1)
    t.eq(agent_generation.seat_count, 5)
    t.eq(state.phase, "review-proposed")
  end,

  test_missing_authored_artifact_blocks_instead_of_regenerating = function()
    local model = memory_io()
    local generation_proposal = author(model)
    local review_proposal = approve_generation(model, generation_proposal)
    model.writes[artifact_root .. "/generated-test-cases.json"] = nil
    local action = ai.handle_consensus_reached(consensus_reached(review_proposal), model.ports)
    t.eq(action.kind, "blocked-result")
    t.eq(action.result.status, "blocked")
    t.eq(model.writes[artifact_root .. "/generated-test-cases.json"], nil)
  end,

  test_reject_and_converge_fail_closed = function()
    local model = memory_io()
    local generation_proposal = author(model)
    local rejected = ai.handle_consensus_reached(consensus_reached(generation_proposal, "reject"), model.ports)
    t.eq(rejected.kind, "blocked-result")

    model = memory_io()
    generation_proposal = author(model)
    local converged = ai.handle_consensus_converge(consensus_converge(generation_proposal), model.ports)
    t.eq(converged.kind, "blocked-result")

    model = memory_io()
    generation_proposal = author(model)
    local review_proposal = approve_generation(model, generation_proposal)
    local review_rejected = ai.handle_consensus_reached(consensus_reached(review_proposal, "reject"), model.ports)
    t.eq(review_rejected.kind, "blocked-result")
  end,

  test_consensus_narrative_is_not_persisted = function()
    local model = memory_io()
    local generation_proposal = author(model)
    local review_proposal = approve_generation(model, generation_proposal)
    local action = ai.handle_consensus_reached(consensus_reached(review_proposal), model.ports)
    t.eq(action.kind, "module-loop-request")
    local body = all_writes(model)
    t.eq(body:find("raw_prompt", 1, true), nil)
    t.eq(body:find("raw_response", 1, true), nil)
    t.eq(body:find("password", 1, true), nil)
  end,

  test_custom_ai_artifact_paths_flow_into_resume_request = function()
    local custom_root = artifact_root .. "/custom"
    local model = memory_io()
    local start_payload = module_start({
      cdp_execution = {
        schema = "testing-runner.module-cdp-execution.v1",
        step_budget = 8,
        case_priorities = { "P0", "P1" },
        ai_generation = {
          schema = "testing-runner.ai-case-generation.request.v1",
          mode = "autonomous-reviewed",
          case_budget = 1,
          context_manifest_path = custom_root .. "/context.json",
          generated_cases_path = custom_root .. "/generated.json",
          generated_case_gate_path = custom_root .. "/gate.json",
          ai_agent_generation_path = custom_root .. "/generation-review.json",
          generated_case_agent_review_path = custom_root .. "/execution-review.json",
          ai_test_design_loop_path = custom_root .. "/closure.json",
        },
      },
    })
    local start = ai.start(start_payload, model.ports)
    t.eq(start.kind, "generation-request")
    t.eq(start.request.context_manifest_path, custom_root .. "/context.json")
    local generated_action = ai.generate(start.request, model.ports)
    if generated_action.kind ~= "generation-proposal" then
      error(decode(model, artifact_root .. "/ai-orchestration-state.json").blocked_error or "generation did not produce proposal")
    end
    local generated_proposal = generated_action.proposal
    local review_proposal = ai.handle_consensus_reached(consensus_reached(generated_proposal), model.ports).proposal
    local action = ai.handle_consensus_reached(consensus_reached(review_proposal), model.ports)
    t.eq(action.kind, "module-loop-request")
    t.eq(action.request.cdp_execution.ai_generation.context_manifest_path, custom_root .. "/context.json")
    t.eq(action.request.cdp_execution.ai_generation.generated_cases_path, custom_root .. "/generated.json")
    t.eq(action.request.cdp_execution.ai_generation.generated_case_gate_path, custom_root .. "/gate.json")
    t.eq(action.request.cdp_execution.ai_generation.ai_agent_generation_path, custom_root .. "/generation-review.json")
    t.eq(action.request.cdp_execution.ai_generation.generated_case_agent_review_path, custom_root .. "/execution-review.json")
    t.eq(action.request.cdp_execution.ai_generation.ai_test_design_loop_path, custom_root .. "/closure.json")
    t.eq(model.writes[custom_root .. "/context.json"] ~= nil, true)
    t.eq(model.writes[custom_root .. "/generated.json"] ~= nil, true)
    t.eq(model.writes[custom_root .. "/gate.json"] ~= nil, true)
    t.eq(model.writes[custom_root .. "/generation-review.json"] ~= nil, true)
    t.eq(model.writes[custom_root .. "/execution-review.json"] ~= nil, true)
    t.eq(model.writes[custom_root .. "/closure.json"] ~= nil, true)
  end,
}
