local M = {}

local strings = require("contract.strings")
local testing_contract = require("contract.testing")
local testing_json = require("testing_runtime.json")

local max_string = 512

local statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  degraded = true,
}

local terminal_statuses = {
  passed = true,
  failed = true,
  blocked = true,
  degraded = true,
}

local priorities = {
  P0 = 1,
  P1 = 2,
  P2 = 3,
}

M.relation_graph_schema = "testing-discovery.relation-graph.v2"
M.schedule_schema = "platform-test-loop.schedule.v1"

local function dense_list(value)
  if type(value) ~= "table" then
    return false
  end
  local n = #value
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 or key > n then
      return false
    end
  end
  return true
end

local function bounded_string(value, limit)
  return type(value) == "string" and value ~= "" and #value <= (limit or max_string)
end

local function validate_artifact_root(value, message)
  if value ~= nil and not strings.is_artifact_root(value) then
    error(message or "platform-test-loop: malformed-request: artifact_root must be a safe .testing/runs/... path")
  end
end

local function validate_ids(payload)
  if payload.trace_id ~= nil and not testing_contract.is_bounded_id(payload.trace_id) then
    error("platform-test-loop: malformed-request: trace_id must be a bounded string")
  end
  if payload.dedup_key ~= nil and not testing_contract.is_bounded_id(payload.dedup_key) then
    error("platform-test-loop: malformed-request: dedup_key must be a bounded string")
  end
end

local function module_name(result, index)
  if bounded_string(result.module, max_string) then
    return result.module
  end
  if type(result.native_summary) == "table" and bounded_string(result.native_summary.module, max_string) then
    return result.native_summary.module
  end
  if type(result.source_ref) == "table" and bounded_string(result.source_ref.ref, max_string) then
    return result.source_ref.ref
  end
  return "module-" .. tostring(index)
end

local function copy_module_result(result, index)
  if type(result) ~= "table" then
    error("platform-test-loop: malformed-aggregate: module result must be a table")
  end
  if result.schema ~= nil and result.schema ~= testing_contract.schemas.runner_result then
    error("platform-test-loop: unknown-result-schema: expected testing-runner.result.v1")
  end
  if not statuses[result.status] then
    error("platform-test-loop: malformed-aggregate: module result status is required")
  end
  validate_artifact_root(result.artifact_root, "platform-test-loop: malformed-aggregate: module artifact_root must be a safe .testing/runs/... path")
  if result.dedup_key ~= nil and not testing_contract.is_bounded_id(result.dedup_key) then
    error("platform-test-loop: malformed-aggregate: module dedup_key must be a bounded string")
  end

  local module = module_name(result, index)
  local src = testing_contract.copy_source_ref(result.source_ref, "module", module)
  local copy = {
    module = module,
    status = result.status,
    source_ref = src,
  }
  if result.artifact_root ~= nil then copy.artifact_root = result.artifact_root end
  if result.dedup_key ~= nil then copy.dedup_key = result.dedup_key end
  if type(result.exit_code) == "number" then copy.exit_code = result.exit_code end
  return copy
end

local function planned_module_result(module, index)
  if not bounded_string(module, max_string) then
    error("platform-test-loop: malformed-aggregate: modules must contain bounded strings")
  end
  return {
    module = module,
    status = "planned",
    source_ref = { kind = "module", ref = module },
  }
end

local function count_statuses(results)
  local counts = {
    total = #results,
    planned = 0,
    passed = 0,
    failed = 0,
    blocked = 0,
    degraded = 0,
  }
  for _, result in ipairs(results) do
    counts[result.status] = counts[result.status] + 1
  end
  return counts
end

local function number_or_zero(value)
  return type(value) == "number" and value or 0
end

local function native_summary(result)
  return type(result) == "table" and type(result.native_summary) == "table" and result.native_summary or nil
end

local function outcome_classification(result)
  local summary = native_summary(result)
  return summary and summary.outcome_classification or nil
end

