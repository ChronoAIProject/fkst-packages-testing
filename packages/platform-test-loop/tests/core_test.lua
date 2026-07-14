local core = require("core")
local json_codec = require("testing_runtime.json")
local t = fkst.test

local function module_result(module, status)
  return {
    schema = "testing-runner.result.v1",
    job = "module-test-loop",
    module = module,
    status = status,
    artifact_root = ".testing/runs/" .. module,
    source_ref = { kind = "module", ref = module },
    dedup_key = module .. "-run",
    exit_code = status == "passed" and 0 or 1,
  }
end

local function generic_host_module_result(module)
  return {
    schema = "testing-runner.result.v1",
    job = "module-test-loop",
    module = module,
    status = "passed",
    artifact_root = ".testing/runs/generic-host-" .. module,
    source_ref = { kind = "host-module", ref = module },
    trace_id = "trace-generic-host-" .. module,
    dedup_key = "generic-host-" .. module,
    exit_code = 0,
    adapter = { name = "fkst-native", mode = "module-no-browser" },
    native_summary = {
      schema = "testing-runner.module-no-browser-summary.v1",
      module = module,
      status = "passed",
      mode = "argv",
    },
  }
end

local function flow_module_result(module, status, flow_summary, outcome)
  local result = module_result(module, status)
  result.native_summary = {
    schema = "testing-runner.module-cdp-execution-summary.v1",
    module = module,
    status = status,
    outcome_classification = outcome,
    platform_flow_summary = flow_summary,
  }
  return result
end

local graph_path = ".testing/runs/schedule/relation-graph.json"

local function scheduled_request(module, priority)
  return {
    schema = "testing-runner.module-test-loop.request.v1",
    module = module,
    backend = "fkst-native",
    dry_run = false,
    ui_loop = {
      base_url = "http://localhost:8080/app",
      allowed_origins = { "http://localhost:8080" },
      priority = { priority },
      platform_flow_ref = graph_path,
    },
    module_discovery = {
      schema = "testing-runner.module-discovery.v1",
      observations = {},
    },
    cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 1,
      case_priorities = { "P0" },
    },
    preflight_result = { status = "ready" },
    artifact_root = ".testing/runs/schedule/modules/" .. module,
    source_ref = { kind = "testing-discovery-relation-graph", ref = graph_path },
    trace_id = "trace-" .. module,
    dedup_key = "dedup-" .. module,
  }
end

local function relation_graph()
  return {
    schema = "testing-discovery.relation-graph.v2",
    artifact_kind = "testing-schedule-relation-graph",
    relation_graph_path = graph_path,
    run_id = "schedule-run",
    artifact_root = ".testing/runs/schedule",
    aggregate_artifact_root = ".testing/runs/schedule/platform",
    aggregate_result_path = ".testing/runs/schedule/platform/aggregate.json",
    source_ref = { kind = "host-app", ref = "local-app" },
    trace_id = "trace-schedule",
    dedup_key = "dedup-schedule",
    nodes = {
      { id = "p1", priority = "P1", request = scheduled_request("p1", "P1") },
      { id = "p0", priority = "P0", request = scheduled_request("p0", "P0") },
    },
    edges = { { from = "p0", to = "p1" } },
    node_count = 2,
    edge_count = 1,
  }
end

local function copy_graph()
  return json.decode(json_codec.encode(relation_graph()))
end

local function scheduled_result(module)
  local result = module_result(module, "passed")
  result.artifact_root = ".testing/runs/schedule/modules/" .. module
  result.source_ref = { kind = "testing-discovery-relation-graph", ref = graph_path }
  return result
end

