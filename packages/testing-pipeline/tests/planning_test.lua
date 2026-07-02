local projector = require("planning_projector")
local t = fkst.test

local function payload()
  return {
    schema = "testing-pipeline.module-start.v1",
    module = "module-a",
    artifact_root = ".testing/runs/module-a-plan",
    module_evidence = {
      entry = { route = "/modules/a", loaded = true, title = "Module A" },
      visible_elements = { "Module A heading", "Search box" },
      signals = { console = { clean = true }, network = { status = "clean" } },
      interactions = {
        { kind = "navigation", label = "Open details" },
        { kind = "filter", label = "Filter by status" },
        { kind = "write-flow", label = "Create record" },
        { kind = "state-change", label = "Toggle active state" },
        { kind = "negative-path", label = "Invalid search input" },
      },
    },
  }
end

return {
  test_projector_builds_feature_inventory_and_p0_p1_p2_plan = function()
    local inventory, plan = projector.project(payload(), {
      source_ref = { kind = "host", ref = "module-a" },
      trace_id = "trace-module-a",
      dedup_key = "dedup-module-a",
    })

    t.eq(inventory.schema, "testing-pipeline.feature-inventory.v1")
    t.eq(inventory.module, "module-a")
    t.eq(inventory.artifact_root, ".testing/runs/module-a-plan")
    t.eq(inventory.entry.target, "/modules/a")
    t.eq(inventory.counts.visible_elements, 2)
    t.eq(inventory.counts.interactions, 5)

    t.eq(plan.schema, "testing-pipeline.test-plan.v1")
    t.eq(plan.review_gate.schema, "testing-pipeline.review-gate.v1")
    t.is_true(#plan.priorities.P0 >= 5)
    t.is_true(#plan.priorities.P1 >= 2)
    t.is_true(#plan.priorities.P2 >= 4)
    t.is_true(plan.review_gate.counts.executable >= 7)
    t.is_true(plan.review_gate.counts.blocked >= 2)
    t.is_true(plan.review_gate.counts.not_executed_risk >= 1)
  end,

  test_projector_records_gaps_when_evidence_is_missing = function()
    local inventory, plan = projector.project({
      schema = "testing-pipeline.module-start.v1",
      module = "module-b",
      artifact_root = ".testing/runs/module-b-plan",
      module_evidence = { entry = { title = "Module B" } },
    }, {})

    t.eq(inventory.counts.interactions, 0)
    t.eq(plan.priorities.P0[1].review_status, "blocked")
    t.eq(plan.priorities.P1[1].review_status, "not-executed risk")
    t.eq(plan.priorities.P2[1].review_status, "not-executed risk")
    t.is_true(plan.review_gate.counts.blocked >= 1)
    t.is_true(plan.review_gate.counts.not_executed_risk >= 5)
  end,
}