local function flow_summary(results)
  local summary = {
    schema = "platform-test-loop.flow-summary.v1",
    planned = 0,
    executed = 0,
    skipped = 0,
    blocked_by_safety_gate = 0,
    blocked_by_fixture_gap = 0,
    blocked_by_environment_readiness = 0,
  }
  local saw_flow_signal = false
  for _, result in ipairs(results) do
    local native = native_summary(result)
    local flow = native and native.platform_flow_summary or nil
    if type(flow) == "table" then
      saw_flow_signal = true
      summary.planned = summary.planned + number_or_zero(flow.planned or flow.flows_planned)
      summary.executed = summary.executed + number_or_zero(flow.executed or flow.flows_executed)
      summary.skipped = summary.skipped + number_or_zero(flow.skipped or flow.flows_skipped)
      summary.blocked_by_safety_gate = summary.blocked_by_safety_gate + number_or_zero(flow.blocked_by_safety_gate or flow.safety_blocked)
      summary.blocked_by_fixture_gap = summary.blocked_by_fixture_gap + number_or_zero(flow.blocked_by_fixture_gap or flow.fixture_gap_blocked)
      summary.blocked_by_environment_readiness = summary.blocked_by_environment_readiness + number_or_zero(flow.blocked_by_environment_readiness or flow.environment_readiness_blocked)
    else
      local classification = outcome_classification(result)
      if result.status == "passed" or result.status == "degraded" then summary.executed = summary.executed + 1 end
      if result.status == "blocked" or result.status == "degraded" or classification ~= nil then summary.skipped = summary.skipped + 1 end
      if classification == "data-fixture-gap" then summary.blocked_by_fixture_gap = summary.blocked_by_fixture_gap + 1 end
      if classification == "environment-session-issue" or classification == "environment-readiness-gap" then summary.blocked_by_environment_readiness = summary.blocked_by_environment_readiness + 1 end
      if classification == "ai-generation-gap" or classification == "unsafe-generated-case" or classification == "not-executed-risk" or classification == "multi-module-flow-gap" then
        summary.blocked_by_safety_gate = summary.blocked_by_safety_gate + 1
      end
    end
  end
  summary.planned = math.max(summary.planned, summary.executed + summary.skipped)
  if saw_flow_signal or summary.planned > 0 or summary.skipped > 0 then return summary end
  return nil
end

local function aggregate_status(counts)
  if counts.total == 0 or counts.planned == counts.total then return "planned" end
  if counts.passed == counts.total then return "passed" end
  if counts.failed == counts.total then return "failed" end
  if counts.blocked == counts.total then return "blocked" end
  if counts.degraded == counts.total then return "degraded" end
  return "mixed"
end

local function aggregate_artifact_root(payload, src)
  if payload.artifact_root ~= nil then
    return payload.artifact_root
  end
  return ".testing/runs/" .. testing_contract.safe_key(payload.platform or payload.dedup_key or src.ref or "platform", "platform")
end

function M.validate_request(payload)
  if type(payload) ~= "table" then
    error("platform-test-loop: malformed-request: payload must be a table")
  end
  if payload.schema ~= "platform-test-loop.start.v1" then
    error("platform-test-loop: unknown-schema: expected platform-test-loop.start.v1")
  end
  if payload.modules ~= nil and not dense_list(payload.modules) then
    error("platform-test-loop: malformed-request: modules must be a dense list")
  end
  if payload.priority ~= nil and not dense_list(payload.priority) then
    error("platform-test-loop: malformed-request: priority must be a dense list")
  end
  validate_artifact_root(payload.artifact_root)
  validate_ids(payload)
  return payload
end

function M.runner_request(payload)
  payload = M.validate_request(payload)
  return {
    schema = "testing-runner.platform-test-loop.request.v1",
    modules = payload.modules,
    priority = payload.priority,
    config = payload.config,
    e2e_driver = payload.e2e_driver,
    no_browser = payload.no_browser,
    dry_run = payload.dry_run,
    dry_run_github = payload.dry_run_github,
    backend = payload.backend,
    preflight_result = payload.preflight_result,
    artifact_root = payload.artifact_root,
    source_ref = payload.source_ref,
    trace_id = payload.trace_id,
    dedup_key = payload.dedup_key,
  }
end

