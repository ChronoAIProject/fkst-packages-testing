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
    generated_cases_path = ".testing/runs/module-a-inventory/generated-test-cases.json",
    prompt_template_ref = "testing-runner.ai-case-generation.prompt.v1",
    generation_mode = "autonomous-reviewed",
    generation_digest = "gen-dashboard",
    cases = { generated_case(case_overrides) },
    case_count = 1,
  }
end

local function ai_request(overrides)
  local value = {
    schema = ai.request_schema,
    mode = "autonomous-reviewed",
    case_budget = 4,
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function generated_gate(request, generated)
  local effective_request = request or ai_request()
  local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
    ai_generation = effective_request,
  })
  return ai.gate_generated_cases(generated or generated_payload(), context, effective_request)
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
    candidate_generation_digest = "gen-dashboard",
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
    candidate_generation_digest = "gen-dashboard",
    gate_digest = generated_gate(ai_request(), generated_payload()).gate_digest,
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

local function trace_references(include_ui_state)
  local references = {
    { kind = "requirement", ref = "REQ-DASHBOARD-VISIBLE" },
    { kind = "code-symbol", ref = "Dashboard.openVisibleSurface" },
    { kind = "route-or-api", ref = "GET /app/dashboard" },
    { kind = "ui-element", ref = "dashboard-details-button" },
    { kind = "evidence", ref = ".testing/runs/evidence/dashboard" },
    { kind = "priority", ref = "P1" },
    { kind = "risk-category", ref = "positive" },
    { kind = "assertion-trace", ref = "dashboard-visible-assertion" },
  }
  if include_ui_state then table.insert(references, { kind = "ui-state", ref = "dashboard-details-open" }) end
  return references
end

local function coverage_case(case_id, source_id, position, include_ui_state, distinct)
  local target = "Dashboard details"
  local expected = "Dashboard details are visible."
  local actions = {
    { action = "bounded-navigation", target = "Dashboard", expected = "Dashboard is visible." },
    { action = "open-visible-surface", target = target, expected = expected },
  }
  if distinct then actions = { actions[2], actions[1] } end
  return {
    case_id = case_id,
    intent = "Exercise visible surface for Dashboard",
    target = target,
    preconditions = { "Dashboard is loaded", "A local session is ready" },
    actions = actions,
    assertions = {
      { expected = expected, trace_references = trace_references(true) },
    },
    trace_references = trace_references(include_ui_state),
    source = {
      source_id = source_id,
      candidate_position = position,
      round = position + 1,
      presentation_order = position + 2,
    },
  }
end

local function coverage_input(include_ui_state, reverse_order, distinct, quota)
  local deterministic = coverage_case("dashboard:navigation", "baseline-source-transient", 1, include_ui_state, false)
  local generated = coverage_case("dashboard:ai-visible-surface", "generated-source-transient", 9, include_ui_state, distinct)
  return {
    policy = {
      policy_id = "minimal-traced-positive-case",
      required_case_trace_kinds = {
        "requirement", "code-symbol", "route-or-api", "ui-element", "ui-state",
        "evidence", "priority", "risk-category", "assertion-trace",
      },
      required_assertion_trace_kinds = {
        "requirement", "code-symbol", "route-or-api", "ui-element", "ui-state",
        "evidence", "assertion-trace",
      },
      positive_risk_case_quota = quota or 1,
      positive_risk_reference = { kind = "risk-category", ref = "positive" },
    },
    cases = reverse_order and { generated, deterministic } or { deterministic, generated },
  }
end

local function planned_with_coverage(coverage)
  return planning.build(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
    ai_generation = ai_request(),
    generated_cases = generated_payload(),
    generated_case_gate = generated_gate(ai_request(), generated_payload()),
    ai_agent_generation = agent_generation_artifact(),
    generated_case_agent_review = agent_review_artifact(),
    coverage = coverage,
  })
end

