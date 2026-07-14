local M = {}

local strings = require("contract.strings")
local testing_contract = require("contract.testing")

local max_string = 512
local max_coverage_rows = 64

local statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  degraded = true,
}

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

local function preserved_module_report(result)
  local native = type(result.native_summary) == "table" and result.native_summary or nil
  local path = native and native.stage_report_path or nil
  if path == nil then return nil end
  if result.artifact_root == nil or path ~= result.artifact_root .. "/stage-report.md" then
    error("platform-test-loop: malformed-aggregate: module report must point under module artifact_root")
  end
  return path
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
  local module_report_path = preserved_module_report(result)
  if result.artifact_root ~= nil then copy.artifact_root = result.artifact_root end
  if module_report_path ~= nil then copy.module_report_path = module_report_path end
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

local function require_completion(condition, message)
  if not condition then
    error("platform-test-loop: malformed-completion: " .. message)
  end
end

local function completion_barrier(value)
  require_completion(type(value) == "table", "completion_barrier must be a table")
  require_completion(value.schema == testing_contract.schemas.platform_completion_barrier, "completion_barrier schema is unknown")
  require_completion(type(value.satisfied) == "boolean", "completion_barrier.satisfied must be boolean")
  return {
    schema = testing_contract.schemas.platform_completion_barrier,
    satisfied = value.satisfied,
  }
end

local function aggregate_modules(aggregate)
  local modules = {}
  for _, result in ipairs(aggregate.modules) do modules[result.module] = true end
  return modules
end

local function coverage_matrix(value, aggregate)
  require_completion(type(value) == "table", "coverage_matrix must be a table")
  require_completion(value.schema == testing_contract.schemas.platform_coverage_matrix, "coverage_matrix schema is unknown")
  require_completion(dense_list(value.rows) and #value.rows <= max_coverage_rows, "coverage_matrix.rows must be a bounded dense list")
  local known_modules = aggregate_modules(aggregate)
  local rows = {}
  for _, row in ipairs(value.rows) do
    require_completion(type(row) == "table", "coverage matrix rows must be tables")
    require_completion(testing_contract.is_bounded_id(row.id), "coverage row id must be bounded")
    require_completion(bounded_string(row.module), "coverage row module must be bounded")
    require_completion(bounded_string(row.claim), "coverage row claim must be bounded")
    require_completion(known_modules[row.module] == true, "coverage row module must exist in the aggregate")
    if row.evidence_pointer ~= nil then
      require_completion(strings.is_artifact_root(row.evidence_pointer), "coverage evidence must be an artifact pointer")
    end
    table.insert(rows, {
      id = row.id,
      module = row.module,
      claim = row.claim,
      evidence_pointer = row.evidence_pointer,
    })
  end
  return {
    schema = testing_contract.schemas.platform_coverage_matrix,
    rows = rows,
  }
end

local function publication_config(value)
  require_completion(type(value) == "table", "publication must be a table")
  require_completion(value.mode == "artifact-only", "publication.mode must be artifact-only")
  require_completion(value.dry_run == true, "publication.dry_run must be true")
  return { mode = "artifact-only", dry_run = true }
end

function M.completion_request(payload)
  local aggregate = M.aggregate_result(payload)
  local barrier = completion_barrier(payload.completion_barrier)
  local matrix = coverage_matrix(payload.coverage_matrix, aggregate)
  local publication = publication_config(payload.publication)
  aggregate.completion_barrier = barrier
  aggregate.coverage_matrix = matrix
  if not barrier.satisfied then return nil end
  require_completion(aggregate.counts.total > 0 and aggregate.counts.planned == 0, "a satisfied barrier requires terminal modules")
  return {
    schema = testing_contract.schemas.final_aggregate_report_request,
    aggregate = aggregate,
    coverage_matrix = matrix,
    publication = publication,
  }
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