function M.validate_aggregate_request(payload)
  if type(payload) ~= "table" then
    error("platform-test-loop: malformed-aggregate: payload must be a table")
  end
  if payload.schema ~= "platform-test-loop.aggregate.v1" then
    error("platform-test-loop: unknown-aggregate-schema: expected platform-test-loop.aggregate.v1")
  end
  if payload.module_results ~= nil and not dense_list(payload.module_results) then
    error("platform-test-loop: malformed-aggregate: module_results must be a dense list")
  end
  if payload.modules ~= nil and not dense_list(payload.modules) then
    error("platform-test-loop: malformed-aggregate: modules must be a dense list")
  end
  validate_artifact_root(payload.artifact_root)
  validate_ids(payload)
  return payload
end

function M.aggregate_result(payload)
  payload = M.validate_aggregate_request(payload)
  local src = testing_contract.copy_source_ref(payload.source_ref, "platform", payload.platform or "platform")
  local artifact_root = aggregate_artifact_root(payload, src)
  validate_artifact_root(artifact_root)

  local modules = {}
  if payload.module_results ~= nil then
    for index, result in ipairs(payload.module_results) do
      table.insert(modules, copy_module_result(result, index))
    end
  elseif payload.modules ~= nil then
    for index, module in ipairs(payload.modules) do
      table.insert(modules, planned_module_result(module, index))
    end
  end

  local counts = count_statuses(modules)
  local flows = flow_summary(payload.module_results or {})
  return {
    schema = "platform-test-loop.aggregate.v1",
    status = aggregate_status(counts),
    counts = counts,
    modules = modules,
    flow_summary = flows,
    platform_flows = flows,
    artifact_root = artifact_root,
    metadata_path = artifact_root .. "/metadata.json",
    result_path = payload.result_path or (artifact_root .. "/aggregate.json"),
    source_ref = src,
    trace_id = testing_contract.trace_id(payload.trace_id, src, artifact_root),
    dedup_key = testing_contract.dedup_key(payload.dedup_key, {
      "platform-test-loop",
      "aggregate",
      src.kind,
      src.ref,
      artifact_root,
    }),
  }
end

local function read_body(path, reader, optional)
  if reader ~= nil then return reader(path) end
  if not optional then return file.read(path) end
  local ok, body = pcall(file.read, path)
  return ok and body or nil
end

local function decode_json(body, context)
  if type(body) ~= "string" or body == "" then
    error(context .. ": artifact body is empty")
  end
  local ok, value = pcall(json.decode, body)
  if not ok then error(context .. ": invalid json") end
  return value
end

local function encode_json(value)
  return testing_json.encode(value)
end

local function validate_graph_path(path)
  if not strings.is_artifact_root(path) or path:sub(-20) ~= "/relation-graph.json" then
    error("platform-test-loop: malformed-relation-graph: relation_graph_path must be a safe relation-graph artifact")
  end
end

local function has_only(value, allowed, context)
  for key, _ in pairs(value or {}) do
    if allowed[key] ~= true then error(context .. ": unsupported field " .. tostring(key)) end
  end
end

local graph_fields = {
  aggregate_artifact_root = true,
  aggregate_result_path = true,
  artifact_kind = true,
  artifact_root = true,
  dedup_key = true,
  edge_count = true,
  edges = true,
  node_count = true,
  nodes = true,
  relation_graph_path = true,
  run_id = true,
  schema = true,
  source_ref = true,
  trace_id = true,
}

local node_fields = { id = true, priority = true, request = true, source_ref = true }
local edge_fields = { from = true, to = true }
local request_fields = {
  artifact_root = true,
  backend = true,
  cdp_execution = true,
  dedup_key = true,
  dry_run = true,
  module = true,
  module_discovery = true,
  preflight_result = true,
  schema = true,
  source_ref = true,
  trace_id = true,
  ui_loop = true,
}

