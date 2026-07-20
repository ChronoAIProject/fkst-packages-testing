local ai = require("ai_orchestration")
local design_loop = require("testing_ai.module_ai_design_loop")
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

local function design_case(id, subject_ids)
  return {
    id = id,
    module_id = "dashboard",
    priority = "P1",
    title = "Verify " .. id,
    objective = "Verify " .. id,
    case_kind = "read-only-interaction",
    actions = {
      { action = "open-visible-surface", target = "Dashboard", expected = "Dashboard is visible" },
    },
    expected_observable = "Dashboard remains visible.",
    coverage_subject_ids = subject_ids,
    provenance = { origin = "deterministic", source_pointer = artifact_root .. "/design/source.json" },
  }
end

local function design_fixture(model, max_rounds, extra_subject)
  local root = artifact_root .. "/design"
  local documents = {
    seed_cases = { schema = design_loop.schemas.seed_cases, cases = {} },
    deterministic_cases = { schema = design_loop.schemas.deterministic_cases, cases = { design_case("health", { "REQ-HEALTH" }) } },
    coverage_scope = {
      schema = design_loop.schemas.coverage_scope,
      subjects = {
        { id = "REQ-HEALTH", kind = "requirement", priority = "P0", evidence_pointer = root .. "/requirements.json" },
        { id = "module-dashboard", kind = "module", priority = "P1", evidence_pointer = root .. "/inventory.json" },
      },
    },
  }
  local paths = {
    seed_cases = root .. "/seed-cases.json",
    deterministic_cases = root .. "/deterministic-cases.json",
    coverage_scope = root .. "/coverage-scope.json",
  }
  if extra_subject then
    documents.coverage_scope.subjects[3] = {
      id = "repository-dashboard-route",
      kind = "repository-signal",
      priority = "P1",
      evidence_pointer = root .. "/repository-context.json",
    }
  end
  for key, path in pairs(paths) do model.writes[path] = ai.json_encode(documents[key]) end
  local function ref(key)
    return { artifact_pointer = paths[key], artifact_digest = design_loop.document_digest(documents[key]) }
  end
  return {
    schema = design_loop.schemas.request,
    artifact_root = root,
    seed_cases_ref = ref("seed_cases"),
    deterministic_cases_ref = ref("deterministic_cases"),
    coverage_scope_ref = ref("coverage_scope"),
    max_rounds = max_rounds or 3,
    case_budget = 8,
    action_budget = 24,
    trace_id = "trace-design-graph",
    dedup_key = "dedup-design-graph",
  }
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
        ai_design_loop_state_ref = {
          artifact_pointer = custom_root .. "/design-state.json",
          artifact_digest = "design-state-digest",
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
    t.eq(action.request.cdp_execution.ai_design_loop_state_ref.artifact_pointer, custom_root .. "/design-state.json")
    t.eq(action.request.cdp_execution.ai_design_loop_state_ref.artifact_digest, "design-state-digest")
    t.eq(model.writes[custom_root .. "/context.json"] ~= nil, true)
    t.eq(model.writes[custom_root .. "/generated.json"] ~= nil, true)
    t.eq(model.writes[custom_root .. "/gate.json"] ~= nil, true)
    t.eq(model.writes[custom_root .. "/generation-review.json"] ~= nil, true)
    t.eq(model.writes[custom_root .. "/execution-review.json"] ~= nil, true)
    t.eq(model.writes[custom_root .. "/closure.json"] ~= nil, true)
  end,

  test_design_graph_supplements_persists_and_replays_without_duplication = function()
    local model = memory_io()
    local started = ai.start_design_loop(design_fixture(model), model.ports)
    t.eq(started.kind, "design-round-plan")
    local round_plan = decode(model, artifact_root .. "/design/ai-design-round-plan.json")
    local patch = {
      schema = design_loop.schemas.patch,
      round = 1,
      base_round_digest = round_plan.round_digest,
      operations = {
        { operation = "add-case", case = design_case("dashboard-visible", { "module-dashboard" }) },
      },
    }
    local patch_path = artifact_root .. "/design/reviewer-patch-input.json"
    model.writes[patch_path] = ai.json_encode(patch)
    local patch_ref = { artifact_pointer = patch_path, artifact_digest = design_loop.document_digest(patch) }
    local applied = ai.apply_design_round({
      schema = ai.design_round_request_schema,
      state_ref = started.refs.state_ref,
      patch_ref = patch_ref,
      trace_id = "trace-design-graph",
      dedup_key = "dedup-design-graph",
    }, model.ports)
    t.eq(applied.kind, "design-closure")
    t.eq(model.writes[artifact_root .. "/design/rounds/1/ai-design-round-plan.json"] ~= nil, true)
    t.eq(model.writes[artifact_root .. "/design/rounds/2/ai-design-round-plan.json"] ~= nil, true)
    local closure = decode(model, artifact_root .. "/design/ai-design-closure.json")
    t.eq(closure.status, "reviewed-complete")
    local replay = ai.apply_design_round({
      schema = ai.design_round_request_schema,
      state_ref = applied.refs.state_ref,
      patch_ref = patch_ref,
    }, model.ports)
    t.eq(replay.replayed, true)
    t.eq(replay.refs.state_ref.artifact_digest, applied.refs.state_ref.artifact_digest)
  end,

  test_existing_consensus_review_enters_design_rounds_before_runner_resume = function()
    local model = memory_io()
    local start_payload = module_start()
    start_payload.cdp_execution.ai_design_loop_request = design_fixture(model, 3, true)
    local start = ai.start(start_payload, model.ports)
    local generated = ai.generate(start.request, model.ports)
    local review = ai.handle_consensus_reached(consensus_reached(generated.proposal), model.ports)
    local design = ai.handle_consensus_reached(consensus_reached(review.proposal), model.ports)
    t.eq(design.kind, "review-proposal")
    t.eq(design.proposal.source_ref.kind, "testing-ai-design-round")
    local round_plan = decode(model, artifact_root .. "/design/ai-design-round-plan.json")
    local patch = {
      schema = design_loop.schemas.patch,
      round = 1,
      base_round_digest = round_plan.round_digest,
      operations = {
        { operation = "add-case", case = design_case("dashboard-consensus-reviewed", { "module-dashboard" }) },
      },
    }
    local patch_path = artifact_root .. "/design/consensus-patch.json"
    model.writes[patch_path] = ai.json_encode(patch)
    local reached = consensus_reached(design.proposal)
    reached.patch_ref = { artifact_pointer = patch_path, artifact_digest = design_loop.document_digest(patch) }
    local next_round = ai.handle_consensus_reached(reached, model.ports)
    t.eq(next_round.kind, "review-proposal")
    local second_plan = decode(model, artifact_root .. "/design/ai-design-round-plan.json")
    local second_patch = {
      schema = design_loop.schemas.patch,
      round = 2,
      base_round_digest = second_plan.round_digest,
      operations = {
        { operation = "add-case", case = design_case("dashboard-repository-signal", { "repository-dashboard-route" }) },
      },
    }
    local second_path = artifact_root .. "/design/consensus-patch-round-2.json"
    model.writes[second_path] = ai.json_encode(second_patch)
    local second_reached = consensus_reached(next_round.proposal)
    second_reached.patch_ref = { artifact_pointer = second_path, artifact_digest = design_loop.document_digest(second_patch) }
    local resumed = ai.handle_consensus_reached(second_reached, model.ports)
    t.eq(resumed.kind, "module-loop-request")
    t.eq(resumed.request.cdp_execution.ai_design_loop_request, nil)
    t.eq(resumed.request.cdp_execution.ai_design_loop_state_ref.artifact_pointer, artifact_root .. "/design/ai-design-loop-state.json")
  end,

  test_design_consensus_rejection_fails_closed = function()
    local model = memory_io()
    local start_payload = module_start()
    start_payload.cdp_execution.ai_design_loop_request = design_fixture(model)
    local start = ai.start(start_payload, model.ports)
    local generated = ai.generate(start.request, model.ports)
    local review = ai.handle_consensus_reached(consensus_reached(generated.proposal), model.ports)
    local design = ai.handle_consensus_reached(consensus_reached(review.proposal), model.ports)
    local blocked = ai.handle_consensus_reached(consensus_reached(design.proposal, "reject"), model.ports)
    t.eq(blocked.kind, "blocked-result")
    local state = decode(model, artifact_root .. "/ai-orchestration-state.json")
    t.eq(state.design.status, "blocked")
  end,

  test_design_graph_preserves_completed_round_on_conflict_or_digest_mismatch = function()
    local model = memory_io()
    local started = ai.start_design_loop(design_fixture(model), model.ports)
    local original_state = model.writes[started.refs.state_ref.artifact_pointer]
    local round_plan = decode(model, artifact_root .. "/design/ai-design-round-plan.json")
    local patch = {
      schema = design_loop.schemas.patch,
      round = 1,
      base_round_digest = round_plan.round_digest,
      operations = {},
      findings = {
        schema = design_loop.schemas.reviewer_findings,
        findings = {
          { subject_id = "module-dashboard", status = "blocked", rationale = "Missing browser evidence." },
          { subject_id = "module-dashboard", status = "covered", rationale = "Reviewer disagrees." },
        },
      },
    }
    local patch_path = artifact_root .. "/design/conflicting-patch.json"
    model.writes[patch_path] = ai.json_encode(patch)
    t.raises(function()
      ai.apply_design_round({
        schema = ai.design_round_request_schema,
        state_ref = started.refs.state_ref,
        patch_ref = { artifact_pointer = patch_path, artifact_digest = design_loop.document_digest(patch) },
      }, model.ports)
    end)
    t.eq(model.writes[started.refs.state_ref.artifact_pointer], original_state)
    t.raises(function()
      ai.apply_design_round({
        schema = ai.design_round_request_schema,
        state_ref = { artifact_pointer = started.refs.state_ref.artifact_pointer, artifact_digest = "wrong-digest" },
        patch_ref = { artifact_pointer = patch_path, artifact_digest = design_loop.document_digest(patch) },
      }, model.ports)
    end)
  end,

  test_design_graph_emits_round_limit_residual_risk_for_missing_evidence = function()
    local model = memory_io()
    local started = ai.start_design_loop(design_fixture(model, 1), model.ports)
    t.eq(started.kind, "design-closure")
    local closure = decode(model, artifact_root .. "/design/ai-design-closure.json")
    local residual = decode(model, artifact_root .. "/design/residual-risk.json")
    t.eq(closure.status, "round-limit")
    t.eq(residual.unresolved[1].status, "missing-evidence")
    t.eq(closure.residual_risk_digest, design_loop.document_digest(residual))
  end,

  test_design_graph_rejects_malformed_round_requests_and_json = function()
    t.raises(function() ai.json_decode("{") end)
    t.raises(function() ai.json_decode("x") end)
    t.raises(function() ai.apply_design_round({}, memory_io().ports) end)
    t.raises(function()
      ai.apply_design_round({ schema = ai.design_round_request_schema, unsupported = true }, memory_io().ports)
    end)
  end,
}
