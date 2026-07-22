local M = {}

M.digest_environment = string.rep("a", 64)
M.digest_readiness = string.rep("8", 64)
M.digest_plan = string.rep("b", 64)
M.digest_grant = string.rep("c", 64)
M.digest_catalog = string.rep("d", 64)
M.digest_module_plan = string.rep("e", 64)
M.digest_authorization = string.rep("f", 64)
M.repository = {
  url = "https://example.invalid/repository.git",
  commit_sha = string.rep("1", 40),
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end
M.copy = copy

function M.request(root, run_id)
  root = root or ".testing/runs/structured"
  run_id = run_id or "run-110"
  local value = {
    schema = "testing-runner.structured-execution.request.v2",
    repository = copy(M.repository),
    environment_receipt_ref = root .. "/environment/environment-receipt-ready.json",
    environment_receipt_sha256 = M.digest_environment,
    browser_readiness_ref = root .. "/browser-readiness.json",
    browser_readiness_sha256 = M.digest_readiness,
    execution_grant_ref = root .. "/execution-grant.json",
    execution_grant_sha256 = M.digest_grant,
    artifact_root = root .. "/execution",
    trace_id = "trace-structured",
    dedup_key = "dedup-structured",
    source_ref = { kind = "workflow-qa", ref = run_id },
  }
  value["test_" .. "plan_ref"] = root .. "/source-plan.json"
  value["test_" .. "plan_sha256"] = M.digest_plan
  return value
end

function M.receipt(request)
  local environment_root = request.environment_receipt_ref:match("^(.*)/environment%-receipt%-ready%.json$")
  local operation_id = request.source_ref.ref
  local base_url = "http://127.0.0.1:4173/health"
  local sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } }
  local operation_state_ref = { kind = "artifact", ref = environment_root .. "/operation-state.json" }
  return {
    schema = "environment-factory.receipt.v2",
    operation_id = operation_id,
    status = "ready",
    profile_revision = "profile-v1",
    profile_sha256 = string.rep("9", 64),
    repository = copy(request.repository),
    workspace_ref = { kind = "workspace", ref = operation_id .. "-workspace" },
    base_url = base_url,
    runtime_ports = { { name = "application", port = 4173 } },
    sessions = copy(sessions),
    browser_readiness = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
        { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } }, cdp_url = "http://127.0.0.1:9222" },
      },
      source_ref = copy(operation_state_ref),
      request_context = { dry_run = false },
      correlation = {
        schema = "environment-factory.browser-readiness-correlation.v1",
        attempt_id = "attempt-1",
        operation_id = operation_id,
        operation_state_ref = copy(operation_state_ref),
        readiness_attempt_ref = { kind = "artifact", ref = environment_root .. "/readiness-attempts/attempt-1.json" },
        readiness_attempt_sha256 = string.rep("a", 64),
        base_url = base_url,
        sessions = copy(sessions),
        trace_id = request.trace_id,
        dedup_key = request.dedup_key,
      },
    },
    artifact_root = environment_root,
    diagnostic_refs = {},
    cleanup_ref = { kind = "environment-cleanup", ref = operation_id },
    cleanup_status = "pending",
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
end

function M.readiness(request)
  local receipt = M.receipt(request)
  local value = copy(receipt.browser_readiness)
  value.source_ref = { kind = "workflow-qa", ref = request.source_ref.ref }
  return value
end

function M.plan(request, cases)
  return {
    schema = "testing-structured-plan.v2",
    execution_mode = "structured-api-cli",
    repository = copy(request.repository),
    environment_receipt_sha256 = request.environment_receipt_sha256,
    browser_readiness_sha256 = request.browser_readiness_sha256,
    case_catalog_sha256 = M.digest_catalog,
    module_plan_sha256 = M.digest_module_plan,
    cases = cases or {
      {
        case_id = "cli-version",
        kind = "cli",
        argv = { "fixture-cli", "--version" },
        timeout_seconds = 10,
        assertions = { { type = "exit-code", expected = 0 } },
      },
    },
    residual_risk_case_ids = {},
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
end

function M.grant(request, capabilities, expires_at)
  capabilities = capabilities or {
    cli = { { argv_prefix = { "fixture-cli" } } },
    http = {},
  }
  return {
    schema = "testing-structured-execution-grant.v1",
    grant_id = "grant-110",
    parent_authorization_sha256 = M.digest_authorization,
    plan_sha256 = request.test_plan_sha256,
    environment_receipt_sha256 = request.environment_receipt_sha256,
    repository = copy(request.repository),
    cli_capabilities = copy(capabilities.cli or {}),
    http_capabilities = copy(capabilities.http or {}),
    authority = { kind = "policy", ref = "testing-authority" },
    policy_revision = "policy-v1",
    evidence_ref = { kind = "attestation", ref = "grant-110" },
    issued_at = "2026-07-20T00:00:00Z",
    expires_at = expires_at or "2026-07-20T01:00:00Z",
    max_uses = 1,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
end

function M.attestation()
  return {
    grant_sha256 = M.digest_grant,
    authority = { kind = "policy", ref = "testing-authority" },
    policy_revision = "policy-v1",
    evidence_ref = { kind = "attestation", ref = "grant-110" },
  }
end

function M.artifacts(request, plan, grant)
  return {
    [request.environment_receipt_ref] = {
      raw = "environment",
      digest = request.environment_receipt_sha256,
      value = M.receipt(request),
    },
    [request.browser_readiness_ref] = {
      raw = "readiness",
      digest = request.browser_readiness_sha256,
      value = M.readiness(request),
    },
    [request.test_plan_ref] = {
      raw = "plan",
      digest = request.test_plan_sha256,
      value = plan or M.plan(request),
    },
    [request.execution_grant_ref] = {
      raw = "grant",
      digest = request.execution_grant_sha256,
      value = grant or M.grant(request),
    },
  }
end

return M
