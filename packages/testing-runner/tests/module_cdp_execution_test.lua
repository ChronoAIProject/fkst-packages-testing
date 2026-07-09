local cdp = require("module_cdp_execution")
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

return {
  test_builds_bounded_cdp_execution_artifact_for_safe_p0_p1_cases = function()
    local artifact = cdp.build(payload(), ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.schema, "testing-runner.module-cdp-execution-result.v1")
    t.eq(artifact.artifact_kind, "module-cdp-execution")
    t.eq(artifact.execution_status, "passed")
    t.eq(artifact.classification, "bounded-exploration-complete")
    t.eq(artifact.mode, "bounded-cdp-controller")
    t.eq(artifact.execution_path, ".testing/runs/module-a-cdp/cdp-execution.json")
    t.eq(artifact.test_plan_path, ".testing/runs/module-a-cdp/test-plan.json")
    t.eq(artifact.planned_case_count, 5)
    t.eq(artifact.action_count, 5)
    t.eq(artifact.actions[1].intent, "Reach Dashboard entry URL")
    t.eq(artifact.actions[1].action, "navigate")
    t.eq(artifact.actions[1].url, fixture_base_url .. "/dashboard")
    t.eq(artifact.actions[1].evidence_pointer, ".testing/runs/module-a-cdp/evidence/cdp/dashboard-reachability.json")
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
        fixture_ref = ".testing/runs/fixtures/dashboard-create",
        cleanup_ref = ".testing/runs/fixtures/dashboard-cleanup",
        evidence_pointer = ".testing/runs/evidence/dashboard-create",
      },
    }
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.execution_status, "passed")
    t.eq(artifact.planned_case_count, 1)
    t.eq(artifact.action_count, 1)
    t.eq(artifact.actions[1].case_id, "dashboard:write-flow")
    t.eq(artifact.actions[1].priority, "P2")
    t.eq(artifact.actions[1].action, "safe-mutation-fixture")
    t.eq(artifact.actions[1].mutation_kind, "create-test-data")
    t.eq(artifact.actions[1].cleanup_ref, ".testing/runs/fixtures/dashboard-cleanup")
    t.eq(artifact.actions[1].fixture_evidence_pointer, ".testing/runs/evidence/dashboard-create")
  end,

  test_destructive_p2_fixture_degrades_without_execution = function()
    local value = payload()
    value.ui_loop.mutation_policy = "host-approved"
    value.cdp_execution.case_priorities = { "P2" }
    value.cdp_execution.mutation_fixtures = {
      {
        case_id = "dashboard:write-flow",
        mutation_kind = "delete",
        fixture_ref = ".testing/runs/fixtures/dashboard-delete",
        cleanup_ref = ".testing/runs/fixtures/dashboard-cleanup",
        evidence_pointer = ".testing/runs/evidence/dashboard-delete",
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

  test_records_fixture_gap_when_cleanup_or_rollback_is_missing = function()
    local value = payload()
    value.ui_loop.mutation_policy = "host-approved"
    value.cdp_execution.case_priorities = { "P2" }
    value.cdp_execution.mutation_fixtures = {
      {
        case_id = "dashboard:write-flow",
        mutation_kind = "create-test-data",
        fixture_ref = ".testing/runs/fixtures/dashboard-create",
        evidence_pointer = ".testing/runs/evidence/dashboard-create",
      },
    }
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.execution_status, "degraded")
    t.eq(artifact.classification, "no-executable-safe-cases")
    t.eq(artifact.action_count, 0)
  end,

  test_executes_ai_generated_read_only_actions_through_bounded_schema = function()
    local value = payload()
    value.module_discovery.observations[1].route = "/app/dashboard"
    value.cdp_execution.ai_generation = {
      schema = "testing-runner.ai-case-generation.request.v1",
      mode = "draft",
      case_budget = 1,
    }
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.execution_status, "passed")
    t.eq(artifact.classification, "bounded-exploration-complete")
    t.eq(artifact.ai_generation.executable_generated_case_count, 1)
    t.eq(artifact.ai_context_manifest_path, ".testing/runs/module-a-cdp/ai-context-manifest.json")
    t.eq(artifact.generated_cases_path, ".testing/runs/module-a-cdp/generated-test-cases.json")
    t.eq(artifact.generated_case_gate_path, ".testing/runs/module-a-cdp/generated-case-gate.json")
    t.eq(artifact.actions[6].case_origin, "ai-generated")
    t.eq(artifact.actions[6].action, "open-visible-surface")
    t.eq(artifact.actions[6].provenance_digest:find("local-reviewed", 1, true) ~= nil, true)
  end,

  test_ai_generated_unknown_action_is_rejected_before_execution = function()
    local value = payload()
    value.cdp_execution.ai_generation = {
      schema = "testing-runner.ai-case-generation.request.v1",
      mode = "draft",
      case_budget = 1,
    }
    value.cdp_execution.generated_cases = {
      schema = "testing-runner.generated-test-cases.v1",
      artifact_kind = "generated-test-cases",
      artifact_root = ".testing/runs/module-a-cdp",
      context_manifest_path = ".testing/runs/module-a-cdp/ai-context-manifest.json",
      generation_mode = "draft",
      generation_digest = "gen-dashboard",
      cases = {
        {
          id = "dashboard:ai-unknown",
          module_id = "dashboard",
          priority = "P1",
          title = "Unknown action",
          objective = "Unknown action",
          case_kind = "read-only-interaction",
          actions = { { action = "click-anything", target = "Dashboard" } },
          expected_observable = "bounded result",
        },
      },
      case_count = 1,
    }
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.ai_generation.rejected_generated_case_count, 1)
    t.eq(artifact.planned_case_count, 5)
  end,

  test_autonomous_reviewed_generated_case_executes_only_after_agent_approval = function()
    local value = payload()
    value.module_discovery.observations[1].route = "/app/dashboard"
    value.cdp_execution.ai_generation = {
      schema = "testing-runner.ai-case-generation.request.v1",
      mode = "autonomous-reviewed",
      case_budget = 1,
    }
    value.cdp_execution.ai_agent_generation = {
      schema = "testing-runner.ai-agent-generation.v1",
      artifact_kind = "ai-agent-generation",
      artifact_root = ".testing/runs/module-a-cdp",
      context_manifest_path = ".testing/runs/module-a-cdp/ai-context-manifest.json",
      generated_cases_path = ".testing/runs/module-a-cdp/generated-test-cases.json",
      status = "approved",
      mode = "autonomous-reviewed",
      generation_digest = "agent-gen-dashboard",
      generated_case_count = 1,
      seat_count = 4,
      seat_names = { "teleology", "parsimony", "fidelity", "high-risk" },
    }
    value.cdp_execution.generated_case_agent_review = {
      schema = "testing-runner.generated-case-agent-review.v1",
      artifact_kind = "generated-case-agent-review",
      artifact_root = ".testing/runs/module-a-cdp",
      context_manifest_path = ".testing/runs/module-a-cdp/ai-context-manifest.json",
      generated_cases_path = ".testing/runs/module-a-cdp/generated-test-cases.json",
      generated_case_gate_path = ".testing/runs/module-a-cdp/generated-case-gate.json",
      generated_case_agent_review_path = ".testing/runs/module-a-cdp/generated-case-agent-review.json",
      status = "approved",
      mode = "autonomous-reviewed",
      decision_digest = "agent-review-dashboard",
      approved_case_ids = { "dashboard:ai-visible-surface" },
      approved_case_count = 1,
      rejected_case_count = 0,
      blocked_case_count = 0,
      seat_count = 4,
      seat_names = { "teleology", "parsimony", "fidelity", "high-risk" },
    }
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.ai_generation.agent_review_status, "approved")
    t.eq(artifact.ai_agent_generation_path, ".testing/runs/module-a-cdp/ai-agent-generation.json")
    t.eq(artifact.generated_case_agent_review_path, ".testing/runs/module-a-cdp/generated-case-agent-review.json")
    t.eq(artifact.actions[6].case_origin, "ai-generated")
  end,

  test_autonomous_reviewed_rejection_blocks_generated_execution = function()
    local value = payload()
    value.module_discovery.observations[1].route = "/app/dashboard"
    value.cdp_execution.ai_generation = {
      schema = "testing-runner.ai-case-generation.request.v1",
      mode = "autonomous-reviewed",
      case_budget = 1,
    }
    value.cdp_execution.ai_agent_generation = {
      schema = "testing-runner.ai-agent-generation.v1",
      artifact_kind = "ai-agent-generation",
      artifact_root = ".testing/runs/module-a-cdp",
      context_manifest_path = ".testing/runs/module-a-cdp/ai-context-manifest.json",
      generated_cases_path = ".testing/runs/module-a-cdp/generated-test-cases.json",
      status = "approved",
      mode = "autonomous-reviewed",
      generation_digest = "agent-gen-dashboard",
      generated_case_count = 1,
      seat_count = 5,
    }
    value.cdp_execution.generated_case_agent_review = {
      schema = "testing-runner.generated-case-agent-review.v1",
      artifact_kind = "generated-case-agent-review",
      artifact_root = ".testing/runs/module-a-cdp",
      context_manifest_path = ".testing/runs/module-a-cdp/ai-context-manifest.json",
      generated_cases_path = ".testing/runs/module-a-cdp/generated-test-cases.json",
      generated_case_gate_path = ".testing/runs/module-a-cdp/generated-case-gate.json",
      generated_case_agent_review_path = ".testing/runs/module-a-cdp/generated-case-agent-review.json",
      status = "rejected",
      mode = "autonomous-reviewed",
      decision_digest = "agent-review-dashboard",
      approved_case_ids = {},
      approved_case_count = 0,
      rejected_case_count = 1,
      blocked_case_count = 1,
      seat_count = 5,
    }
    local artifact = cdp.build(value, ".testing/runs/module-a-cdp", { readiness = { status = "ready" } })
    t.eq(artifact.ai_generation.agent_review_status, "rejected")
    t.eq(artifact.planned_case_count, 5)
    for _, action in ipairs(artifact.actions) do
      t.eq(action.case_origin, nil)
    end
  end,
}
