local graph = require("testkit.graph")

local function online_regression_event()
  return {
    queue = "online_regression_start",
    source_ref = { kind = "external", reference = "edge-coverage-online" },
    payload = {
      schema = "online-regression.start.v1",
      driver = "edge-coverage-driver",
      heartbeat_url = "http://localhost:8080/health",
      backend = "fkst-native",
      no_browser = true,
      dry_run = false,
      artifact_root = ".testing/runs/edge-coverage-online",
      source_ref = { kind = "online", ref = "edge-coverage-online" },
      trace_id = "trace-edge-coverage-online",
      dedup_key = "edge-coverage-online-run",
    },
  }
end

return {
  test_run_graph_online_regression_edge_is_covered = function()
    local trace = graph.require_quiescent(graph.run(online_regression_event(), { max_steps = 8 }))

    graph.assert_covers(trace, {
      "testing-runner.online_regression_request -> testing-runner.run_online_regression",
    })
  end,
}