return {
  test_builds_platform_runner_request = function()
    local request = core.runner_request({
      schema = "platform-test-loop.start.v1",
      modules = { "a", "b" },
      priority = { "P0", "P1" },
      e2e_driver = "browser_harness",
      backend = "fkst-native",
      preflight_result = { status = "ready" },
      trace_id = "trace-platform",
      dedup_key = "dedup-platform",
    })
    t.eq(request.schema, "testing-runner.platform-test-loop.request.v1")
    t.eq(request.modules[2], "b")
    t.eq(request.priority[1], "P0")
    t.eq(request.e2e_driver, "browser_harness")
    t.eq(request.backend, "fkst-native")
    t.eq(request.preflight_result.status, "ready")
    t.eq(request.trace_id, "trace-platform")
    t.eq(request.dedup_key, "dedup-platform")
  end,

  test_dependency_completion_releases_waves_independent_of_node_order = function()
    local graph = relation_graph()
    local initial = core.coordinate(graph, {})
    t.eq(#initial.wave, 1)
    t.eq(initial.wave[1].module, "p0")
    t.eq(initial.aggregate, nil)

    local after_p0, results = core.consume_terminal_result(graph, {}, scheduled_result("p0"))
    t.eq(#after_p0.wave, 1)
    t.eq(after_p0.wave[1].module, "p1")
    t.eq(after_p0.aggregate, nil)

    local complete = core.consume_terminal_result(graph, results, scheduled_result("p1"))
    t.eq(#complete.wave, 0)
    t.eq(complete.aggregate.status, "passed")
    t.eq(complete.aggregate.counts.total, 2)
    t.eq(complete.aggregate.modules[1].module, "p1")
    t.eq(complete.aggregate.modules[2].module, "p0")
    t.eq(complete.aggregate.result_path, ".testing/runs/schedule/platform/aggregate.json")
  end,

  test_relation_graph_loads_and_aggregate_writer_persists_one_result = function()
    local body = json_codec.encode(relation_graph())
    local loaded = core.read_relation_graph(graph_path, function(path)
      t.eq(path, graph_path)
      return body
    end)
    local action = core.coordinate(loaded, { scheduled_result("p0"), scheduled_result("p1") })
    local writes = 0
    local written_path
    local ok = core.write_aggregate_result(action.aggregate, function(path, aggregate_body)
      writes = writes + 1
      written_path = path
      t.is_true(aggregate_body:find('"counts"', 1, true) ~= nil)
      return true
    end)
    t.eq(ok, true)
    t.eq(writes, 1)
    t.eq(written_path, relation_graph().aggregate_result_path)
  end,

  test_relation_graph_rejects_runner_command_injection = function()
    local graph = relation_graph()
    graph.nodes[1].request.native_argv = { "true" }
    t.raises(function() core.validate_relation_graph(graph) end)
  end,

  test_terminal_result_must_match_graph_artifact_root = function()
    local result = scheduled_result("p0")
    result.artifact_root = ".testing/runs/other"
    t.raises(function() core.coordinate(relation_graph(), { result }) end)
  end,

  test_relation_graph_validation_rejects_malformed_authoritative_fields = function()
    local mutations = {
      function(graph) graph.schema = "other" end,
      function(graph) graph.relation_graph_path = ".testing/runs/other/relation-graph.json" end,
      function(graph) graph.aggregate_artifact_root = ".testing/runs/schedule/other" end,
      function(graph) graph.aggregate_result_path = ".testing/runs/schedule/platform/other.json" end,
      function(graph) graph.run_id = nil end,
      function(graph) graph.nodes = {} graph.node_count = 0 end,
      function(graph) graph.edges = { [2] = { from = "p0", to = "p1" } } graph.edge_count = 1 end,
      function(graph) graph.node_count = 1 end,
      function(graph) graph.nodes[1].id = nil end,
      function(graph) graph.nodes[1].request.schema = "other" end,
      function(graph) graph.nodes[1].request.backend = "other" end,
      function(graph) graph.nodes[1].request.artifact_root = ".testing/runs/other" end,
      function(graph) graph.nodes[1].request.preflight_result = nil end,
      function(graph) graph.nodes[1].request.ui_loop.priority = { "P0" } end,
      function(graph) graph.nodes[1].request.module_discovery = nil end,
      function(graph) graph.nodes[1].request.cdp_execution = nil end,
      function(graph) graph.nodes[1].request.trace_id = nil end,
      function(graph) graph.nodes[1].request.source_ref.ref = ".testing/runs/other/relation-graph.json" end,
      function(graph) graph.edges[1].from = nil end,
      function(graph) graph.edges[1].from = "p1" end,
    }
    for _, mutate in ipairs(mutations) do
      local graph = copy_graph()
      mutate(graph)
      t.raises(function() core.validate_relation_graph(graph) end)
    end
  end,

  test_relation_graph_reader_rejects_bad_paths_bodies_and_path_mismatch = function()
    t.raises(function() core.read_relation_graph(".testing/runs/schedule/other.json", function() return "{}" end) end)
    t.raises(function() core.read_relation_graph(graph_path, function() return "" end) end)
    t.raises(function() core.read_relation_graph(graph_path, function() return "not-json" end) end)
    local graph = copy_graph()
    graph.relation_graph_path = ".testing/runs/other/relation-graph.json"
    t.raises(function() core.read_relation_graph(graph_path, function() return json_codec.encode(graph) end) end)
  end,

  test_schedule_request_rejects_unknown_schema_and_wrong_source = function()
    t.raises(function() core.validate_schedule_request({ schema = "other" }) end)
    t.raises(function()
      core.validate_schedule_request({
        schema = "platform-test-loop.schedule.v1",
        relation_graph_path = graph_path,
        artifact_root = ".testing/runs/schedule/platform",
        source_ref = { kind = "other", ref = graph_path },
      })
    end)
  end,

  test_terminal_result_rejects_nonterminal_and_unbound_results = function()
    local invalid = {
      { status = "passed", source_ref = { kind = "testing-discovery-relation-graph", ref = graph_path }, module = "p0" },
      { schema = "testing-runner.result.v1", job = "module-test-loop", status = "planned", source_ref = { kind = "testing-discovery-relation-graph", ref = graph_path }, module = "p0" },
      { schema = "testing-runner.result.v1", job = "module-test-loop", status = "passed", source_ref = { kind = "other", ref = graph_path }, module = "p0" },
      { schema = "testing-runner.result.v1", job = "module-test-loop", status = "passed", source_ref = { kind = "testing-discovery-relation-graph", ref = graph_path } },
    }
    for _, result in ipairs(invalid) do
      result.artifact_root = ".testing/runs/schedule/modules/p0"
      t.raises(function() core.coordinate(relation_graph(), { result }) end)
    end
  end,

  test_coordinate_sorts_ready_nodes_and_rejects_sparse_results = function()
    local graph = copy_graph()
    graph.edges = {}
    graph.edge_count = 0
    local action = core.coordinate(graph, {})
    t.eq(action.wave[1].module, "p0")
    t.eq(action.wave[2].module, "p1")
    local results = { [2] = scheduled_result("p0") }
    t.raises(function() core.coordinate(graph, results) end)

    graph.nodes[1].priority = "P0"
    graph.nodes[1].request.ui_loop.priority = { "P0" }
    action = core.coordinate(graph, {})
    t.eq(action.wave[1].module, "p0")
    t.eq(action.wave[2].module, "p1")
  end,

  test_result_collection_rejects_invalid_runner_metadata = function()
    t.raises(function()
      core.results_from_artifacts(relation_graph(), scheduled_result("p1"), function()
        return json_codec.encode({ schema = "other", status = "passed" })
      end)
    end)
  end,

  test_aggregate_writer_rejects_invalid_result_shapes = function()
    t.raises(function() core.write_aggregate_result({ schema = "other" }, function() return true end) end)
    local aggregate = core.coordinate(relation_graph(), { scheduled_result("p0"), scheduled_result("p1") }).aggregate
    aggregate.result_path = ".testing/runs/other/aggregate.json"
    t.raises(function() core.write_aggregate_result(aggregate, function() return true end) end)
  end,

  test_rejects_sparse_modules = function()
    t.raises(function()
      local modules = {}
      modules[1] = "a"
      modules[3] = "c"
      core.runner_request({ schema = "platform-test-loop.start.v1", modules = modules })
    end)
  end,

  test_aggregate_defaults_to_planned_modules = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      modules = { "module-a", "module-b" },
      platform = "generic-platform",
      artifact_root = ".testing/runs/platform",
      trace_id = "trace-platform",
      dedup_key = "platform-run",
    })
    t.eq(result.status, "planned")
    t.eq(result.counts.total, 2)
    t.eq(result.counts.planned, 2)
    t.eq(result.modules[1].module, "module-a")
    t.eq(result.modules[2].status, "planned")
    t.eq(result.artifact_root, ".testing/runs/platform")
    t.eq(result.metadata_path, ".testing/runs/platform/metadata.json")
    t.eq(result.trace_id, "trace-platform")
    t.eq(result.dedup_key, "platform-run")
  end,

  test_aggregate_all_passed = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        module_result("module-a", "passed"),
        module_result("module-b", "passed"),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.status, "passed")
    t.eq(result.counts.passed, 2)
    t.eq(result.modules[1].dedup_key, "module-a-run")
    t.eq(result.modules[2].exit_code, 0)
  end,

  test_generic_host_module_results_aggregate_to_platform_passed = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        generic_host_module_result("module-a"),
        generic_host_module_result("module-b"),
      },
      artifact_root = ".testing/runs/generic-host-platform",
      source_ref = { kind = "host-platform", ref = "generic-host" },
      trace_id = "trace-generic-host-platform",
      dedup_key = "generic-host-platform",
    })
    t.eq(result.schema, "platform-test-loop.aggregate.v1")
    t.eq(result.status, "passed")
    t.eq(result.counts.total, 2)
    t.eq(result.counts.passed, 2)
    t.eq(result.modules[1].module, "module-a")
    t.eq(result.modules[1].status, "passed")
    t.eq(result.modules[1].artifact_root, ".testing/runs/generic-host-module-a")
    t.eq(result.modules[1].dedup_key, "generic-host-module-a")
    t.eq(result.modules[1].exit_code, 0)
    t.eq(result.modules[2].module, "module-b")
    t.eq(result.modules[2].status, "passed")
    t.eq(result.modules[2].artifact_root, ".testing/runs/generic-host-module-b")
    t.eq(result.modules[2].dedup_key, "generic-host-module-b")
    t.eq(result.modules[2].exit_code, 0)
    t.eq(result.artifact_root, ".testing/runs/generic-host-platform")
    t.eq(result.metadata_path, ".testing/runs/generic-host-platform/metadata.json")
    t.eq(result.source_ref.kind, "host-platform")
    t.eq(result.source_ref.ref, "generic-host")
    t.eq(result.trace_id, "trace-generic-host-platform")
    t.eq(result.dedup_key, "generic-host-platform")
  end,

  test_aggregate_all_failed = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        module_result("module-a", "failed"),
        module_result("module-b", "failed"),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.status, "failed")
    t.eq(result.counts.failed, 2)
  end,

  test_aggregate_all_blocked = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        module_result("module-a", "blocked"),
        module_result("module-b", "blocked"),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.status, "blocked")
    t.eq(result.counts.blocked, 2)
  end,

  test_aggregate_all_degraded = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        module_result("module-a", "degraded"),
        module_result("module-b", "degraded"),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.status, "degraded")
    t.eq(result.counts.degraded, 2)
  end,

  test_aggregate_mixed_statuses = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        module_result("module-a", "passed"),
        module_result("module-b", "failed"),
        module_result("module-c", "blocked"),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.status, "mixed")
    t.eq(result.counts.passed, 1)
    t.eq(result.counts.failed, 1)
    t.eq(result.counts.blocked, 1)
  end,

  test_aggregate_counts_multi_module_flow_summaries = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        flow_module_result("module-a", "passed", {
          planned = 2,
          executed = 1,
          skipped = 1,
          blocked_by_safety_gate = 1,
        }),
        flow_module_result("module-b", "degraded", {
          flows_planned = 3,
          flows_executed = 1,
          flows_skipped = 2,
          fixture_gap_blocked = 1,
          environment_readiness_blocked = 1,
        }),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.flow_summary.schema, "platform-test-loop.flow-summary.v1")
    t.eq(result.flow_summary.planned, 5)
    t.eq(result.flow_summary.executed, 2)
    t.eq(result.flow_summary.skipped, 3)
    t.eq(result.flow_summary.blocked_by_safety_gate, 1)
    t.eq(result.flow_summary.blocked_by_fixture_gap, 1)
    t.eq(result.flow_summary.blocked_by_environment_readiness, 1)
    t.eq(result.platform_flows.planned, 5)
  end,

  test_aggregate_derives_flow_gaps_from_outcomes_without_breaking_status = function()
    local result = core.aggregate_result({
      schema = "platform-test-loop.aggregate.v1",
      module_results = {
        flow_module_result("module-a", "blocked", nil, "data-fixture-gap"),
        flow_module_result("module-b", "blocked", nil, "ai-generation-gap"),
        flow_module_result("module-c", "blocked", nil, "environment-session-issue"),
      },
      artifact_root = ".testing/runs/platform",
    })
    t.eq(result.status, "blocked")
    t.eq(result.flow_summary.planned, 3)
    t.eq(result.flow_summary.skipped, 3)
    t.eq(result.flow_summary.blocked_by_fixture_gap, 1)
    t.eq(result.flow_summary.blocked_by_safety_gate, 1)
    t.eq(result.flow_summary.blocked_by_environment_readiness, 1)
  end,

  test_aggregate_rejects_sparse_module_results = function()
    t.raises(function()
      local module_results = {}
      module_results[1] = module_result("module-a", "passed")
      module_results[3] = module_result("module-c", "passed")
      core.aggregate_result({ schema = "platform-test-loop.aggregate.v1", module_results = module_results })
    end)
  end,

  test_aggregate_rejects_unsafe_module_artifact_root = function()
    t.raises(function()
      local result = module_result("module-a", "passed")
      result.artifact_root = "../outside"
      core.aggregate_result({
        schema = "platform-test-loop.aggregate.v1",
        module_results = { result },
      })
    end)
  end,

  test_saga_conformance_hook_passes = function()
    t.eq(#core.saga_conformance_errors(), 0)
  end,
}