local function validate_graph_node(node, graph, ids)
  if type(node) ~= "table" or not bounded_string(node.id, 180) then
    error("platform-test-loop: malformed-relation-graph: node id is required")
  end
  has_only(node, node_fields, "platform-test-loop: malformed-relation-graph: node")
  if ids[node.id] == true then error("platform-test-loop: malformed-relation-graph: duplicate node id") end
  if priorities[node.priority] == nil then error("platform-test-loop: malformed-relation-graph: node priority is invalid") end
  if type(node.request) ~= "table" or node.request.schema ~= "testing-runner.module-test-loop.request.v1" then
    error("platform-test-loop: malformed-relation-graph: node runner request is invalid")
  end
  has_only(node.request, request_fields, "platform-test-loop: malformed-relation-graph: node request")
  if node.request.module ~= node.id then error("platform-test-loop: malformed-relation-graph: node request module mismatch") end
  if node.request.backend ~= "fkst-native" or node.request.dry_run ~= false then
    error("platform-test-loop: malformed-relation-graph: node request must use the executable native boundary")
  end
  local expected_artifact_root = graph.artifact_root .. "/modules/" .. strings.runtime_safe_segment(node.id)
  if node.request.artifact_root ~= expected_artifact_root then
    error("platform-test-loop: malformed-relation-graph: node artifact_root is invalid")
  end
  if type(node.request.preflight_result) ~= "table" or not bounded_string(node.request.preflight_result.status, 80) then
    error("platform-test-loop: malformed-relation-graph: node preflight result is invalid")
  end
  if type(node.request.ui_loop) ~= "table"
    or node.request.ui_loop.platform_flow_ref ~= graph.relation_graph_path
    or type(node.request.ui_loop.priority) ~= "table"
    or node.request.ui_loop.priority[1] ~= node.priority
    or #node.request.ui_loop.priority ~= 1 then
    error("platform-test-loop: malformed-relation-graph: node scheduling controls are invalid")
  end
  if type(node.request.module_discovery) ~= "table" or node.request.module_discovery.schema ~= "testing-runner.module-discovery.v1" then
    error("platform-test-loop: malformed-relation-graph: node discovery request is invalid")
  end
  if type(node.request.cdp_execution) ~= "table" or node.request.cdp_execution.schema ~= "testing-runner.module-cdp-execution.v1" then
    error("platform-test-loop: malformed-relation-graph: node execution request is invalid")
  end
  if not testing_contract.is_bounded_id(node.request.trace_id) or not testing_contract.is_bounded_id(node.request.dedup_key) then
    error("platform-test-loop: malformed-relation-graph: node identity is invalid")
  end
  local src = node.request.source_ref
  if type(src) ~= "table" or src.kind ~= "testing-discovery-relation-graph" or src.ref ~= graph.relation_graph_path then
    error("platform-test-loop: malformed-relation-graph: node request source_ref must point to the graph")
  end
  ids[node.id] = true
end

function M.validate_relation_graph(graph)
  if type(graph) ~= "table" or graph.schema ~= M.relation_graph_schema then
    error("platform-test-loop: unknown-relation-graph-schema: expected " .. M.relation_graph_schema)
  end
  has_only(graph, graph_fields, "platform-test-loop: malformed-relation-graph: graph")
  validate_graph_path(graph.relation_graph_path)
  validate_artifact_root(graph.artifact_root, "platform-test-loop: malformed-relation-graph: artifact_root is invalid")
  if graph.relation_graph_path ~= graph.artifact_root .. "/relation-graph.json" then
    error("platform-test-loop: malformed-relation-graph: relation graph is outside its artifact root")
  end
  if graph.aggregate_artifact_root ~= graph.artifact_root .. "/platform" then
    error("platform-test-loop: malformed-relation-graph: aggregate_artifact_root is invalid")
  end
  if graph.aggregate_result_path ~= graph.aggregate_artifact_root .. "/aggregate.json" then
    error("platform-test-loop: malformed-relation-graph: aggregate_result_path is invalid")
  end
  if not testing_contract.is_bounded_id(graph.run_id) or not testing_contract.is_bounded_id(graph.trace_id) or not testing_contract.is_bounded_id(graph.dedup_key) then
    error("platform-test-loop: malformed-relation-graph: run identity is invalid")
  end
  if not dense_list(graph.nodes) or #graph.nodes == 0 or #graph.nodes > 64 then
    error("platform-test-loop: malformed-relation-graph: nodes must be a non-empty bounded dense list")
  end
  if not dense_list(graph.edges) or #graph.edges > 64 then
    error("platform-test-loop: malformed-relation-graph: edges must be a bounded dense list")
  end
  if graph.node_count ~= #graph.nodes or graph.edge_count ~= #graph.edges then
    error("platform-test-loop: malformed-relation-graph: graph counts do not match")
  end
  local ids = {}
  for _, node in ipairs(graph.nodes) do validate_graph_node(node, graph, ids) end
  local edge_ids = {}
  for _, edge in ipairs(graph.edges) do
    if type(edge) ~= "table" or not bounded_string(edge.from, 180) or not bounded_string(edge.to, 180) then
      error("platform-test-loop: malformed-relation-graph: dependency edge is invalid")
    end
    has_only(edge, edge_fields, "platform-test-loop: malformed-relation-graph: edge")
    if edge.from == edge.to or ids[edge.from] ~= true or ids[edge.to] ~= true then
      error("platform-test-loop: malformed-relation-graph: dependency edge must reference distinct graph nodes")
    end
    local edge_id = edge.from .. "\0" .. edge.to
    if edge_ids[edge_id] == true then error("platform-test-loop: malformed-relation-graph: duplicate dependency edge") end
    edge_ids[edge_id] = true
  end
  return graph
