local core = require("core")
local t = fkst.test

local function scope(overrides)
  local payload = {
    schema = core.scope_schema,
    base_url = "http://localhost:8080/app?drop=yes#frag",
    allowed_origins = { "http://localhost:8080" },
    sessions = {
      { role = "base", browser_harness_command = "true" },
      { role = "cdp", cdp_url = "http://127.0.0.1:9222" },
    },
    observations = {
      {
        id = "dashboard-route",
        name = "Dashboard",
        entry_url = "http://localhost:8080/app/dashboard?view=private#state",
        visible_label = "Dashboard",
        discovery_source = "navigation",
        confidence = "high",
        evidence_pointer = ".testing/runs/discovery/evidence/dashboard",
      },
      {
        id = "dashboard-browser-visible",
        name = "Dashboard action",
        entry_url = "http://localhost:8080/app/dashboard/actions?x=1#modal",
        visible_label = "Dashboard action",
        discovery_source = "browser-visible",
        evidence_pointer = ".testing/runs/discovery/evidence/dashboard-action",
      },
      {
        id = "settings-a11y",
        name = "Settings",
        route = "/app/settings?tab=profile#main",
        visible_label = "Settings",
        source = "accessibility",
        confidence = "medium",
        evidence_pointer = ".testing/runs/discovery/evidence/settings",
      },
      {
        id = "external",
        name = "External",
        entry_url = "http://127.0.0.1:9999/app/external",
        visible_label = "External",
        discovery_source = "navigation",
        evidence_pointer = ".testing/runs/discovery/evidence/external",
      },
    },
    artifact_root = ".testing/runs/discovery",
    source_ref = { kind = "host-app", ref = "local-app" },
    trace_id = "trace-discovery",
    dedup_key = "dedup-discovery",
  }
  for key, value in pairs(overrides or {}) do payload[key] = value end
  return payload
end

local function ready_result()
  return {
    schema = "browser-readiness.result.v1",
    status = "ready",
    sessions = {
      { role = "base_url", status = "ready" },
      { role = "cdp", status = "ready" },
    },
    source_ref = { kind = "testing-discovery-plan", ref = ".testing/runs/discovery" },
  }
end

local function inspect_no_fragment(value)
  local kind = type(value)
  if kind == "string" then
    t.eq(value:find("drop=yes", 1, true), nil)
    t.eq(value:find("view=private", 1, true), nil)
    t.eq(value:find("#", 1, true), nil)
  elseif kind == "table" then
    for key, item in pairs(value) do
      inspect_no_fragment(key)
      inspect_no_fragment(item)
    end
  end
end

