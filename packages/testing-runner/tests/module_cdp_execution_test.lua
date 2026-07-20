local ai = require("module_ai_generation")
local design_loop = require("module_ai_design_loop")
local cdp = require("module_cdp_execution")
local inventory_module = require("module_inventory")
local native = require("fkst_native")
local t = fkst.test

local fixture_origin = "http://localhost:8080"
local fixture_base_url = fixture_origin .. "/app"

local function payload(overrides)
  local value = {
    schema = "testing-runner.module-test-loop.request.v1",
    module = "module-a",
    ui_loop = {
      base_url = fixture_base_url,
      allowed_origins = { fixture_origin },
      cdp_readiness_ref = "cdp-ready",
      mutation_policy = "read-only",
    },
    module_discovery = {
      schema = "testing-runner.module-discovery.v1",
      observations = {
        {
          id = "dashboard",
          name = "Dashboard",
          entry_url = fixture_base_url .. "/dashboard?secret=value#state",
          visible_label = "Dashboard",
          discovery_source = "navigation",
          confidence = "high",
          evidence_pointer = ".testing/runs/evidence/dashboard",
        },
      },
    },
    cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 8,
      case_priorities = { "P0", "P1" },
    },
    preflight_result = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "admin", status = "ready" },
      },
    },
  }
  for key, item in pairs(overrides or {}) do value[key] = item end
  return value
end

local function reviewed_artifacts(value, review_status, generated_overrides)
  local root = ".testing/runs/module-a-cdp"
  local request = {
    schema = ai.request_schema,
    mode = "autonomous-reviewed",
    case_budget = 1,
    context_manifest_path = root .. "/ai-context-manifest.json",
    generated_cases_path = root .. "/generated-test-cases.json",
    generated_case_gate_path = root .. "/generated-case-gate.json",
    ai_agent_generation_path = root .. "/ai-agent-generation.json",
    generated_case_agent_review_path = root .. "/generated-case-agent-review.json",
    ai_test_design_loop_path = root .. "/ai-test-design-loop.json",
  }
  value.cdp_execution.ai_generation = request
  value.module_discovery.observations[1].route = "/app/dashboard"
  local inventory = inventory_module.inventory(value.module_discovery, value.ui_loop, root, {
    readiness = { status = "ready" },
  })
  local context = ai.build_context(inventory, value.ui_loop, root, { ai_generation = request })
  local generated_case = {
    id = "dashboard:ai-visible-surface",
    module_id = "dashboard",
    priority = "P1",
    title = "Exercise visible dashboard surface",
    objective = "Exercise visible dashboard surface",
    case_kind = "read-only-interaction",
    actions = {
      {
        action = "open-visible-surface",
        target = "Dashboard",
        expected = "visible surface opens without mutation",
      },
    },
    expected_observable = "Dashboard remains visible and same-origin.",
    provenance = {
      origin = "ai-generated",
      context_manifest_path = context.context_manifest_path,
      prompt_template_ref = context.prompt_template_ref,
      model_invocation_digest = "model-dashboard-reviewed",
    },
  }
  for key, item in pairs(generated_overrides or {}) do generated_case[key] = item end
  local generated = {
    schema = ai.generated_cases_schema,
    artifact_kind = "generated-test-cases",
    artifact_root = root,
    context_manifest_path = context.context_manifest_path,
    prompt_template_ref = context.prompt_template_ref,
    generation_mode = "autonomous-reviewed",
    generation_digest = "gen-dashboard-reviewed",
    generated_cases_path = context.generated_cases_path,
    cases = { generated_case },
    case_count = 1,
  }
  local gate = ai.gate_generated_cases(generated, context, request)
  local approved = review_status ~= "rejected"
  local generation = {
    schema = ai.agent_generation_schema,
    artifact_kind = "ai-agent-generation",
    artifact_root = root,
    context_manifest_path = context.context_manifest_path,
    generated_cases_path = context.generated_cases_path,
    status = "approved",
    mode = "autonomous-reviewed",
    proposal_id = "testing-ai-generation",
    consensus_proposal_ref = "testing-ai/generation/context",
    generation_digest = "agent-generation-dashboard",
    candidate_generation_digest = generated.generation_digest,
    generated_case_count = 1,
    seat_count = 5,
    seat_names = { "teleology", "parsimony", "fidelity", "natural-ownership", "proportional-containment" },
  }
  local review = {
    schema = ai.agent_review_schema,
    artifact_kind = "generated-case-agent-review",
    artifact_root = root,
    context_manifest_path = context.context_manifest_path,
    generated_cases_path = context.generated_cases_path,
    generated_case_gate_path = context.generated_case_gate_path,
    generated_case_agent_review_path = context.generated_case_agent_review_path,
    status = approved and "approved" or "rejected",
    mode = "autonomous-reviewed",
    proposal_id = "testing-ai-review",
    consensus_proposal_ref = "testing-ai/review/context",
    decision_digest = "agent-review-dashboard",
    candidate_generation_digest = generated.generation_digest,
    gate_digest = gate.gate_digest,
    approved_case_ids = approved and { "dashboard:ai-visible-surface" } or {},
    approved_case_count = approved and 1 or 0,
    rejected_case_count = approved and 0 or 1,
    blocked_case_count = approved and 0 or 1,
    seat_count = 5,
    seat_names = { "teleology", "parsimony", "fidelity", "natural-ownership", "proportional-containment" },
    review_decisions = {
      {
        case_id = "dashboard:ai-visible-surface",
        status = approved and "approved" or "rejected",
        classification = approved and "agent-approved" or "agent-rejected",
        reason = approved and "approved for bounded execution" or "rejected by agent review",
      },
    },
  }
  local closure = ai.build_review_closure(context, generated, gate, generation, review)
  local documents = {
    [context.context_manifest_path] = context,
    [context.generated_cases_path] = generated,
    [context.generated_case_gate_path] = gate,
    [context.ai_agent_generation_path] = generation,
    [context.generated_case_agent_review_path] = review,
    [context.ai_test_design_loop_path] = closure,
  }
  return function(path)
    return native.json_encode(documents[path])
  end
