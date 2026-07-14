local dept = require("departments.collect_module_result.main")
local json_codec = require("testing_runtime.json")
local strings = require("contract.strings")
local testing = require("testkit.testing")
local t = fkst.test

local runtime_key = strings.decimal_checksum(os.getenv("FKST_RUNTIME_ROOT") or "platform-department-runtime")

local function write_json(path, value)
  local directory = assert(path:match("^(.*)/[^/]+$"))
  os.execute("mkdir -p " .. directory)
  local handle = assert(io.open(path, "w"))
  handle:write(json_codec.encode(value) .. "\n")
  handle:close()
end

local function module_request(root, graph_path, module, priority)
  return {
    schema = "testing-runner.module-test-loop.request.v1",
    module = module,
    backend = "fkst-native",
    dry_run = false,
    preflight_result = { status = "ready" },
    ui_loop = {
      base_url = "http://localhost:8080/app",
      allowed_origins = { "http://localhost:8080" },
      platform_flow_ref = graph_path,
      priority = { priority },
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
    artifact_root = root .. "/modules/" .. module,
    source_ref = { kind = "testing-discovery-relation-graph", ref = graph_path },
    trace_id = "trace-" .. module,
    dedup_key = "dedup-" .. module,
  }
end

local function write_graph()
  local root = ".testing/runs/platform-department-" .. runtime_key
  local graph_path = root .. "/relation-graph.json"
  local graph = {
    schema = "testing-discovery.relation-graph.v2",
    artifact_kind = "testing-schedule-relation-graph",
    relation_graph_path = graph_path,
    run_id = "platform-department-run",
    artifact_root = root,
    aggregate_artifact_root = root .. "/platform",
    aggregate_result_path = root .. "/platform/aggregate.json",
    source_ref = { kind = "host-app", ref = "platform-department" },
    trace_id = "trace-platform-department",
    dedup_key = "dedup-platform-department",
    nodes = {
      { id = "p1", priority = "P1", request = module_request(root, graph_path, "p1", "P1") },
      { id = "p0", priority = "P0", request = module_request(root, graph_path, "p0", "P0") },
    },
    edges = { { from = "p0", to = "p1" } },
    node_count = 2,
    edge_count = 1,
  }
  write_json(graph_path, graph)
  return graph
end

return {
  test_collects_successful_chain_and_raises_dependent_request = function()
    local graph = write_graph()
    local trace = testing.run_fake(dept, {
      queue = "testing-runner.testing_result",
      payload = {
        schema = "testing-runner.result.v1",
        job = "module-test-loop",
        module = "p0",
        status = "passed",
        artifact_root = graph.artifact_root .. "/modules/p0",
        source_ref = { kind = "testing-discovery-relation-graph", ref = graph.relation_graph_path },
        trace_id = "trace-p0-result",
        dedup_key = "dedup-p0-result",
        exit_code = 0,
      },
    })

    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "testing-runner.module_test_request")
    t.eq(trace.raises[1].payload.module, "p1")

    write_json(graph.artifact_root .. "/modules/p0/metadata.json", {
      schema = "testing-runner.native-metadata.v1",
      job = "module-test-loop",
      status = "passed",
      artifact_root = graph.artifact_root .. "/modules/p0",
      source_ref = { kind = "testing-discovery-relation-graph", ref = graph.relation_graph_path },
      trace_id = "trace-p0-result",
      dedup_key = "dedup-p0-result",
    })
    local complete = testing.run_fake(dept, {
      queue = "testing-runner.testing_result",
      payload = {
        schema = "testing-runner.result.v1",
        job = "module-test-loop",
        module = "p1",
        status = "passed",
        artifact_root = graph.artifact_root .. "/modules/p1",
        source_ref = { kind = "testing-discovery-relation-graph", ref = graph.relation_graph_path },
        trace_id = "trace-p1-result",
        dedup_key = "dedup-p1-result",
        exit_code = 0,
      },
    })

    t.eq(#complete.raises, 1)
    t.eq(complete.raises[1].queue, "platform_result")
    t.eq(complete.raises[1].payload.counts.passed, 2)
  end,
}