end

function M.read_relation_graph(path, reader)
  validate_graph_path(path)
  local graph = decode_json(read_body(path, reader, false), "platform-test-loop: malformed-relation-graph")
  if graph.relation_graph_path ~= path then
    error("platform-test-loop: malformed-relation-graph: artifact path mismatch")
  end
  return M.validate_relation_graph(graph)
end

function M.validate_schedule_request(payload)
  if type(payload) ~= "table" or payload.schema ~= M.schedule_schema then
    error("platform-test-loop: unknown-schedule-schema: expected " .. M.schedule_schema)
  end
  validate_graph_path(payload.relation_graph_path)
  validate_artifact_root(payload.artifact_root)
  validate_ids(payload)
  has_only(payload, {
    artifact_root = true,
    dedup_key = true,
    relation_graph_path = true,
    schema = true,
    source_ref = true,
    trace_id = true,
  }, "platform-test-loop: malformed-request: schedule")
  local src = payload.source_ref
  if type(src) ~= "table" or src.kind ~= "testing-discovery-relation-graph" or src.ref ~= payload.relation_graph_path then
    error("platform-test-loop: malformed-request: schedule source_ref must point to the graph")
  end
  return payload
end

local function result_module(result)
  if bounded_string(result.module, 180) then return result.module end
  local summary = type(result.native_summary) == "table" and result.native_summary or nil
  if summary ~= nil and bounded_string(summary.module, 180) then return summary.module end
  return nil
end

local function validate_terminal_result(graph, result)
  if type(result) ~= "table" or result.schema ~= testing_contract.schemas.runner_result then
    error("platform-test-loop: malformed-terminal-result: expected testing-runner.result.v1")
  end
  if result.job ~= "module-test-loop" or terminal_statuses[result.status] ~= true then
    error("platform-test-loop: malformed-terminal-result: module terminal status is required")
  end
  local src = result.source_ref
  if type(src) ~= "table" or src.kind ~= "testing-discovery-relation-graph" or src.ref ~= graph.relation_graph_path then
    error("platform-test-loop: malformed-terminal-result: source_ref does not identify the graph")
  end
  local module = result_module(result)
  if module == nil then error("platform-test-loop: malformed-terminal-result: module identity is required") end
  return module
end

local function indexed_results(graph, results)
  local nodes, by_module = {}, {}
  for _, node in ipairs(graph.nodes) do nodes[node.id] = node end
  for _, result in ipairs(results or {}) do
    local module = validate_terminal_result(graph, result)
    local node = nodes[module]
    if node == nil then error("platform-test-loop: malformed-terminal-result: module is not in the graph") end
    if result.artifact_root ~= node.request.artifact_root then
      error("platform-test-loop: malformed-terminal-result: artifact_root does not match the graph node")
    end
    if by_module[module] ~= nil then error("platform-test-loop: malformed-terminal-result: duplicate module result") end
    by_module[module] = result
  end
  return by_module
end

local function predecessor_map(graph)
  local predecessors = {}
  for _, node in ipairs(graph.nodes) do predecessors[node.id] = {} end
  for _, edge in ipairs(graph.edges) do predecessors[edge.to][edge.from] = true end
  return predecessors
end

