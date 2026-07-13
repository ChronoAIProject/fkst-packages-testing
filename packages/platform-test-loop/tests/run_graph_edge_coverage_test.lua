local graph = require("testkit.graph")

local function platform_loop_event()
  return {
    queue = "platform_loop_request",
    source_ref = { kind = "external", reference = "edge-coverage-platform" },
    payload = {
      schema = "platform-test-loop.start.v1",
      modules = { "edge-coverage-module" },
      backend = "fkst-native",
      no_browser = true,
      dry_run = false,
      artifact_root = ".testing/runs/edge-coverage-platform",
      source_ref = { kind = "platform", ref = "edge-coverage-platform" },
      trace_id = "trace-edge-coverage-platform",
      dedup_key = "edge-coverage-platform-run",
    },
  }
end

return {
  test_run_graph_platform_loop_edge_is_covered = function()
    local trace = graph.require_quiescent(graph.run(platform_loop_event(), { max_steps = 8 }))

    graph.assert_covers(trace, {
      "testing-runner.platform_test_request -> testing-runner.run_platform_loop",
    })
  end,
}