local function has_trace_reference(references, expected)
  for _, reference in ipairs(references) do
    if reference.kind == expected.kind and reference.ref == expected.ref then return true end
  end
  return false
end

local function has_source(sources, origin, source_id)
  for _, source in ipairs(sources) do
    if source.origin == origin and source.source_id == source_id then return true end
  end
  return false
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

  test_build_context_respects_custom_ai_artifact_paths = function()
    local request = ai_request({
      context_manifest_path = ".testing/runs/module-a-inventory/custom/context.json",
      generated_cases_path = ".testing/runs/module-a-inventory/custom/generated.json",
      generated_case_gate_path = ".testing/runs/module-a-inventory/custom/gate.json",
      ai_agent_generation_path = ".testing/runs/module-a-inventory/custom/generation-review.json",
      generated_case_agent_review_path = ".testing/runs/module-a-inventory/custom/execution-review.json",
      ai_test_design_loop_path = ".testing/runs/module-a-inventory/custom/closure.json",
    })
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = request,
    })
    t.eq(context.context_manifest_path, request.context_manifest_path)
    t.eq(context.generated_cases_path, request.generated_cases_path)
    t.eq(context.generated_case_gate_path, request.generated_case_gate_path)
    t.eq(context.ai_agent_generation_path, request.ai_agent_generation_path)
    t.eq(context.generated_case_agent_review_path, request.generated_case_agent_review_path)
    t.eq(context.ai_test_design_loop_path, request.ai_test_design_loop_path)
  end,

  test_context_digest_changes_when_sanitized_module_identity_changes = function()
    local first = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request(),
    })
    local changed_inventory = inventory({
      modules = {
        {
          id = "reports",
          name = "Reports",
          entry_url = fixture_base_url .. "/reports",
          route = "/app/reports",
          visible_label = "Reports",
          discovery_source = "navigation",
          confidence = "high",
          evidence_pointer = ".testing/runs/evidence/reports",
          feature_signals = { "entry-route", "visible-label-or-route", "local-session-evidence" },
        },
      },
      module_count = 1,
    })
    local second = ai.build_context(changed_inventory, ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request(),
    })
    t.eq(first.input_digest == second.input_digest, false)
  end,

  test_canonicalizes_agent_candidates_and_assigns_authority_fields = function()
    local request = ai_request({ case_budget = 1 })
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", { ai_generation = request })
    local generated = ai.canonicalize_candidates(context, request, {
      schema = ai.candidate_schema,
      cases = {
        {
          module_id = "dashboard",
          priority = "P1",
          title = "Navigate dashboard details",
          objective = "Verify dashboard details are reachable.",
          case_kind = "primary-interaction",
          actions = {
            { action = "bounded-navigation", target = fixture_base_url .. "/dashboard/details", expected = "Details become visible." },
          },
          expected_observable = "Dashboard details remain visible.",
        },
      },
    }, "model-dashboard")
    t.eq(generated.case_count, 1)
    t.eq(generated.cases[1].id:find("dashboard:ai-", 1, true), 1)
    t.eq(generated.cases[1].provenance.model_invocation_digest, "model-dashboard")
    t.eq(generated.cases[1].evidence_pointers[1], ".testing/runs/evidence/dashboard")
    t.eq(generated.cases[1].actions[1].evidence_pointer, ".testing/runs/evidence/dashboard")
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

  test_generated_case_gate_digest_changes_when_case_content_changes = function()
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", { ai_generation = ai_request() })
    local first = ai.gate_generated_cases(generated_payload({
      actions = { { action = "open-visible-surface", target = "Dashboard" } },
    }), context, ai_request())
    local second = ai.gate_generated_cases(generated_payload({
      actions = { { action = "open-visible-surface", target = "Dashboard details" } },
    }), context, ai_request())
    t.eq(first.gate_digest == second.gate_digest, false)
  end,

  test_generated_cases_gate_rejects_stale_context_binding = function()
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", { ai_generation = ai_request() })
    local generated = generated_payload()
    generated.context_manifest_path = ".testing/runs/other/ai-context-manifest.json"
    t.raises(function()
      ai.gate_generated_cases(generated, context, ai_request())
    end)
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
      generated_case_gate = generated_gate(ai_request(), generated_payload()),
      ai_agent_generation = agent_generation_artifact(),
      generated_case_agent_review = agent_review_artifact(),
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

  test_planning_builds_traced_deduplicated_coverage_matrix_and_policy_decision = function()
    local artifacts = planned_with_coverage(coverage_input(true, false, false))
    local matrix = artifacts.coverage_matrix
    t.eq(matrix.version, "coverage-matrix/v1")
    t.eq(matrix.coverage_matrix_path, ".testing/runs/module-a-inventory/coverage-matrix.json")
    t.eq(matrix.input_case_count, 2)
    t.eq(matrix.unique_case_count, 1)
    t.eq(matrix.decision.complete, true)
    t.eq(matrix.decision.scope, "configured-policy")
    t.eq(matrix.decision.mandatory_gap_count, 0)
    t.eq(artifacts.test_plan.coverage_matrix_path, matrix.coverage_matrix_path)
    t.eq(artifacts.test_plan.coverage_decision.complete, true)

    local case = matrix.cases[1]
    t.eq(case.provenance.source_count, 2)
    t.is_true(has_source(case.provenance.sources, "deterministic", "baseline-source-transient"))
    t.is_true(has_source(case.provenance.sources, "ai-generated", "generated-source-transient"))
    t.eq(case.assertions[1].expected, "dashboard details are visible.")
    t.eq(#case.trace_references, 9)
    t.eq(#case.assertions[1].trace_references, 9)
    for _, reference in ipairs(trace_references(true)) do
      t.is_true(has_trace_reference(case.trace_references, reference))
      t.is_true(has_trace_reference(case.assertions[1].trace_references, reference))
    end
    t.eq(case.semantic_fingerprint:find("baseline-source-transient", 1, true), nil)
    t.eq(case.semantic_fingerprint:find("generated-source-transient", 1, true), nil)

    local reordered = coverage_input(true, true, false)
    reordered.cases[1].source.source_id = "other-generated-source"
    reordered.cases[1].source.candidate_position = 3
    reordered.cases[2].source.source_id = "other-baseline-source"
    reordered.cases[2].source.candidate_position = 7
    for _, coverage_case_value in ipairs(reordered.cases) do
      coverage_case_value.preconditions = { coverage_case_value.preconditions[2], coverage_case_value.preconditions[1] }
      local reversed = {}
      for index = #coverage_case_value.trace_references, 1, -1 do
        table.insert(reversed, coverage_case_value.trace_references[index])
      end
      coverage_case_value.trace_references = reversed
    end
    local reordered_matrix = planned_with_coverage(reordered).coverage_matrix
    t.eq(reordered_matrix.cases[1].semantic_fingerprint, case.semantic_fingerprint)

    local distinct_matrix = planned_with_coverage(coverage_input(true, false, true)).coverage_matrix
    t.eq(distinct_matrix.unique_case_count, 2)
    t.eq(distinct_matrix.cases[1].semantic_fingerprint == distinct_matrix.cases[2].semantic_fingerprint, false)

    local incomplete = planned_with_coverage(coverage_input(false, false, false)).coverage_matrix
    t.eq(incomplete.decision.complete, false)
    t.eq(incomplete.decision.mandatory_gap_count, 1)
    t.eq(incomplete.decision.gaps[1].code, "missing-case-trace-reference")
    t.eq(incomplete.decision.gaps[1].reference_kind, "ui-state")

    local assertion_missing_input = coverage_input(true, false, false)
    for _, coverage_case_value in ipairs(assertion_missing_input.cases) do
      coverage_case_value.assertions[1].trace_references = trace_references(false)
    end
    local assertion_incomplete = planned_with_coverage(assertion_missing_input).coverage_matrix
    t.eq(assertion_incomplete.decision.complete, false)
    t.eq(assertion_incomplete.decision.mandatory_gap_count, 1)
    t.eq(assertion_incomplete.decision.gaps[1].code, "missing-assertion-trace-reference")
    t.eq(assertion_incomplete.decision.gaps[1].reference_kind, "ui-state")

    local quota_gap = planned_with_coverage(coverage_input(true, false, false, 2)).coverage_matrix
    t.eq(quota_gap.decision.complete, false)
    t.eq(quota_gap.decision.gaps[1].code, "positive-risk-case-quota-not-met")
  end,

  test_agent_proposals_are_pointer_only_and_count_agnostic = function()
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request(),
    })
    local generated = generated_payload()
    local generation = ai.build_generation_proposal(context, generated, ai_request(), "manifest: generated candidates")
    t.eq(generation.schema, "consensus.proposal.v1")
    t.eq(generation.verdict_mode, "converge")
    t.eq(generation.angles, nil)
    t.eq(generation.content_fetch, "manifest: generated candidates")
    t.eq(generation.body:find("secret", 1, true), nil)

    local gate = ai.gate_generated_cases(generated, context, ai_request())
    local review = ai.build_review_proposal(context, generated, gate, ai_request(), "manifest: gated candidates")
    t.eq(review.verdict_mode, "gate")
    t.eq(review.angles, nil)
    t.eq(review.content_fetch, "manifest: gated candidates")
    t.eq(review.body:find("generated-case-gate.json", 1, true) ~= nil, true)
  end,

  test_agent_generation_and_review_require_consensus_approval_evidence = function()
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request({ mode = "autonomous-reviewed" }),
    })
    local gate = ai.gate_generated_cases(generated_payload(), context, ai_request({ mode = "autonomous-reviewed" }))
    local generation = ai.generation_from_agent_results(context, consensus_reached({ angle_results = {
      { angle = "teleology", verdict = "approve", exit_code = 0 },
      { angle = "parsimony", verdict = "approve", exit_code = 0 },
      { angle = "fidelity", verdict = "approve", exit_code = 0 },
      { angle = "natural-ownership", verdict = "approve", exit_code = 0 },
      { angle = "proportional-containment", verdict = "approve", exit_code = 0 },
    } }))
    local review = ai.review_from_agent_results(context, gate, consensus_reached({ proposal_id = "testing-ai-review", angle_results = {
      { angle = "teleology", verdict = "approve", exit_code = 0 },
      { angle = "parsimony", verdict = "approve", exit_code = 0 },
      { angle = "fidelity", verdict = "approve", exit_code = 0 },
      { angle = "natural-ownership", verdict = "approve", exit_code = 0 },
      { angle = "proportional-containment", verdict = "approve", exit_code = 0 },
    } }))
    t.eq(generation.status, "approved")
    t.eq(generation.seat_count, 5)
    t.eq(review.status, "approved")
    t.eq(review.approved_case_count, 1)
    t.eq(ai.agent_review_allows_merge(review, gate.cases[1]), true)

    local weak_review = ai.review_from_agent_results(context, gate, consensus_reached({ proposal_id = "testing-ai-review", angle_results = {
      { angle = "teleology", verdict = "approve", exit_code = 0 },
    } }))
    t.eq(weak_review.status, "unavailable")
    t.eq(weak_review.approved_case_count, 0)

    local duplicate_generation = ai.generation_from_agent_results(context, consensus_reached({ angle_results = {
      { angle = "teleology", verdict = "approve", exit_code = 0 },
      { angle = "parsimony", verdict = "approve", exit_code = 0 },
      { angle = "fidelity", verdict = "approve", exit_code = 0 },
      { angle = "natural-ownership", verdict = "approve", exit_code = 0 },
      { angle = "proportional-containment", verdict = "approve", exit_code = 0 },
      { angle = "teleology", verdict = "approve", exit_code = 0 },
    } }))
    t.eq(duplicate_generation.status, "unavailable")
  end,

  test_autonomous_review_requires_agent_approval_before_merge = function()
    local artifacts = planning.build(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request({ mode = "autonomous-reviewed" }),
      generated_cases = generated_payload(),
      generated_case_gate = generated_gate(ai_request({ mode = "autonomous-reviewed" }), generated_payload()),
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

  test_autonomous_review_rejects_stale_agent_review_binding = function()
    t.raises(function()
      planning.build(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
        ai_generation = ai_request({ mode = "autonomous-reviewed" }),
        generated_cases = generated_payload(),
        generated_case_gate = generated_gate(ai_request({ mode = "autonomous-reviewed" }), generated_payload()),
        ai_agent_generation = agent_generation_artifact(),
        generated_case_agent_review = agent_review_artifact({ gate_digest = "gate-stale" }),
      })
    end)
  end,

  test_autonomous_review_merges_agent_approved_cases = function()
    local artifacts = planning.build(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request({ mode = "autonomous-reviewed" }),
      generated_cases = generated_payload(),
      generated_case_gate = generated_gate(ai_request({ mode = "autonomous-reviewed" }), generated_payload()),
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

  test_review_closure_records_final_ai_loop_state = function()
    local generated = generated_payload({
      id = "dashboard:ai-search-filter",
      actions = { { action = "search-or-filter-readonly", target = "Dashboard" } },
    })
    local gate = generated_gate(ai_request({ mode = "autonomous-reviewed", case_budget = 2 }), generated)
    local artifacts = planning.build(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = ai_request({ mode = "autonomous-reviewed", case_budget = 2 }),
      generated_cases = generated,
      generated_case_gate = gate,
      ai_agent_generation = agent_generation_artifact(),
      generated_case_agent_review = agent_review_artifact({ approved_case_ids = {}, approved_case_count = 0, blocked_case_count = 1, gate_digest = gate.gate_digest }),
    })
    local closure = artifacts.ai_review_closure
    t.eq(closure.schema, ai.review_closure_schema)
    t.eq(closure.ai_test_design_loop_path, ".testing/runs/module-a-inventory/ai-test-design-loop.json")
    t.eq(closure.status, "blocked")
    t.eq(closure.generated_case_count, 1)
    t.eq(closure.blocked_generated_case_count, 1)
    t.eq(closure.execution_eligible_generated_case_count, 0)
    t.eq(closure.reviewed_cases[1].classification, "agent-review-blocked")
    t.eq(closure.reviewed_cases[1].final_status, "blocked")
    t.is_true(closure.required_follow_up[1]:find("agent review", 1, true) ~= nil)
  end,

  test_zero_generated_cases_degrades_review_closure_when_budget_expected_cases = function()
    local request = ai_request({ mode = "autonomous-reviewed", case_budget = 2 })
    local context = ai.build_context(inventory(), ui_loop(), ".testing/runs/module-a-inventory", {
      ai_generation = request,
    })
    local generated = generated_payload()
    generated.cases = {}
    generated.case_count = 0
    local gate = ai.gate_generated_cases(generated, context, request)
    local generation = agent_generation_artifact({
      generated_case_count = 0,
      candidate_generation_digest = generated.generation_digest,
    })
    local review = agent_review_artifact({
      approved_case_ids = {},
      approved_case_count = 0,
      rejected_case_count = 0,
      blocked_case_count = 0,
      candidate_generation_digest = generated.generation_digest,
      gate_digest = gate.gate_digest,
      review_decisions = {},
    })
    local closure = ai.build_review_closure(context, generated, gate, generation, review)
    t.eq(gate.status, "degraded")
    t.eq(closure.status, "degraded")
    t.eq(closure.generated_case_count, 0)
    t.is_true(closure.required_follow_up[1]:find("no generated candidate", 1, true) ~= nil)
  end,
}