local function ready_nodes(graph, by_module)
  local predecessors, ready = predecessor_map(graph), {}
  for _, node in ipairs(graph.nodes) do
    if by_module[node.id] == nil then
      local dependencies_passed = true
      for dependency, _ in pairs(predecessors[node.id]) do
        if by_module[dependency] == nil or by_module[dependency].status ~= "passed" then
          dependencies_passed = false
        end
      end
      if dependencies_passed then table.insert(ready, node) end
    end
  end
  table.sort(ready, function(left, right)
    local left_priority, right_priority = priorities[left.priority], priorities[right.priority]
    if left_priority ~= right_priority then return left_priority < right_priority end
    return left.id < right.id
  end)
  return ready
end

function M.coordinate(graph, results)
  graph = M.validate_relation_graph(graph)
  if results ~= nil and not dense_list(results) then
    error("platform-test-loop: malformed-terminal-result: results must be a dense list")
  end
  local by_module = indexed_results(graph, results or {})
  local complete = true
  for _, node in ipairs(graph.nodes) do
    if by_module[node.id] == nil then complete = false end
  end
  if complete then
    local ordered = {}
    for _, node in ipairs(graph.nodes) do table.insert(ordered, by_module[node.id]) end
    return {
      wave = {},
      aggregate = M.aggregate_result({
        schema = "platform-test-loop.aggregate.v1",
        module_results = ordered,
        artifact_root = graph.aggregate_artifact_root,
        result_path = graph.aggregate_result_path,
        source_ref = { kind = "testing-discovery-relation-graph", ref = graph.relation_graph_path },
        trace_id = graph.trace_id,
        dedup_key = testing_contract.safe_key(graph.dedup_key .. "-aggregate", "platform-aggregate"),
      }),
    }
  end
  local wave = {}
  for _, node in ipairs(ready_nodes(graph, by_module)) do table.insert(wave, node.request) end
  return { wave = wave, aggregate = nil }
end

function M.consume_terminal_result(graph, results, result)
  graph = M.validate_relation_graph(graph)
  local collected = {}
  for _, item in ipairs(results or {}) do table.insert(collected, item) end
  local module = validate_terminal_result(graph, result)
  for _, item in ipairs(collected) do
    if result_module(item) == module then error("platform-test-loop: malformed-terminal-result: duplicate module result") end
  end
  table.insert(collected, result)
  return M.coordinate(graph, collected), collected
end

local function result_from_metadata(graph, node, metadata)
  if type(metadata) ~= "table" or metadata.schema ~= "testing-runner.native-metadata.v1" then
    error("platform-test-loop: malformed-terminal-result: runner metadata schema is invalid")
  end
  return {
    schema = testing_contract.schemas.runner_result,
    job = metadata.job,
    module = node.id,
    status = metadata.status,
    artifact_root = metadata.artifact_root,
    source_ref = metadata.source_ref,
    trace_id = metadata.trace_id,
    dedup_key = metadata.dedup_key,
    adapter = metadata.adapter,
    native_summary = metadata.native_summary,
  }
end

function M.results_from_artifacts(graph, current_result, reader)
  graph = M.validate_relation_graph(graph)
  local current_module = validate_terminal_result(graph, current_result)
  local results = {}
  for _, node in ipairs(graph.nodes) do
    if node.id == current_module then
      table.insert(results, current_result)
    else
      local path = node.request.artifact_root .. "/metadata.json"
      local body = read_body(path, reader, true)
      if body ~= nil and body ~= "" then
        local metadata = decode_json(body, "platform-test-loop: malformed-terminal-result")
        if terminal_statuses[metadata.status] == true then table.insert(results, result_from_metadata(graph, node, metadata)) end
      end
    end
  end
  indexed_results(graph, results)
  return results
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function write_file(path, body)
  local dir = path:match("^(.*)/[^/]+$")
  if not strings.is_artifact_root(dir) then return nil, "unsafe aggregate directory" end
  local ok = os.execute("mkdir -p " .. shell_quote(dir))
  if ok ~= true and ok ~= 0 then return nil, "failed to create aggregate directory" end
  local handle, err = io.open(path, "w")
  if handle == nil then return nil, err or "failed to open aggregate result" end
  local wrote, write_err = handle:write(body)
  handle:close()
  if not wrote then return nil, write_err or "failed to write aggregate result" end
  return true
end

