local ai = require("module_ai_generation")
local planning = require("module_planning")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"

local function inventory(overrides)
  local value = {
    schema = "testing-runner.module-inventory.v1",
    artifact_kind = "module-inventory",
    discovery_status = "complete",
    artifact_root = ".testing/runs/module-a-inventory",
    modules = {
      {
        id = "dashboard",
        name = "Dashboard",
        entry_url = fixture_base_url .. "/dashboard?secret=value#state",
        route = "/app/dashboard",
        visible_label = "Dashboard",
        discovery_source = "navigation",
        confidence = "high",
        evidence_pointer = ".testing/runs/evidence/dashboard",
        feature_signals = { "entry-route", "visible-label-or-route", "local-session-evidence", "search-or-filter-control" },
      },
    },
    module_count = 1,
    limitations = { "Visible-session coverage only." },
    coverage = "visible-session-only",
    readiness = { status = "ready" },
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function ui_loop(overrides)
  local value = {
    base_url = fixture_base_url .. "?token=redacted#frag",
    allowed_origins = { fixture_origin },
    mutation_policy = "read-only",
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function generated_case(overrides)
  local value = {
    id = "dashboard:ai-visible-surface",
    module_id = "dashboard",
    priority = "P1",
    title = "Exercise visible surface for Dashboard",
    objective = "Exercise visible surface for Dashboard",
    case_kind = "read-only-interaction",
    actions = {
      {
        action = "open-visible-surface",
        target = "Dashboard",
        expected = "visible surface opens without mutation",
        evidence_pointer = ".testing/runs/evidence/dashboard",
      },
    },
    expected_observable = "Dashboard remains visible and same-origin.",
    evidence_pointers = { ".testing/runs/evidence/dashboard" },
    provenance = {
      origin = "ai-generated",
      context_manifest_path = ".testing/runs/module-a-inventory/ai-context-manifest.json",
      prompt_template_ref = "testing-runner.ai-case-generation.prompt.v1",
      model_invocation_digest = "ai-dashboard-surface",
    },
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function generated_payload(case_overrides)
  return {
    schema = ai.generated_cases_schema,
    artifact_kind = "generated-test-cases",
    artifact_root = ".testing/runs/module-a-inventory",
    context_manifest_path = ".testing/runs/module-a-inventory/ai-context-manifest.json",
    prompt_template_ref = "testing-runner.ai-case-generation.prompt.v1",
    generation_mode = "draft",
    generation_digest = "gen-dashboard",
    cases = { generated_case(case_overrides) },
    case_count = 1,
  }
end

local function ai_request(overrides)
  local value = {
    schema = ai.request_schema,
    mode = "draft",
    case_budget = 4,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function consensus_reached(overrides)
  local value = {
    schema = "consensus.consensus_reached.v1",
    proposal_id = "testing-ai-generation",
    decision = "approve",
    body = "approved",
    source_ref = { kind = "testing-ai-generation", ref = ".testing/runs/module-a-inventory/ai-context-manifest.json" },
    angle_results = {
      { angle = "teleology", verdict = "approve" },
      { angle = "parsimony", verdict = "approve" },
      { angle = "fidelity", verdict = "approve" },
      { angle = "natural-ownership", verdict = "approve" },
      { angle = "proportional-containment", verdict = "approve" },
    },
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function agent_generation_artifact(overrides)
  local value = {
    schema = ai.agent_generation_schema,
    artifact_kind = "ai-agent-generation",
    artifact_root = ".testing/runs/module-a-inventory",
    context_manifest_path = ".testing/runs/module-a-inventory/ai-context-manifest.json",
    generated_cases_path = ".testing/runs/module-a-inventory/generated-test-cases.json",
    status = "approved",
    mode = "autonomous-reviewed",
    proposal_id = "testing-ai-generation",
    consensus_proposal_ref = "testing-ai/generation/ctx",
    generation_digest = "agent-gen-dashboard",
    generated_case_count = 1,
    seat_count = 5,
    seat_names = { "teleology", "parsimony", "fidelity", "natural-ownership", "proportional-containment" },
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function agent_review_artifact(overrides)
  local value = {
    schema = ai.agent_review_schema,
    artifact_kind = "generated-case-agent-review",
    artifact_root = ".testing/runs/module-a-inventory",
    context_manifest_path = ".testing/runs/module-a-inventory/ai-context-manifest.json",
    generated_cases_path = ".testing/runs/module-a-inventory/generated-test-cases.json",
    generated_case_gate_path = ".testing/runs/module-a-inventory/generated-case-gate.json",
    generated_case_agent_review_path = ".testing/runs/module-a-inventory/generated-case-agent-review.json",
    status = "approved",
    mode = "autonomous-reviewed",
    proposal_id = "testing-ai-review",
    consensus_proposal_ref = "testing-ai/review/ctx",
    decision_digest = "agent-review-dashboard",
    approved_case_ids = { "dashboard:ai-visible-surface" },
    approved_case_count = 1,
    rejected_case_count = 0,
    blocked_case_count = 0,
    seat_count = 5,
    seat_names = { "teleology", "parsimony", "fidelity", "natural-ownership", "proportional-containment" },
    review_decisions = {
      { case_id = "dashboard:ai-visible-surface", status = "approved", classification = "agent-approved", reason = "agent review approved deterministic executable case" },
    },
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

return {
  test_build_context_manifest_uses_sanitized_pointer_only_fields = function()
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request(),
      step_budget = 6,
      case_priorities = { "P0", "P1" },
    })
    t.eq(context.schema, "testing-runner.ai-context-manifest.v1")
    t.eq(context.context_manifest_path, ".testing/runs/module-a-inventory/ai-context-manifest.json")
    t.eq(context.generated_cases_path, ".testing/runs/module-a-inventory/generated-test-cases.json")
    t.eq(context.generated_case_gate_path, ".testing/runs/module-a-inventory/generated-case-gate.json")
    t.eq(context.base_url, fixture_base_url)
    t.eq(context.allowed_origins[1], fixture_origin)
    t.eq(context.modules[1].entry_url, fixture_base_url .. "/dashboard")
    t.eq(context.budgets.step_budget, 6)
    t.eq(context.prompt_template_ref, "testing-runner.ai-case-generation.prompt.v1")
    t.eq(context.untrusted_context_notice:find("untrusted sanitized context", 1, true) ~= nil, true)
  end,

  test_generated_cases_gate_accepts_bounded_read_only_actions = function()
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", { ai_generation = ai_request() })
    local gate = ai.gate_generated_cases(generated_payload(), context, ai_request())
    t.eq(gate.schema, "testing-runner.generated-case-gate.v1")
    t.eq(gate.generated_case_gate_path, ".testing/runs/module-a-inventory/generated-case-gate.json")
    t.eq(gate.status, "reviewed")
    t.eq(gate.accepted_count, 1)
    t.eq(gate.executable_count, 1)
    t.eq(gate.cases[1].case_origin, "ai-generated")
    t.eq(gate.cases[1].review_status, "executable")
    t.eq(gate.cases[1].actions[1].action, "open-visible-surface")
  end,

  test_generated_cases_reject_unknown_action_and_external_origin = function()
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", { ai_generation = ai_request() })
    local gate = ai.gate_generated_cases(generated_payload({
      actions = { { action = "click-anything", target = "Dashboard" } },
    }), context, ai_request())
    t.eq(gate.status, "blocked")
    t.eq(gate.rejected_count, 1)
    t.eq(gate.decisions[1].classification, "schema-or-safety-rejected")

    gate = ai.gate_generated_cases(generated_payload({
      id = "dashboard:ai-external",
      actions = { { action = "open-visible-surface", target = "https://example.com/outside" } },
    }), context, ai_request())
    t.eq(gate.rejected_count, 1)
  end,

  test_generated_cases_reject_forbidden_payload_terms = function()
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", { ai_generation = ai_request() })
    local gate = ai.gate_generated_cases(generated_payload({
      id = "dashboard:ai-token",
      title = "Inspect token state",
    }), context, ai_request())
    t.eq(gate.rejected_count, 1)
  end,

  test_read_only_mutation_generated_case_is_not_executed_risk = function()
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", { ai_generation = ai_request() })
    local gate = ai.gate_generated_cases(generated_payload({
      id = "dashboard:ai-write",
      case_kind = "mutation-or-edge",
      actions = { { action = "safe-mutation-fixture", target = "Dashboard" } },
    }), context, ai_request({ allowed_case_kinds = { "mutation-or-edge" }, allowed_action_kinds = { "safe-mutation-fixture" } }))
    t.eq(gate.accepted_count, 1)
    t.eq(gate.not_executed_risk_count, 1)
    t.eq(gate.cases[1].ai_gate.classification, "read-only-policy")
  end,

  test_planning_merges_ai_cases_without_replacing_deterministic_baseline = function()
    local artifacts = planning.build(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request(),
      generated_cases = generated_payload(),
    })
    local module = artifacts.test_plan.modules[1]
    local deterministic = 0
    local generated = 0
    for _, case in ipairs(module.cases) do
      if case.case_origin == "deterministic" then deterministic = deterministic + 1 end
      if case.case_origin == "ai-generated" then generated = generated + 1 end
    end
    t.eq(deterministic, 10)
    t.eq(generated, 1)
    t.eq(artifacts.test_plan.review_gate.ai_generation.executable_generated_case_count, 1)
    t.eq(artifacts.ai_context.schema, "testing-runner.ai-context-manifest.v1")
    t.eq(artifacts.generated_case_gate.accepted_count, 1)
  end,

  test_agent_proposals_are_pointer_only_and_count_agnostic = function()
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request({ mode = "autonomous-reviewed", consensus_angles = { "teleology", "parsimony" } }),
    })
    local generation = ai.build_generation_proposal(context, ai_request({ mode = "autonomous-reviewed", consensus_angles = { "teleology", "parsimony" } }))
    t.eq(generation.schema, "consensus.proposal.v1")
    t.eq(generation.verdict_mode, "converge")
    t.eq(#generation.angles, 2)
    t.eq(generation.body:find("http://localhost:8080/app/dashboard", 1, true) ~= nil, true)
    t.eq(generation.body:find("secret", 1, true), nil)

    local gate = ai.gate_generated_cases(generated_payload(), context, ai_request({ mode = "autonomous-reviewed" }))
    local review = ai.build_review_proposal(context, generated_payload(), gate, ai_request({ mode = "autonomous-reviewed" }))
    t.eq(review.verdict_mode, "gate")
    t.eq(review.angles, nil)
    t.eq(review.body:find("generated-case-gate.json", 1, true) ~= nil, true)
  end,

  test_agent_generation_and_review_artifacts_parse_variable_seats = function()
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request({ mode = "autonomous-reviewed" }),
    })
    local gate = ai.gate_generated_cases(generated_payload(), context, ai_request({ mode = "autonomous-reviewed" }))
    local generation = ai.generation_from_agent_results(context, consensus_reached({ angle_results = {
      { angle = "one", verdict = "approve" },
      { angle = "two", verdict = "approve" },
      { angle = "three", verdict = "approve" },
      { angle = "four", verdict = "approve" },
      { angle = "five", verdict = "approve" },
    } }))
    local review = ai.review_from_agent_results(context, gate, consensus_reached({ proposal_id = "testing-ai-review", angle_results = {
      { angle = "one", verdict = "approve" },
      { angle = "two", verdict = "approve" },
      { angle = "three", verdict = "approve" },
      { angle = "four", verdict = "approve" },
      { angle = "five", verdict = "approve" },
    } }))
    t.eq(generation.status, "approved")
    t.eq(generation.seat_count, 5)
    t.eq(review.status, "approved")
    t.eq(review.approved_case_count, 1)
    t.eq(ai.agent_review_allows_merge(review, gate.cases[1]), true)
  end,

  test_autonomous_review_requires_agent_approval_before_merge = function()
    local artifacts = planning.build(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request({ mode = "autonomous-reviewed" }),
      generated_cases = generated_payload(),
      ai_agent_generation = agent_generation_artifact(),
      generated_case_agent_review = agent_review_artifact({ status = "rejected", approved_case_ids = {}, approved_case_count = 0, rejected_case_count = 1, blocked_case_count = 1 }),
    })
    local generated = 0
    for _, case in ipairs(artifacts.test_plan.modules[1].cases) do
      if case.case_origin == "ai-generated" then generated = generated + 1 end
    end
    t.eq(generated, 0)
    t.eq(artifacts.test_plan.ai_generation.status, "blocked")
    t.eq(artifacts.test_plan.ai_generation.agent_review_status, "rejected")
  end,

  test_autonomous_review_merges_agent_approved_cases = function()
    local artifacts = planning.build(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request({ mode = "autonomous-reviewed" }),
      generated_cases = generated_payload(),
      ai_agent_generation = agent_generation_artifact(),
      generated_case_agent_review = agent_review_artifact(),
    })
    local generated = 0
    for _, case in ipairs(artifacts.test_plan.modules[1].cases) do
      if case.case_origin == "ai-generated" then generated = generated + 1 end
    end
    t.eq(generated, 1)
    t.eq(artifacts.test_plan.ai_generation.agent_review_status, "approved")
    t.eq(artifacts.test_plan.ai_generation.agent_approved_generated_case_count, 1)
  end,
}
