local graph = require("testkit.graph")
local json_codec = require("testing_runtime.json")
local strings = require("contract.strings")
local t = fkst.test

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

local runtime_key = strings.decimal_checksum(os.getenv("FKST_RUNTIME_ROOT") or "platform-test-runtime")
local digest = string.rep("a", 64)

local function module_request(root, graph_path, module, priority, executable)
  local sessions = { { role = "base_url", status = "ready" } }
  local observations = {}
  if executable then
    table.insert(sessions, { role = "cdp", status = "ready", cdp_url = "http://127.0.0.1:9222" })
    table.insert(observations, {
      id = module,
      name = module,
      entry_url = "http://localhost:8080/app/" .. module,
      visible_label = module,
      discovery_source = "navigation",
      confidence = "high",
      evidence_pointer = root .. "/evidence/" .. module,
    })
  end
  return {
    schema = "testing-runner.module-test-loop.request.v1",
    module = module,
    backend = "fkst-native",
    dry_run = false,
    preflight_result = { status = "ready", sessions = sessions },
    ui_loop = {
      base_url = "http://localhost:8080/app",
      allowed_origins = { "http://localhost:8080" },
      cdp_readiness_ref = "cdp-ready",
      platform_flow_ref = graph_path,
      priority = { priority },
    },
    module_discovery = { schema = "testing-runner.module-discovery.v1", observations = observations },
    cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 1,
      case_priorities = { "P0" },
    },
    artifact_root = root .. "/modules/" .. module,
    source_ref = { kind = "testing-discovery-relation-graph", ref = graph_path },
    trace_id = "trace-" .. module,
    dedup_key = "dedup-" .. module,
  }
end

local function write_receipt(root, module)
  local pointer = root .. "/modules/" .. module .. "/evidence/execution/" .. module .. "-reachability.json"
  local receipt = {
    schema = "testing-runtime.execution-receipt.v1",
    module = module,
    request_sha256 = digest,
    status = "passed",
    classification = "typed-browser-assertions-passed",
    action_count = 1,
    executed_action_count = 1,
    failed_action_count = 0,
    blocked_action_count = 0,
    actions = {
      {
        step = 1,
        case_id = module .. ":reachability",
        action = "navigate",
        execution_status = "executed",
        assertion_status = "passed",
        observation = "typed browser action and assertions completed",
        evidence_pointer = pointer,
        assertion_results = {
          { type = "url-within-scope", status = "passed", observation = "url-within-scope passed", evidence_pointer = pointer },
          { type = "document-ready", status = "passed", observation = "document-ready passed", evidence_pointer = pointer },
        },
      },
    },
  }
  os.execute("mkdir -p " .. root .. "/modules/" .. module)
  local handle = assert(io.open(root .. "/modules/" .. module .. "/browser-execution-receipt.json", "w"))
  handle:write(json_codec.encode(receipt) .. "\n")
  handle:close()
end

local function schedule_event(name, dependent, executable)
  local root = ".testing/runs/platform-schedule-" .. name .. "-" .. runtime_key
  local graph_path = root .. "/relation-graph.json"
  local nodes = {
    { id = "p0", priority = "P0", request = module_request(root, graph_path, "p0", "P0", executable) },
  }
  local edges = {}
  if dependent then
    table.insert(nodes, { id = "p1", priority = "P1", request = module_request(root, graph_path, "p1", "P1", executable) })
    table.insert(edges, { from = "p0", to = "p1" })
  end
  local relation_graph = {
    schema = "testing-discovery.relation-graph.v2",
    artifact_kind = "testing-schedule-relation-graph",
    relation_graph_path = graph_path,
    run_id = "platform-schedule-" .. name,
    artifact_root = root,
    aggregate_artifact_root = root .. "/platform",
    aggregate_result_path = root .. "/platform/aggregate.json",
    source_ref = { kind = "host-app", ref = name },
    trace_id = "trace-platform-schedule-" .. name,
    dedup_key = "dedup-platform-schedule-" .. name,
    nodes = nodes,
    edges = edges,
    node_count = #nodes,
    edge_count = #edges,
  }
  os.execute("mkdir -p " .. root)
  if executable then
    write_receipt(root, "p0")
    if dependent then write_receipt(root, "p1") end
  end
  local handle = assert(io.open(graph_path, "w"))
  handle:write(json_codec.encode(relation_graph) .. "\n")
  handle:close()
  return {
    queue = "platform_loop_request",
    source_ref = { kind = "external", reference = name },
    payload = {
      schema = "platform-test-loop.schedule.v1",
      relation_graph_path = graph_path,
      artifact_root = root .. "/platform",
      source_ref = { kind = "testing-discovery-relation-graph", ref = graph_path },
      trace_id = "trace-platform-schedule-" .. name,
      dedup_key = "dedup-platform-schedule-" .. name,
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

  test_schedule_graph_reaches_completion_collector = function()
    local trace = graph.require_quiescent(graph.run(schedule_event("complete", false), { max_steps = 8 }))
    graph.assert_covers(trace, {
      "testing-runner.testing_result -> platform-test-loop.collect_module_result",
    })
    local aggregate = graph.require_raise(trace, "platform-test-loop.platform_result").payload
    t.eq(aggregate.counts.total, 1)
    t.eq(aggregate.status, "blocked")
  end,

  test_successful_predecessor_releases_dependent_wave = function()
    for _ = 1, 2 do
      t.mock_command("hash-json", { exit_code = 0, stdout = digest .. "\n", stderr = "" })
      t.mock_command("execute", { exit_code = 0, stdout = "", stderr = "" })
    end
    local trace = graph.require_quiescent(graph.run(schedule_event("barrier", true, true), { max_steps = 8 }))
    local dependent = graph.require_raise(trace, "testing-runner.module_test_request", function(raised)
      return raised.payload.module == "p1"
    end)
    t.eq(dependent.payload.module, "p1")
    t.eq(graph.require_raise(trace, "platform-test-loop.platform_result").payload.counts.passed, 2)
  end,
}