function M.write_aggregate_result(aggregate, writer)
  if type(aggregate) ~= "table" or aggregate.schema ~= "platform-test-loop.aggregate.v1" then
    error("platform-test-loop: malformed-aggregate: invalid aggregate result")
  end
  if aggregate.result_path ~= aggregate.artifact_root .. "/aggregate.json" then
    error("platform-test-loop: malformed-aggregate: result_path must be a safe artifact path")
  end
  local write = writer or write_file
  return write(aggregate.result_path, encode_json(aggregate) .. "\n")
end

local function add_error(errors, id, message)
  table.insert(errors, { id = id, message = message })
end

local function expect_equal(errors, id, actual, expected)
  if actual ~= expected then
    add_error(errors, id, "expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function conformance_module_result(module)
  return {
    schema = testing_contract.schemas.runner_result,
    job = "module-test-loop",
    module = module,
    status = "passed",
    artifact_root = ".testing/runs/" .. module,
    source_ref = { kind = "module", ref = module },
    dedup_key = module .. "-run",
    exit_code = 0,
  }
end

function M.saga_conformance_errors()
  local errors = {}
  local ok_request, request = pcall(M.runner_request, {
    schema = "platform-test-loop.start.v1",
    modules = { "conformance-a", "conformance-b" },
    priority = { "P0" },
    backend = "fkst-native",
    artifact_root = ".testing/runs/conformance-platform",
    source_ref = { kind = "platform", ref = "conformance-platform" },
    trace_id = "trace-conformance-platform",
    dedup_key = "conformance-platform-run",
  })
  if not ok_request then
    add_error(errors, "platform-test-loop.saga.runner-request", tostring(request))
  else
    expect_equal(errors, "platform-test-loop.saga.runner-schema", request.schema, "testing-runner.platform-test-loop.request.v1")
    expect_equal(errors, "platform-test-loop.saga.runner-module", request.modules and request.modules[2], "conformance-b")
    expect_equal(errors, "platform-test-loop.saga.runner-backend", request.backend, "fkst-native")
    expect_equal(errors, "platform-test-loop.saga.runner-trace", request.trace_id, "trace-conformance-platform")
    expect_equal(errors, "platform-test-loop.saga.runner-dedup", request.dedup_key, "conformance-platform-run")
  end

  local ok_aggregate, aggregate = pcall(M.aggregate_result, {
    schema = "platform-test-loop.aggregate.v1",
    module_results = {
      conformance_module_result("conformance-a"),
      conformance_module_result("conformance-b"),
    },
    artifact_root = ".testing/runs/conformance-platform",
    source_ref = { kind = "platform", ref = "conformance-platform" },
    trace_id = "trace-conformance-platform",
    dedup_key = "conformance-platform-run",
  })
  if not ok_aggregate then
    add_error(errors, "platform-test-loop.saga.aggregate", tostring(aggregate))
    return errors
  end
  expect_equal(errors, "platform-test-loop.saga.aggregate-schema", aggregate.schema, "platform-test-loop.aggregate.v1")
  expect_equal(errors, "platform-test-loop.saga.aggregate-status", aggregate.status, "passed")
  expect_equal(errors, "platform-test-loop.saga.aggregate-total", aggregate.counts and aggregate.counts.total, 2)
  expect_equal(errors, "platform-test-loop.saga.aggregate-passed", aggregate.counts and aggregate.counts.passed, 2)
  expect_equal(errors, "platform-test-loop.saga.aggregate-artifact", aggregate.artifact_root, ".testing/runs/conformance-platform")
  expect_equal(errors, "platform-test-loop.saga.aggregate-metadata", aggregate.metadata_path, ".testing/runs/conformance-platform/metadata.json")
  expect_equal(errors, "platform-test-loop.saga.aggregate-trace", aggregate.trace_id, "trace-conformance-platform")
  expect_equal(errors, "platform-test-loop.saga.aggregate-dedup", aggregate.dedup_key, "conformance-platform-run")
  expect_equal(errors, "platform-test-loop.saga.aggregate-module", aggregate.modules and aggregate.modules[1] and aggregate.modules[1].module, "conformance-a")
  expect_equal(errors, "platform-test-loop.saga.aggregate-module-dedup", aggregate.modules and aggregate.modules[2] and aggregate.modules[2].dedup_key, "conformance-b-run")
  return errors
end

return M
