local graph = require("testkit.graph")
local runtime_ports = require("ports")
local t = fkst.test

local state_path = ".testing/runs/environment-graph/operation-state.json"

local function cleanup_state()
  local ok = os.execute("rm -rf .testing/runs/environment-graph")
  t.is_true(ok == true or ok == 0)
end

return {
  test_browser_readiness_result_routes_but_plain_state_fails_closed = function()
    cleanup_state()
    local ok = os.execute("mkdir -p .testing/runs/environment-graph")
    t.is_true(ok == true or ok == 0)
    local handle = assert(io.open(state_path, "w"))
    handle:write(runtime_ports.encode_json({ schema = "environment-factory.operation-state.v1" }))
    handle:write("\n")
    handle:close()

    local trace = graph.run({
      queue = "browser-readiness.browser_readiness_result",
      source_ref = { kind = "external", reference = "environment-graph-readiness" },
      payload = {
        schema = "browser-readiness.result.v1",
        status = "ready",
        sessions = { { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } }, cdp_url = "http://127.0.0.1:9222" } },
        source_ref = { kind = "artifact", ref = state_path },
        request_context = { dry_run = false },
        correlation = {
          schema = "environment-factory.browser-readiness-correlation.v1",
          attempt_id = "graph-attempt",
          operation_id = "environment-graph",
          operation_state_ref = { kind = "artifact", ref = state_path },
          environment_receipt_ref = { kind = "artifact", ref = ".testing/runs/environment-graph/environment-receipt-ready.json" },
          base_url = "http://127.0.0.1:4312/health",
          sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
          trace_id = "trace-environment-graph",
          dedup_key = "dedup-environment-graph",
        },
      },
    }, { max_steps = 4 })

    graph.assert_covers(trace, {
      "browser-readiness.browser_readiness_result -> environment-factory.handoff",
    })
    local step = graph.require_delivery(trace, {
      queue = "browser-readiness.browser_readiness_result",
      consumer = "environment-factory.handoff",
    })
    t.eq(step.status, "error")
    t.is_true(tostring(step.error):find("runtime-config-unavailable", 1, true) ~= nil)
    cleanup_state()
  end,

  test_terminal_publication_routes_to_outbox_acknowledgement = function()
    local trace = graph.run({
      queue = "test-publication.publication_request",
      source_ref = { kind = "external", reference = "environment-terminal" },
      payload = {
        schema = "test-publication.publication-request.v1",
        source_ref = { kind = "artifact", ref = ".testing/runs/environment-graph/environment-receipt-ready.json" },
        trace_id = "trace-environment-graph",
        dedup_key = "dedup-environment-graph",
        status = "passed",
        job = "environment-graph-module",
        artifact_root = ".testing/runs/environment-graph/testing",
      },
    }, { max_steps = 4 })
    graph.assert_covers(trace, {
      "test-publication.publication_request -> environment-factory.acknowledge",
    })
    local step = graph.require_delivery(trace, {
      queue = "test-publication.publication_request",
      consumer = "environment-factory.acknowledge",
    })
    t.eq(step.status, "error")
  end,
}
