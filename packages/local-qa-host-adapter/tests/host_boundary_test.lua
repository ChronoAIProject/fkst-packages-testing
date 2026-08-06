local execution = require("contract.structured_execution")
local workflow_qa = require("contract.workflow_qa")
local execution_grant = require("departments.execution_grant.main")
local terminal = require("departments.terminal.main")
local testing = require("testkit.testing")
local t = fkst.test

local function digest(char) return string.rep(char, 64) end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function department_event(queue, payload, ports)
  local event = { queue = queue, payload = payload }
  if ports ~= nil then event["test_" .. "ports"] = ports end
  return event
end

local function grant_fixture()
  local root = ".testing/runs/local-qa-host-boundary"
  local repository = {
    url = "https://example.invalid/repository.git",
    commit_sha = string.rep("1", 40),
  }
  local request = {
    schema = execution.schemas.grant_request,
    execution_mode = "structured-api-cli",
    repository = repository,
    preauthorization_ref = root .. "/preauthorization.json",
    preauthorization_sha256 = digest("1"),
    plan_ref = root .. "/plan.json",
    plan_sha256 = digest("2"),
    environment_receipt_ref = root .. "/environment-receipt.json",
    environment_receipt_sha256 = digest("3"),
    grant_ref = root .. "/grant.json",
    trace_id = "trace-local-qa-host-boundary",
    dedup_key = "dedup-local-qa-host-boundary",
    source_ref = { kind = "workflow-qa", ref = "local-qa-host-boundary" },
  }
  local environment = {
    schema = "environment-factory.receipt.v2",
    operation_id = "local-qa-host-boundary",
    status = "ready",
    profile_revision = "profile-v1",
    profile_sha256 = digest("9"),
    repository = copy(repository),
    workspace_ref = { kind = "workspace", ref = "local-qa-host-boundary-workspace" },
    base_url = "http://127.0.0.1:4173/health",
    runtime_ports = { { name = "application", port = 4173 } },
    sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
    browser_readiness = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
        { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } },
          cdp_url = "http://127.0.0.1:9222" },
      },
      source_ref = { kind = "artifact", ref = root .. "/operation-state.json" },
      request_context = { dry_run = false },
      correlation = {
        schema = "environment-factory.browser-readiness-correlation.v1",
        attempt_id = "attempt-1",
        operation_id = "local-qa-host-boundary",
        operation_state_ref = { kind = "artifact", ref = root .. "/operation-state.json" },
        readiness_attempt_ref = { kind = "artifact", ref = root .. "/readiness-attempt.json" },
        readiness_attempt_sha256 = digest("8"),
        base_url = "http://127.0.0.1:4173/health",
        sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
        trace_id = request.trace_id,
        dedup_key = request.dedup_key,
      },
    },
    artifact_root = root,
    diagnostic_refs = {},
    cleanup_ref = { kind = "environment-cleanup", ref = "local-qa-host-boundary" },
    cleanup_status = "pending",
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  local plan = {
    schema = "testing-structured-plan.v2",
    execution_mode = "structured-api-cli",
    repository = copy(repository),
    environment_receipt_sha256 = request.environment_receipt_sha256,
    browser_readiness_sha256 = digest("8"),
    case_catalog_sha256 = digest("4"),
    module_plan_sha256 = digest("5"),
    cases = { {
      case_id = "cli-version",
      kind = "cli",
      argv = { "fixture-cli", "--version" },
      timeout_seconds = 10,
      assertions = { { type = "exit-code", expected = 0 } },
    } },
    residual_risk_case_ids = {},
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  local preauthorization = {
    schema = execution.schemas.preauthorization,
    authorization_id = "local-qa-host-authorization",
    repository = copy(repository),
    profile_sha256 = digest("9"),
    case_catalog_sha256 = digest("4"),
    capabilities = { cli = { { argv_prefix = { "fixture-cli" } } }, http = {} },
    authority = { kind = "host-policy", ref = "local-qa-host-policy" },
    policy_revision = "local-qa-host-policy-v1",
    evidence_ref = { kind = "attestation", ref = "local-qa-host-preauthorization" },
    issued_at = "2026-07-20T00:00:00Z",
    expires_at = "2026-07-20T01:00:00Z",
    max_uses = 1,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  return request, preauthorization, plan, environment
end

local function grant_runtime(mutate)
  local request, preauthorization, plan, environment = grant_fixture()
  local writes, claims = 0, 0
  local artifacts = {
    [request.preauthorization_ref] = { value = preauthorization, digest = request.preauthorization_sha256 },
    [request.plan_ref] = { value = plan, digest = request.plan_sha256 },
    [request.environment_receipt_ref] = { value = environment, digest = request.environment_receipt_sha256 },
  }
  local ports = {
    load_artifact = function(ref) return artifacts[ref] end,
    write_artifact = function(ref, value)
      writes = writes + 1
      artifacts[ref] = { value = copy(value), digest = digest("b") }
      return true
    end,
    artifact_digest = function(ref) return artifacts[ref] and artifacts[ref].digest end,
    claim_preauthorization = function()
      claims = claims + 1
      return { status = "claimed", claim_id = "local-qa-host-claim" }
    end,
    grant_values = function()
      return {
        grant_id = "local-qa-host-grant",
        evidence_ref = { kind = "attestation", ref = "local-qa-host-grant" },
        issued_at = "2026-07-20T00:10:00Z",
        expires_at = "2026-07-20T00:20:00Z",
        now = "2026-07-20T00:15:00Z",
      }
    end,
    record_terminal = function() return true end,
  }
  if mutate then mutate(ports, artifacts, request) end
  return request, ports, function() return writes end, function() return claims end
end

local function terminal_fixture()
  local root = ".testing/runs/local-qa-host-boundary"
  local payload = {
    schema = workflow_qa.schemas.terminal,
    repository = "owner/repo",
    issue_number = 568,
    run_id = "local-qa-host-boundary",
    status = "passed",
    counts = { planned = 1, executed = 1, passed = 1, failed = 0, skipped = 0, error = 0, blocked = 0 },
    artifact_root = root,
    aggregate_report_ref = root .. "/aggregate-report.json",
    aggregate_report_sha256 = digest("4"),
    aggregate_publication_receipt_ref = root .. "/publication-receipt.json",
    aggregate_publication_receipt_sha256 = digest("5"),
    cleanup_receipt_ref = root .. "/cleanup-receipt.json",
    cleanup_receipt_sha256 = digest("6"),
    terminal_policy = "host",
    trace_id = "trace-local-qa-host-boundary",
    dedup_key = "dedup-local-qa-host-boundary",
  }
  local artifacts = {
    [payload.aggregate_report_ref] = { value = {
      schema = "test-publication.qa-aggregate-report.v1",
      repository = { slug = payload.repository, commit_sha = string.rep("1", 40) },
      run_id = payload.run_id,
      status = payload.status,
      counts = copy(payload.counts),
      trace_id = payload.trace_id,
      dedup_key = payload.dedup_key,
    }, digest = payload.aggregate_report_sha256 },
    [payload.aggregate_publication_receipt_ref] = { value = {
      schema = "test-publication.qa-publication-receipt.v2",
      repository = { slug = payload.repository, commit_sha = string.rep("1", 40) },
      run_id = payload.run_id,
      status = "published",
      stage = "aggregate-report",
      attempt = 1,
      artifact_sha256 = payload.aggregate_report_sha256,
      receipt_ref = payload.aggregate_publication_receipt_ref,
      trace_id = payload.trace_id,
      dedup_key = payload.dedup_key,
    }, digest = payload.aggregate_publication_receipt_sha256 },
    [payload.cleanup_receipt_ref] = { value = {
      schema = "environment-factory.cleanup-receipt.v1",
      operation_id = payload.run_id,
      status = "complete",
      attempted_resources = { { resource_id = "workspace", resource_kind = "workspace", status = "cleaned" } },
      verified_removals = { "workspace" },
      remaining_resources = {},
      artifact_root = root,
      trace_id = payload.trace_id,
      dedup_key = payload.dedup_key,
    }, digest = payload.cleanup_receipt_sha256 },
  }
  local records = 0
  local ports = {
    load_artifact = function(ref) return artifacts[ref] end,
    write_artifact = function() return true end,
    artifact_digest = function() return digest("a") end,
    claim_preauthorization = function() return { status = "claimed", claim_id = "unused" } end,
    grant_values = function() return {} end,
    record_terminal = function(value)
      records = records + 1
      t.eq(value.run_id, payload.run_id)
      return true
    end,
  }
  return payload, ports, artifacts, function() return records end
end

local function failure_trace(department, event, prefix)
  local trace = testing.run_fake_expecting_failure(department, event)
  t.eq(#trace.raises, 0)
  t.is_true(tostring(trace.failure.error):find(prefix or "local-qa-host:", 1, true) ~= nil)
  return trace
end

return {
  test_execution_grant_uses_real_runtime_and_replays_persisted_result = function()
    local request, ports, writes, claims = grant_runtime()
    local queue = "workflow-qa.workflow_qa_execution_grant_request"
    local first = testing.run_fake(execution_grant, department_event(queue, request, ports))
    local replay = testing.run_fake(execution_grant, department_event(queue, request, ports))
    t.eq(#first.raises, 1)
    t.eq(first.raises[1].queue, "workflow-qa.execution_grant_result")
    t.eq(first.raises[1].payload.schema, execution.schemas.grant_result)
    t.eq(replay.raises[1].payload.grant_sha256, first.raises[1].payload.grant_sha256)
    t.eq(writes(), 1)
    t.eq(claims(), 1)
  end,

  test_execution_grant_default_binding_and_failures_emit_no_result = function()
    local request, ports = grant_runtime()
    local previous = _G.local_qa_workflow_qa_runtime
    _G.local_qa_workflow_qa_runtime = ports
    local queue = "workflow-qa.workflow_qa_execution_grant_request"
    local ok, trace = pcall(testing.run_fake, execution_grant, department_event(queue, request))
    _G.local_qa_workflow_qa_runtime = previous
    if not ok then error(trace) end
    t.eq(#trace.raises, 1)

    request, ports = grant_runtime(function(runtime_ports)
      runtime_ports.write_artifact = function() return false end
    end)
    failure_trace(execution_grant, department_event(queue, request, ports))

    failure_trace(execution_grant, department_event(queue, request, {}))

    request, ports = grant_runtime(function(_, artifacts, grant_request)
      artifacts[grant_request.environment_receipt_ref].value.repository.commit_sha = string.rep("9", 40)
    end)
    failure_trace(execution_grant, department_event(queue, request, ports))
  end,

  test_terminal_records_only_after_shared_validation_succeeds = function()
    local payload, ports, artifacts, records = terminal_fixture()
    local queue = "workflow-qa.workflow_qa_terminal_request"
    local trace = testing.run_fake(terminal, department_event(queue, payload, ports))
    t.eq(#trace.raises, 0)
    t.eq(records(), 1)

    payload, ports, artifacts, records = terminal_fixture()
    artifacts[payload.aggregate_report_ref].value.status = "failed"
    failure_trace(terminal, department_event(queue, payload, ports))
    t.eq(records(), 0)

    payload, ports, _, records = terminal_fixture()
    payload.aggregate_report_sha256 = "bad"
    failure_trace(terminal, department_event(queue, payload, ports), "contract.workflow-qa:")
    t.eq(records(), 0)

    payload, ports, _, records = terminal_fixture()
    ports.record_terminal = nil
    failure_trace(terminal, department_event(queue, payload, ports))
    t.eq(records(), 0)
  end,
}
