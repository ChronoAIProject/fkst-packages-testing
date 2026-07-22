local M = {}

local strings = require("contract.strings")
local testing_contract = require("contract.testing")
local testing_design = require("contract.testing_design")
local ai_orchestration = require("ai_orchestration")

local statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  degraded = true,
  mixed = true,
}

function M.validate_module_start(payload)
  if type(payload) ~= "table" then
    error("module-testing-pipeline: malformed-request: payload must be a table")
  end
  if payload.schema ~= "module-testing-pipeline.module-start.v1" then
    error("module-testing-pipeline: unknown-schema: expected module-testing-pipeline.module-start.v1")
  end
  if not strings.is_bounded_string(payload.module, 256) then
    error("module-testing-pipeline: malformed-request: module is required")
  end
  if payload.artifact_root ~= nil and not strings.is_artifact_root(payload.artifact_root) then
    error("module-testing-pipeline: malformed-request: artifact_root must be a safe .testing/runs/... path")
  end
  if payload.testing_design_context ~= nil then
    testing_design.validate_context_reference(payload.testing_design_context)
  end
  if (payload.browser_readiness_ref == nil) ~= (payload.browser_readiness_sha256 == nil)
    or (payload.browser_readiness_ref ~= nil and (not strings.is_artifact_root(payload.browser_readiness_ref)
      or type(payload.browser_readiness_sha256) ~= "string" or #payload.browser_readiness_sha256 ~= 64
      or payload.browser_readiness_sha256:match("^[0-9a-f]+$") == nil)) then
    error("module-testing-pipeline: malformed-request: browser readiness pointer and digest are invalid")
  end
  return payload
end

function M.module_loop_request(payload)
  payload = M.validate_module_start(payload)
  local src = testing_contract.copy_source_ref(payload.source_ref, "module-testing-pipeline", payload.module)
  return {
    schema = "module-test-loop.start.v1",
    module = payload.module,
    config = payload.config,
    e2e_driver = payload.e2e_driver,
    no_browser = payload.no_browser,
    dry_run = payload.dry_run,
    dry_run_github = payload.dry_run_github,
    backend = payload.backend,
    native_argv = payload.native_argv,
    ui_loop = payload.ui_loop,
    module_discovery = payload.module_discovery,
    cdp_execution = payload.cdp_execution,
    testing_design_context = payload.testing_design_context ~= nil
      and testing_design.copy_context_reference(payload.testing_design_context) or nil,
    browser_readiness_ref = payload.browser_readiness_ref,
    browser_readiness_sha256 = payload.browser_readiness_sha256,
    preflight_result = payload.preflight_result,
    artifact_root = payload.artifact_root,
    source_ref = src,
    trace_id = testing_contract.trace_id(payload.trace_id, src, payload.artifact_root),
    dedup_key = testing_contract.dedup_key(payload.dedup_key, {
      "module-testing-pipeline",
      "module",
      payload.module,
      src.kind,
      src.ref,
      payload.artifact_root or "artifact",
    }),
  }
end

function M.requires_ai_consensus(payload)
  payload = M.validate_module_start(payload)
  local cdp = payload.cdp_execution
  local generation = type(cdp) == "table" and cdp.ai_generation or nil
  return type(generation) == "table" and generation.mode == "autonomous-reviewed"
end

function M.start_ai_orchestration(payload, io)
  M.validate_module_start(payload)
  return ai_orchestration.start(payload, io)
end

function M.generate_ai_cases(payload, io)
  return ai_orchestration.generate(payload, io)
end

function M.handle_ai_consensus_reached(payload, io)
  return ai_orchestration.handle_consensus_reached(payload, io)
end

function M.handle_ai_consensus_converge(payload, io)
  return ai_orchestration.handle_consensus_converge(payload, io)
end

function M.is_testing_ai_consensus(payload)
  return ai_orchestration.is_testing_ai_consensus(payload)
end

function M.validate_testing_result(result)
  if type(result) ~= "table" then
    error("module-testing-pipeline: malformed-result: result must be a table")
  end
  if result.schema ~= "testing-runner.result.v1" then
    error("module-testing-pipeline: unknown-result-schema: expected testing-runner.result.v1")
  end
  return result
end

function M.validate_artifact_summary(summary)
  if type(summary) ~= "table" then
    error("module-testing-pipeline: malformed-summary: summary must be a table")
  end
  if summary.schema ~= "test-artifacts.summary.v1" then
    error("module-testing-pipeline: unknown-summary-schema: expected test-artifacts.summary.v1")
  end
  if not statuses[summary.status] then
    error("module-testing-pipeline: malformed-summary: unknown status")
  end
  if not strings.is_artifact_root(summary.artifact_root) then
    error("module-testing-pipeline: malformed-summary: artifact_root must be a safe .testing/runs/... path")
  end
  return summary
end

local function add_error(errors, id, message)
  table.insert(errors, { id = id, message = message })
end

local function expect_equal(errors, id, actual, expected)
  if actual == expected then return end
  add_error(errors, id, "pipeline transition expected " .. tostring(expected) .. " but got " .. tostring(actual))
end

function M.saga_conformance_errors()
  local ok, request = pcall(M.module_loop_request, {
    schema = "module-testing-pipeline.module-start.v1",
    module = "conformance-module",
    backend = "fkst-native",
    no_browser = true,
    dry_run = false,
    native_argv = { "conformance-module-check" },
    preflight_result = { status = "ready" },
    artifact_root = ".testing/runs/conformance-module",
    source_ref = { kind = "host-module", ref = "conformance-module" },
    trace_id = "trace-conformance-module",
    dedup_key = "conformance-module-run",
  })
  local errors = {}
  if not ok then
    add_error(errors, "module-testing-pipeline.saga.module-loop-request", tostring(request))
    return errors
  end
  expect_equal(errors, "module-testing-pipeline.saga.schema", request.schema, "module-test-loop.start.v1")
  expect_equal(errors, "module-testing-pipeline.saga.module", request.module, "conformance-module")
  expect_equal(errors, "module-testing-pipeline.saga.backend", request.backend, "fkst-native")
  expect_equal(errors, "module-testing-pipeline.saga.no-browser", request.no_browser, true)
  expect_equal(errors, "module-testing-pipeline.saga.dry-run", request.dry_run, false)
  expect_equal(errors, "module-testing-pipeline.saga.native-argv", request.native_argv and request.native_argv[1], "conformance-module-check")
  expect_equal(errors, "module-testing-pipeline.saga.artifact-root", request.artifact_root, ".testing/runs/conformance-module")
  expect_equal(errors, "module-testing-pipeline.saga.source-kind", request.source_ref and request.source_ref.kind, "host-module")
  expect_equal(errors, "module-testing-pipeline.saga.source-ref", request.source_ref and request.source_ref.ref, "conformance-module")
  expect_equal(errors, "module-testing-pipeline.saga.trace-id", request.trace_id, "trace-conformance-module")
  expect_equal(errors, "module-testing-pipeline.saga.dedup-key", request.dedup_key, "conformance-module-run")
  return errors
end

return M