return {
  test_valid_scope_produces_sanitized_discovery_plan = function()
    local plan = core.plan(scope())
    t.eq(plan.schema, "testing-discovery.plan.v1")
    t.eq(plan.base_url, "http://localhost:8080/app")
    t.eq(plan.allowed_origins[1], "http://localhost:8080")
    t.eq(plan.module_count, 2)
    t.eq(plan.modules[1].id, "dashboard")
    t.eq(#plan.modules[1].observations, 2)
    t.eq(plan.modules[1].observations[2].discovery_source, "browser-visible")
    t.eq(plan.modules[2].id, "settings")
    t.eq(plan.rejected_observation_count, 1)
    t.eq(plan.relation_graph_path, ".testing/runs/discovery/relation-graph.json")
    t.eq(plan.relation_graph.schema, "testing-discovery.relation-graph.v1")
    t.eq(plan.relation_graph.flow_budget, 4)
    t.eq(plan.relation_graph.module_depth, 2)
    t.eq(plan.relation_graph.relations[1].relation_type, "same-nav-cluster")
    inspect_no_fragment(plan)
  end,

  test_no_hand_authored_module_list_is_required = function()
    local plan = core.plan(scope({ budgets = { module_limit = 1, observation_limit = 3, step_budget = 5, case_priorities = { "P0" }, flow_budget = 2, module_depth = 3, relationship_limit = 0 } }))
    t.eq(plan.module_count, 1)
    t.eq(plan.modules[1].id, "dashboard")
    t.eq(plan.budgets.step_budget, 5)
    t.eq(plan.budgets.case_priorities[1], "P0")
    t.eq(plan.budgets.flow_budget, 2)
    t.eq(plan.budgets.module_depth, 3)
    t.eq(plan.budgets.relationship_limit, 0)
    t.eq(plan.relation_graph.relation_count, 0)
  end,

  test_empty_accepted_observations_emit_gap_module = function()
    local plan = core.plan(scope({ observations = {} }))
    t.eq(plan.module_count, 1)
    t.eq(plan.modules[1].id, "app-discovery")
    t.eq(#plan.modules[1].observations, 0)
    t.is_true(plan.limitations[#plan.limitations]:find("gap module", 1, true) ~= nil)
  end,

  test_scope_validation_rejects_non_local_and_missing_base_origin = function()
    t.raises(function()
      core.plan(scope({ base_url = "https://example.invalid/app", allowed_origins = { "https://example.invalid" } }))
    end)
    t.raises(function()
      core.plan(scope({ base_url = "https://localhost:8080/app", allowed_origins = { "https://localhost:8080" } }))
    end)
    t.raises(function()
      core.plan(scope({ allowed_origins = { "http://127.0.0.1:8080" } }))
    end)
  end,

  test_unknown_fields_and_inline_payload_fields_are_rejected = function()
    t.raises(function()
      core.plan(scope({ app_name = "local" }))
    end)
    t.raises(function()
      local payload = scope()
      payload.observations[1].screenshot = "inline-state"
      core.plan(payload)
    end)
  end,

  test_readiness_check_uses_only_readiness_control_fields = function()
    local plan = core.plan(scope())
    local request = core.readiness_check(plan)
    t.eq(request.schema, "browser-readiness.check.v1")
    t.eq(request.base_url, "http://localhost:8080/app")
    t.eq(request.source_ref.kind, "testing-discovery-plan")
    t.eq(request.source_ref.ref, ".testing/runs/discovery")
    t.eq(request.request_context.dry_run, false)
    t.eq(request.request_context.native_argv, nil)
  end,

  test_module_starts_emit_runner_compatible_pointer_only_facts = function()
    local plan = core.plan(scope())
    local starts = core.module_starts(plan, ready_result())
    t.eq(#starts, 2)
    t.eq(starts[1].schema, "module-testing-pipeline.module-start.v1")
    t.eq(starts[1].backend, "fkst-native")
    t.eq(starts[1].ui_loop.base_url, "http://localhost:8080/app")
    t.eq(starts[1].ui_loop.allowed_origins[1], "http://localhost:8080")
    t.eq(starts[1].ui_loop.platform_flow_ref, ".testing/runs/discovery/relation-graph.json")
    t.eq(starts[1].module_discovery.schema, "testing-runner.module-discovery.v1")
    t.eq(starts[1].module_discovery.observations[1].entry_url, "http://localhost:8080/app/dashboard")
    t.eq(starts[1].cdp_execution.schema, "testing-runner.module-cdp-execution.v1")
    t.eq(starts[1].artifact_root, ".testing/runs/discovery/modules/dashboard")
    inspect_no_fragment(starts)
  end,

  test_plan_artifact_round_trips = function()
    local written = {}
    local plan = core.plan(scope())
    local ok = core.write_plan(plan, function(path, body)
      written[path] = body
      return true
    end)
    t.eq(ok, true)
    t.is_true(written[".testing/runs/discovery/testing-discovery-plan.json"]:find('"relation_graph_path":".testing/runs/discovery/relation-graph.json"', 1, true) ~= nil)
    local decoded = core.read_plan(plan.artifact_root, function(path)
      return written[path]
    end)
    t.eq(decoded.schema, plan.schema)
    t.eq(decoded.module_count, plan.module_count)
    t.eq(decoded.modules[1].id, "dashboard")
    t.eq(decoded.relation_graph.schema, "testing-discovery.relation-graph.v1")
  end,

  test_saga_conformance_hook_passes = function()
    t.eq(#core.saga_conformance_errors(), 0)
  end,
}