end

local function reviewed_design_state(value)
  local root = ".testing/runs/module-a-cdp/design"
  local function design_case(id, subject_id, origin)
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
      coverage_subject_ids = { subject_id },
      provenance = { origin = origin, source_pointer = root .. "/source.json" },
    }
  end
  local documents = {
    seed_cases = { schema = design_loop.schemas.seed_cases, cases = { design_case("dashboard:reviewed-design", "module-dashboard", "user-seed") } },
    deterministic_cases = { schema = design_loop.schemas.deterministic_cases, cases = { design_case("dashboard:reviewed-requirement", "REQ-HEALTH", "deterministic") } },
    coverage_scope = {
      schema = design_loop.schemas.coverage_scope,
      subjects = {
        { id = "REQ-HEALTH", kind = "requirement", priority = "P0", evidence_pointer = root .. "/requirements.json" },
        { id = "module-dashboard", kind = "module", priority = "P1", evidence_pointer = root .. "/inventory.json" },
      },
    },
  }
  local function ref(name)
    return { artifact_pointer = root .. "/" .. name .. ".json", artifact_digest = design_loop.document_digest(documents[name]) }
  end
  local state = design_loop.start({
    schema = design_loop.schemas.request,
    artifact_root = root,
    seed_cases_ref = ref("seed_cases"),
    deterministic_cases_ref = ref("deterministic_cases"),
    coverage_scope_ref = ref("coverage_scope"),
    max_rounds = 3,
    case_budget = 8,
    action_budget = 24,
    trace_id = "trace-cdp-design",
    dedup_key = "dedup-cdp-design",
  }, documents)
  value.cdp_execution.ai_design_loop_state_ref = {
    artifact_pointer = state.paths.state,
    artifact_digest = design_loop.document_digest(state),
  }
  return function(path)
    if path == state.paths.state then return native.json_encode(state) end
    error("unexpected artifact path " .. tostring(path))
  end
end

