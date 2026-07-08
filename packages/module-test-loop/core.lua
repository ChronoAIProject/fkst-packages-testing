local M = {}

local strings = require("contract.strings")

function M.validate_request(payload)
  if type(payload) ~= "table" then
    error("module-test-loop: malformed-request: payload must be a table")
  end
  if payload.schema ~= "module-test-loop.start.v1" then
    error("module-test-loop: unknown-schema: expected module-test-loop.start.v1")
  end
  if not strings.is_bounded_string(payload.module, 256) then
    error("module-test-loop: malformed-request: module is required")
  end
  return payload
end

local function preflight_context(payload)
  if type(payload.preflight_result) ~= "table" then return nil end
  if type(payload.preflight_result.request_context) ~= "table" then return nil end
  return payload.preflight_result.request_context
end

local function fallback(payload, key)
  if payload[key] ~= nil then return payload[key] end
  local context = preflight_context(payload)
  if context == nil then return nil end
  return context[key]
end

function M.runner_request(payload)
  payload = M.validate_request(payload)
  return {
    schema = "testing-runner.module-test-loop.request.v1",
    module = payload.module,
    config = payload.config,
    e2e_driver = payload.e2e_driver,
    no_browser = fallback(payload, "no_browser"),
    dry_run = fallback(payload, "dry_run"),
    dry_run_github = payload.dry_run_github,
    backend = payload.backend,
    native_argv = fallback(payload, "native_argv"),
    ui_loop = payload.ui_loop,
    module_discovery = payload.module_discovery,
    cdp_execution = payload.cdp_execution,
    preflight_result = payload.preflight_result,
    artifact_root = payload.artifact_root,
    source_ref = payload.source_ref,
    trace_id = payload.trace_id,
    dedup_key = payload.dedup_key,
  }
end

local function add_error(errors, id, message)
  table.insert(errors, { id = id, message = message })
end

local function expect_equal(errors, id, actual, expected)
  if actual == expected then return end
  add_error(errors, id, "module transition expected " .. tostring(expected) .. " but got " .. tostring(actual))
end

function M.saga_conformance_errors()
  local readiness = {
    schema = "browser-readiness.result.v1",
    status = "ready",
    request_context = {
      native_argv = { "conformance-module-check" },
      dry_run = false,
      no_browser = true,
    },
  }
  local ok, request = pcall(M.runner_request, {
    schema = "module-test-loop.start.v1",
    module = "conformance-module",
    backend = "fkst-native",
    preflight_result = readiness,
    artifact_root = ".testing/runs/conformance-module",
    source_ref = { kind = "host-module", ref = "conformance-module" },
    trace_id = "trace-conformance-module",
    dedup_key = "conformance-module-run",
  })
  local errors = {}
  if not ok then
    add_error(errors, "module-test-loop.saga.runner-request", tostring(request))
    return errors
  end
  expect_equal(errors, "module-test-loop.saga.schema", request.schema, "testing-runner.module-test-loop.request.v1")
  expect_equal(errors, "module-test-loop.saga.module", request.module, "conformance-module")
  expect_equal(errors, "module-test-loop.saga.backend", request.backend, "fkst-native")
  expect_equal(errors, "module-test-loop.saga.native-argv", request.native_argv and request.native_argv[1], "conformance-module-check")
  expect_equal(errors, "module-test-loop.saga.dry-run", request.dry_run, false)
  expect_equal(errors, "module-test-loop.saga.no-browser", request.no_browser, true)
  expect_equal(errors, "module-test-loop.saga.artifact-root", request.artifact_root, ".testing/runs/conformance-module")
  expect_equal(errors, "module-test-loop.saga.trace-id", request.trace_id, "trace-conformance-module")
  expect_equal(errors, "module-test-loop.saga.dedup-key", request.dedup_key, "conformance-module-run")
  return errors
end

return M
