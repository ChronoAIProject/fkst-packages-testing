local graph = require("testkit.graph")
local core = require("core")

local t = fkst.test

local function app_scope_event()
  return {
    queue = "app_scope",
    source_ref = { kind = "external", reference = "edge-coverage-discovery" },
    payload = {
      schema = core.scope_schema,
      base_url = "http://localhost:8080/app",
      allowed_origins = { "http://localhost:8080" },
      sessions = {
        { role = "base", browser_harness_command = "true" },
        { role = "cdp", cdp_url = "http://127.0.0.1:9222" },
      },
      observations = {
        {
          id = "dashboard",
          name = "Dashboard",
          entry_url = "http://localhost:8080/app/dashboard",
          visible_label = "Dashboard",
          discovery_source = "browser-visible",
          confidence = "high",
          evidence_pointer = ".testing/runs/discovery/evidence/dashboard",
        },
      },
      artifact_root = ".testing/runs/discovery",
      source_ref = { kind = "host-app", ref = "local-app" },
      trace_id = "trace-discovery",
      dedup_key = "dedup-discovery",
    },
  }
end

local function ready_result_event()
  return {
    queue = "browser-readiness.browser_readiness_result",
    source_ref = { kind = "external", reference = "edge-coverage-discovery-readiness" },
    payload = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "base", status = "ready" },
        { role = "cdp", status = "ready" },
      },
      source_ref = { kind = "testing-discovery-plan", ref = ".testing/runs/discovery" },
      request_context = { dry_run = false },
    },
  }
end

return {
  test_run_graph_readiness_check_edge_is_covered = function()
    local trace = graph.require_quiescent(graph.run(app_scope_event(), { max_steps = 12 }))

    graph.assert_covers(trace, {
      "browser-readiness.browser_readiness_check -> browser-readiness.check_readiness",
    })

    local ready = graph.require_raise(trace, "browser-readiness.browser_readiness_result")
    t.eq(ready.payload.source_ref.kind, "testing-discovery-plan")
  end,

  test_run_graph_readiness_result_edge_is_covered = function()
    core.write_plan(core.plan(app_scope_event().payload))

    local trace = graph.require_quiescent(graph.run(ready_result_event(), { max_steps = 14 }))

    graph.assert_covers(trace, {
      "browser-readiness.browser_readiness_result -> testing-discovery.emit_modules",
    })
  end,
}
