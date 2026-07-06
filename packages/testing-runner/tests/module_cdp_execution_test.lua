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

  test_rejects_embedded_browser_state_in_execution_request = function()
    t.raises(function()
      cdp.validate_request({
        schema = "testing-runner.module-cdp-execution.v1",
        step_budget = 4,
        screenshot = "inline-browser-state",
      })
    end)
  end,
}
