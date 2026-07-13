local planning = require("module_planning")
local t = fkst.test

local function inventory()
  return {
    schema = "testing-runner.module-inventory.v1",
    artifact_kind = "module-inventory",
    discovery_status = "complete",
    artifact_root = ".testing/runs/module-a-inventory",
    modules = {
      {
        id = "dashboard",
        name = "Dashboard",
        entry_url = "http://localhost:8080/app/dashboard",
        route = "/app/dashboard",
        visible_label = "Dashboard",
        discovery_source = "navigation",
        confidence = "high",
        evidence_pointer = ".testing/runs/evidence/dashboard",
      },
    },
    module_count = 1,
    limitations = { "Visible-session coverage only." },
    coverage = "visible-session-only",
    readiness = { status = "ready" },
  }
end

local function count_priority(module, priority)
  local count = 0
  for _, case in ipairs(module.cases) do
    if case.priority == priority then count = count + 1 end
  end
  return count
end

local function has_case(module, priority, status)
  for _, case in ipairs(module.cases) do
    if case.priority == priority and case.review_status == status then return true end
  end
  return false
end

local function find_case(module, suffix)
  for _, case in ipairs(module.cases) do
    if case.id == "dashboard:" .. suffix then return case end
  end
  return nil
end

return {
  test_builds_feature_inventory_and_p0_p1_p2_plan = function()
    local artifacts = planning.build(inventory(), { mutation_policy = "read-only" }, ".testing/runs/module-a-inventory")
    t.eq(artifacts.feature_inventory.schema, "testing-runner.feature-inventory.v1")
    t.eq(artifacts.feature_inventory.artifact_kind, "feature-inventory")
    t.eq(artifacts.feature_inventory.modules[1].id, "dashboard")
    t.eq(artifacts.feature_inventory.modules[1].feature_signals[1], "entry-route")
    t.eq(artifacts.test_plan.schema, "testing-runner.module-test-plan.v1")
    t.eq(artifacts.test_plan.artifact_kind, "module-test-plan")
    t.eq(artifacts.test_plan.plan_status, "complete")
    local module = artifacts.test_plan.modules[1]
    t.eq(count_priority(module, "P0"), 4)
    t.eq(count_priority(module, "P1"), 3)
    t.eq(count_priority(module, "P2"), 3)
    t.is_true(has_case(module, "P0", "executable"))
    t.is_true(has_case(module, "P1", "blocked"))
    t.is_true(has_case(module, "P2", "not-executed-risk"))
    t.eq(artifacts.test_plan.review_gate.mutation_policy, "read-only")
    t.eq(artifacts.test_plan.review_gate.readiness_status, "ready")
    t.is_true(artifacts.test_plan.review_gate.executable_count > 0)
    t.is_true(artifacts.test_plan.review_gate.blocked_count > 0)
    t.is_true(artifacts.test_plan.review_gate.not_executed_risk_count > 0)
  end,

  test_host_approved_mutation_policy_blocks_p2_until_fixtures_exist = function()
    local artifacts = planning.build(inventory(), { mutation_policy = "host-approved" }, ".testing/runs/module-a-inventory")
    local module = artifacts.test_plan.modules[1]
    t.is_true(has_case(module, "P2", "blocked"))
    local case = find_case(module, "write-flow")
    t.eq(case.mutation_gate.classification, "fixture-data-gap")
    t.eq(artifacts.test_plan.review_gate.mutation_policy, "host-approved")
  end,

  test_host_approved_mutation_policy_executes_safe_fixture_mutation = function()
    local artifacts = planning.build(inventory(), { mutation_policy = "host-approved" }, ".testing/runs/module-a-inventory", {
      mutation_fixtures = {
        {
          case_id = "dashboard:write-flow",
          mutation_kind = "create-test-data",
          fixture_lifecycle_path = ".testing/runs/fixtures/dashboard-lifecycle",
        },
      },
    })
    local module = artifacts.test_plan.modules[1]
    local case = find_case(module, "write-flow")
    t.eq(case.review_status, "executable")
    t.eq(case.mutation_gate.classification, "safe-local-test-data")
    t.eq(case.mutation_gate.fixture_lifecycle_path, ".testing/runs/fixtures/dashboard-lifecycle")
    t.eq(find_case(module, "state-change").review_status, "blocked")
  end,

  test_destructive_mutation_fixture_is_blocked_by_default = function()
    local artifacts = planning.build(inventory(), { mutation_policy = "host-approved" }, ".testing/runs/module-a-inventory", {
      mutation_fixtures = {
        {
          case_id = "dashboard:write-flow",
          mutation_kind = "delete",
          fixture_lifecycle_path = ".testing/runs/fixtures/dashboard-delete-lifecycle",
        },
      },
    })
    local case = find_case(artifacts.test_plan.modules[1], "write-flow")
    t.eq(case.review_status, "blocked")
    t.eq(case.mutation_gate.classification, "destructive-or-external-risk")
  end,

  test_degraded_inventory_produces_degraded_plan = function()
    local value = inventory()
    value.discovery_status = "degraded"
    value.modules = {}
    value.module_count = 0
    value.readiness = { status = "blocked" }
    local artifacts = planning.build(value, { mutation_policy = "read-only" }, ".testing/runs/module-a-inventory")
    t.eq(artifacts.test_plan.plan_status, "degraded")
    t.eq(artifacts.test_plan.review_gate.status, "degraded")
    t.eq(artifacts.test_plan.review_gate.readiness_status, "blocked")
    t.eq(#artifacts.test_plan.modules, 0)
  end,
}