return {
  test_builds_bounded_cdp_execution_artifact_for_safe_p0_p1_cases = function()
    local artifact = cdp.build(payload(), ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.schema, "testing-runner.module-cdp-execution-result.v1")
    t.eq(artifact.artifact_kind, "module-cdp-execution")
    t.eq(artifact.execution_status, "planned")
    t.eq(artifact.classification, "bounded-exploration-planned")
    t.eq(artifact.mode, "bounded-cdp-controller")
    t.eq(artifact.execution_path, ".testing/runs/module-a-cdp/cdp-execution.json")
    t.eq(artifact.test_plan_path, ".testing/runs/module-a-cdp/test-plan.json")
    t.eq(artifact.planned_case_count, 5)
    t.eq(artifact.action_count, 5)
    t.eq(artifact.actions[1].intent, "Reach Dashboard entry URL")
    t.eq(artifact.actions[1].action, "navigate")
    t.eq(artifact.actions[1].url, fixture_base_url .. "/dashboard")
    t.eq(artifact.actions[1].evidence_pointer, nil)
    t.eq(artifact.actions[1].planned_evidence_pointer, ".testing/runs/module-a-cdp/evidence/cdp/dashboard-reachability.json")
    t.eq(artifact.actions[1].execution_status, "planned")
    t.eq(artifact.actions[1].assertion_status, "not-run")
    t.eq(artifact.actions[1].url:find("secret", 1, true), nil)
  end,

  test_blocks_when_reused_cdp_session_is_missing = function()
    local artifact = cdp.build(payload({
      preflight_result = {
        schema = "browser-readiness.result.v1",
        status = "ready",
        sessions = {
          { role = "base_url", status = "ready" },
        },
      },
    }), ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.execution_status, "blocked")
    t.eq(artifact.classification, "missing-cdp-session")
    t.eq(artifact.action_count, 0)
  end,

  test_degrades_when_step_budget_stops_before_all_safe_cases = function()
    local value = payload()
    value.cdp_execution.step_budget = 2
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.execution_status, "degraded")
    t.eq(artifact.classification, "step-budget-exhausted")
    t.eq(artifact.planned_case_count, 5)
    t.eq(artifact.action_count, 2)
  end,

  test_executes_p2_only_with_safe_mutation_fixture_evidence = function()
    local value = payload()
    value.ui_loop.mutation_policy = "host-approved"
    value.cdp_execution.case_priorities = { "P2" }
    value.cdp_execution.mutation_fixtures = {
      {
        case_id = "dashboard:write-flow",
        mutation_kind = "create-test-data",
        fixture_lifecycle_path = ".testing/runs/fixtures/dashboard-lifecycle",
      },
    }
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.execution_status, "planned")
    t.eq(artifact.classification, "bounded-exploration-planned")
    t.eq(artifact.planned_case_count, 1)
    t.eq(artifact.action_count, 1)
    t.eq(artifact.actions[1].case_id, "dashboard:write-flow")
    t.eq(artifact.actions[1].priority, "P2")
    t.eq(artifact.actions[1].action, "safe-mutation-fixture")
    t.eq(artifact.actions[1].mutation_kind, "create-test-data")
    t.eq(artifact.actions[1].fixture_lifecycle_path, ".testing/runs/fixtures/dashboard-lifecycle")
    t.eq(artifact.actions[1].execution_status, "planned")
    t.eq(artifact.planned_action_count, 1)
    t.eq(artifact.blocked_action_count, 0)
    t.eq(artifact.executed_action_count, 0)
  end,

  test_destructive_p2_fixture_degrades_without_execution = function()
    local value = payload()
    value.ui_loop.mutation_policy = "host-approved"
    value.cdp_execution.case_priorities = { "P2" }
    value.cdp_execution.mutation_fixtures = {
      {
        case_id = "dashboard:write-flow",
        mutation_kind = "delete",
        fixture_lifecycle_path = ".testing/runs/fixtures/dashboard-delete-lifecycle",
      },
    }
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.execution_status, "degraded")
    t.eq(artifact.classification, "no-executable-safe-cases")
    t.eq(artifact.planned_case_count, 0)
    t.eq(artifact.action_count, 0)
  end,

  test_rejects_embedded_browser_state_in_execution_request = function()
    t.raises(function()
      cdp.validate_request({
        schema = "testing-runner.module-cdp-execution.v1",
        step_budget = 4,
        screenshot = "inline-browser-state",
      })
    end)
  end,

  test_records_fixture_gap_when_lifecycle_descriptor_is_missing = function()
    local value = payload()
    value.ui_loop.mutation_policy = "host-approved"
    value.cdp_execution.case_priorities = { "P2" }
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.execution_status, "degraded")
    t.eq(artifact.classification, "no-executable-safe-cases")
    t.eq(artifact.action_count, 0)
  end,

  test_executes_ai_generated_read_only_actions_through_bounded_schema = function()
    local value = payload()
    local reader = reviewed_artifacts(value, "approved")
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", {
      readiness = { status = "ready" },
      artifact_reader = reader,
    })
    t.eq(artifact.execution_status, "planned")
    t.eq(artifact.classification, "bounded-exploration-planned")
    t.eq(artifact.ai_generation.executable_generated_case_count, 1)
    t.eq(artifact.ai_context_manifest_path, ".testing/runs/module-a-cdp/ai-context-manifest.json")
    t.eq(artifact.generated_cases_path, ".testing/runs/module-a-cdp/generated-test-cases.json")
    t.eq(artifact.generated_case_gate_path, ".testing/runs/module-a-cdp/generated-case-gate.json")
    t.eq(artifact.actions[6].case_origin, "ai-generated")
    t.eq(artifact.actions[6].action, "open-visible-surface")
    t.eq(artifact.actions[6].provenance_digest, "model-dashboard-reviewed")
  end,

  test_expands_multi_step_ai_generated_case_into_ordered_cdp_actions = function()
    local value = payload()
    local reader = reviewed_artifacts(value, "approved", {
      actions = {
        {
          action = "bounded-navigation",
          target = fixture_base_url .. "/dashboard/details?view=summary#state",
          expected = "Details route becomes visible.",
        },
        {
          action = "open-visible-surface",
          target = "Dashboard details",
          expected = "The detail surface opens without leaving local scope.",
        },
      },
      expected_observable = "The details surface remains visible and same-origin.",
    })
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", {
      readiness = { status = "ready" },
      artifact_reader = reader,
    })
    t.eq(artifact.execution_status, "planned")
    t.eq(artifact.planned_case_count, 6)
    t.eq(artifact.action_count, 7)
    t.eq(artifact.actions[6].case_id, "dashboard:ai-visible-surface")
    t.eq(artifact.actions[6].case_origin, "ai-generated")
    t.eq(artifact.actions[6].action, "bounded-navigation")
    t.eq(artifact.actions[6].target, fixture_base_url .. "/dashboard/details")
    t.eq(artifact.actions[6].url, fixture_base_url .. "/dashboard/details")
    t.eq(artifact.actions[6].expected_observable, "Details route becomes visible.")
    t.eq(artifact.actions[7].case_id, "dashboard:ai-visible-surface")
    t.eq(artifact.actions[7].case_origin, "ai-generated")
    t.eq(artifact.actions[7].action, "open-visible-surface")
    t.eq(artifact.actions[7].target, "Dashboard details")
    t.eq(artifact.actions[7].expected_observable, "The detail surface opens without leaving local scope.")
  end,

  test_rejects_legacy_inline_ai_artifacts_before_execution = function()
    t.raises(function()
      cdp.validate_request({
        schema = "testing-runner.module-cdp-execution.v1",
        generated_cases = { schema = "testing-runner.generated-test-cases.v1" },
      })
    end)
  end,

  test_autonomous_reviewed_generated_case_executes_only_after_agent_approval = function()
    local value = payload()
    local reader = reviewed_artifacts(value, "approved")
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", {
      readiness = { status = "ready" },
      artifact_reader = reader,
    })
    t.eq(artifact.ai_generation.agent_review_status, "approved")
    t.eq(artifact.ai_agent_generation_path, ".testing/runs/module-a-cdp/ai-agent-generation.json")
    t.eq(artifact.generated_case_agent_review_path, ".testing/runs/module-a-cdp/generated-case-agent-review.json")
    t.eq(artifact.actions[6].case_origin, "ai-generated")
  end,

  test_autonomous_reviewed_rejection_blocks_generated_execution = function()
    local value = payload()
    local reader = reviewed_artifacts(value, "rejected")
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", {
      readiness = { status = "ready" },
      artifact_reader = reader,
    })
    t.eq(artifact.execution_status, "blocked")
    t.eq(artifact.classification, "ai-artifact-invalid")
    t.eq(artifact.executed_action_count, 0)
  end,

  test_final_design_loop_state_merges_reviewed_cases_before_bounded_execution = function()
    local value = payload()
    local reader = reviewed_design_state(value)
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", {
      readiness = { status = "ready" },
      artifact_reader = reader,
    })
    t.eq(artifact.execution_status, "planned")
    local seen = {}
    for _, action in ipairs(artifact.actions) do seen[action.case_id] = true end
    t.eq(seen["dashboard:reviewed-design"], true)
    t.eq(seen["dashboard:reviewed-requirement"], true)
  end,

  test_design_loop_state_digest_mismatch_blocks_before_execution = function()
    local value = payload()
    local reader = reviewed_design_state(value)
    value.cdp_execution.ai_design_loop_state_ref.artifact_digest = "wrong-digest"
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", {
      readiness = { status = "ready" },
      artifact_reader = reader,
    })
    t.eq(artifact.execution_status, "blocked")
    t.eq(artifact.classification, "ai-design-loop-artifact-invalid")
    t.eq(artifact.action_count, 0)
  end,
}
