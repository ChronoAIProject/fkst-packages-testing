local M = {}

local strings = require("contract.strings")
local testing_contract = require("contract.testing")

local statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  mixed = true,
}

function M.validate_module_start(payload)
  if type(payload) ~= "table" then
    error("testing-pipeline: malformed-request: payload must be a table")
  end
  if payload.schema ~= "testing-pipeline.module-start.v1" then
    error("testing-pipeline: unknown-schema: expected testing-pipeline.module-start.v1")
  end
  if not strings.is_bounded_string(payload.module, 256) then
    error("testing-pipeline: malformed-request: module is required")
  end
  if payload.artifact_root ~= nil and not strings.is_artifact_root(payload.artifact_root) then
    error("testing-pipeline: malformed-request: artifact_root must be a safe .testing/runs/... path")
  end
  if payload.mutation_policy ~= nil and testing_contract.copy_mutation_policy(payload.mutation_policy) == nil then
    error("testing-pipeline: malformed-request: mutation_policy must be a bounded testing-runner.mutation-policy.v1 payload")
  end
  return payload
end

function M.module_loop_request(payload)
  payload = M.validate_module_start(payload)
  local src = testing_contract.copy_source_ref(payload.source_ref, "testing-pipeline", payload.module)
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
    priority = payload.priority,
    mutation_policy = payload.mutation_policy,
    preflight_result = payload.preflight_result,
    artifact_root = payload.artifact_root,
    agentic_testing_repo_root = payload.agentic_testing_repo_root,
    source_ref = src,
    trace_id = testing_contract.trace_id(payload.trace_id, src, payload.artifact_root),
    dedup_key = testing_contract.dedup_key(payload.dedup_key, {
      "testing-pipeline",
      "module",
      payload.module,
      src.kind,
      src.ref,
      payload.artifact_root or "artifact",
    }),
  }
end

function M.validate_testing_result(result)
  if type(result) ~= "table" then
    error("testing-pipeline: malformed-result: result must be a table")
  end
  if result.schema ~= "testing-runner.result.v1" then
    error("testing-pipeline: unknown-result-schema: expected testing-runner.result.v1")
  end
  return result
end

function M.validate_artifact_summary(summary)
  if type(summary) ~= "table" then
    error("testing-pipeline: malformed-summary: summary must be a table")
  end
  if summary.schema ~= "test-artifacts.summary.v1" then
    error("testing-pipeline: unknown-summary-schema: expected test-artifacts.summary.v1")
  end
  if not statuses[summary.status] then
    error("testing-pipeline: malformed-summary: unknown status")
  end
  if not strings.is_artifact_root(summary.artifact_root) then
    error("testing-pipeline: malformed-summary: artifact_root must be a safe .testing/runs/... path")
  end
  return summary
end

return M
