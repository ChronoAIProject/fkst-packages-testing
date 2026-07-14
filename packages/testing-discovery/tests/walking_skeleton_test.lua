local core = require("core")
local graph = require("testkit.graph")
local strings = require("contract.strings")
local json_codec = require("testing_runtime.json")
local t = fkst.test

local runtime_key = strings.decimal_checksum(os.getenv("FKST_RUNTIME_ROOT") or "local-test-runtime")
local run_root = ".testing/runs/walking-skeleton-acceptance-" .. runtime_key
local aggregate_path = run_root .. "/platform/aggregate.json"
local origin = "http://localhost:8080"
local base_url = origin .. "/app"
local cdp_url = "http://127.0.0.1:9222"
local digest = string.rep("a", 64)

local function file_exists(path)
  local handle = io.open(path, "r")
  if handle == nil then return false end
  handle:close()
  return true
end

local function scope()
  return {
    schema = core.scope_schema,
    base_url = base_url,
    allowed_origins = { origin },
    sessions = {
      { role = "base", browser_harness_command = "true" },
      { role = "cdp", cdp_url = cdp_url },
    },
    observations = {
      {
        id = "p1",
        name = "Dependent module",
        route = "/app/p1",
        visible_label = "P1",
        discovery_source = "navigation",
        evidence_pointer = run_root .. "/evidence/p1",
        priority = "P1",
        depends_on = { "p0" },
      },
      {
        id = "p0",
        name = "Prerequisite module",
        route = "/app/p0",
        visible_label = "P0",
        discovery_source = "navigation",
        evidence_pointer = run_root .. "/evidence/p0",
        priority = "P0",
      },
    },
    artifact_root = run_root,
    source_ref = { kind = "host-app", ref = "walking-skeleton" },
    trace_id = "trace-walking-skeleton",
    dedup_key = "walking-skeleton-run",
  }
end

local function readiness_event()
  return {
    queue = "browser-readiness.browser_readiness_result",
    source_ref = { kind = "external", reference = "walking-skeleton-readiness" },
    payload = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready" },
        { role = "cdp", status = "ready", cdp_url = cdp_url },
      },
      source_ref = { kind = "testing-discovery-plan", ref = run_root },
    },
  }
end

local function write_receipt(module)
  local root = run_root .. "/modules/" .. module
  local cases = {
    { id = module .. ":reachability", action = "navigate", assertions = { "url-within-scope", "document-ready" } },
    { id = module .. ":page-load", action = "wait-for-load", assertions = { "document-ready", "url-within-scope" } },
    { id = module .. ":visible-elements", action = "inspect-visible-elements", assertions = { "visible-target-present", "url-within-scope" } },
    { id = module .. ":console-network-health", action = "collect-console-network-health", assertions = { "no-severe-console", "no-failed-document-request", "url-within-scope" } },
    { id = module .. ":navigation", action = "bounded-navigation", assertions = { "url-within-scope", "document-ready" } },
  }
  local actions = {}
  for step, case in ipairs(cases) do
    local pointer = root .. "/evidence/execution/" .. case.id:gsub(":", "-") .. ".json"
    local assertion_results = {}
    for _, assertion in ipairs(case.assertions) do
      table.insert(assertion_results, {
        type = assertion,
        status = "passed",
        observation = assertion .. " passed",
        evidence_pointer = pointer,
      })
    end
    table.insert(actions, {
      step = step,
      case_id = case.id,
      action = case.action,
      execution_status = "executed",
      assertion_status = "passed",
      observation = "typed browser action and assertions completed",
      evidence_pointer = pointer,
      assertion_results = assertion_results,
    })
  end
  local receipt = {
    schema = "testing-runtime.execution-receipt.v1",
    module = module,
    request_sha256 = digest,
    status = "passed",
    classification = "typed-browser-assertions-passed",
    action_count = #actions,
    executed_action_count = #actions,
    failed_action_count = 0,
    blocked_action_count = 0,
    actions = actions,
  }
  os.execute("mkdir -p " .. root)
  local handle = assert(io.open(root .. "/browser-execution-receipt.json", "w"))
  handle:write(json_codec.encode(receipt) .. "\n")
  handle:close()
end

local function result_module(payload)
  if type(payload) ~= "table" then return nil end
  if payload.module ~= nil then return payload.module end
  return type(payload.native_summary) == "table" and payload.native_summary.module or nil
end

local function count_raises(trace, queue)
  local count = 0
  for _, step in ipairs(trace.steps or {}) do
    for _, raised in ipairs(step.raises or {}) do
      if raised.queue == queue then count = count + 1 end
    end
  end
  return count
end

return {
  test_p0_to_p1_chain_reaches_one_persisted_aggregate = function()
    core.write_plan(core.plan(scope()))
    write_receipt("p0")
    write_receipt("p1")
    for _ = 1, 2 do
      t.mock_command("hash-json", { exit_code = 0, stdout = digest .. "\n", stderr = "" })
      t.mock_command("execute", { exit_code = 0, stdout = "", stderr = "" })
    end
    t.eq(file_exists(aggregate_path), false)

    local trace = graph.require_quiescent(graph.run(readiness_event(), { max_steps = 24 }))
    local p0_request, _, p0_request_step = graph.require_raise(trace, "testing-runner.module_test_request", function(raised)
      return raised.payload.module == "p0"
    end)
    local p1_request, _, p1_request_step = graph.require_raise(trace, "testing-runner.module_test_request", function(raised)
      return raised.payload.module == "p1"
    end)
    local p0_result, _, p0_result_step = graph.require_raise(trace, "testing-runner.testing_result", function(raised)
      return result_module(raised.payload) == "p0"
    end)
    local p1_result, _, p1_result_step = graph.require_raise(trace, "testing-runner.testing_result", function(raised)
      return result_module(raised.payload) == "p1"
    end)
    local aggregate, _, aggregate_step = graph.require_raise(trace, "platform-test-loop.platform_result")

    t.eq(p0_request.payload.ui_loop.priority[1], "P0")
    t.eq(p1_request.payload.ui_loop.priority[1], "P1")
    t.is_true(p0_request_step < p0_result_step)
    t.is_true(p0_result_step < p1_request_step)
    t.is_true(p1_request_step < p1_result_step)
    t.is_true(p1_result_step < aggregate_step)
    t.eq(p0_result.payload.status, "passed")
    t.eq(p1_result.payload.status, "passed")
    t.eq(count_raises(trace, "platform-test-loop.platform_result"), 1)
    t.eq(aggregate.payload.counts.total, 2)
    t.eq(aggregate.payload.counts.passed, 2)
    t.eq(file_exists(aggregate_path), true)

    local graph_file = assert(io.open(run_root .. "/relation-graph.json", "r"))
    local persisted_graph = json.decode(graph_file:read("*a"))
    graph_file:close()
    t.eq(persisted_graph.nodes[1].id, "p1")
    t.eq(persisted_graph.edges[1].from, "p0")
    t.eq(persisted_graph.edges[1].to, "p1")

    local aggregate_file = assert(io.open(aggregate_path, "r"))
    local persisted_aggregate = json.decode(aggregate_file:read("*a"))
    aggregate_file:close()
    t.eq(#persisted_aggregate.modules, 2)
    t.eq(persisted_aggregate.modules[1].module, "p1")
    t.eq(persisted_aggregate.modules[2].module, "p0")
  end,
}
