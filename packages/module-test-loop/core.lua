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
    preflight_result = payload.preflight_result,
    artifact_root = payload.artifact_root,
    agentic_testing_repo_root = payload.agentic_testing_repo_root,
    source_ref = payload.source_ref,
    trace_id = payload.trace_id,
    dedup_key = payload.dedup_key,
  }
end

return M
