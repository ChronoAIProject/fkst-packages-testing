local adapter = require("host_workflow_qa_adapter")
local execution = require("contract.structured_execution")
local workflow_qa = require("contract.workflow_qa")
local t = fkst.test

local function digest(char) return string.rep(char, 64) end

local function fixture()
  local repository = {
    url = "https://example.invalid/testing/controlled-fixture.git",
    commit_sha = string.rep("1", 40),
  }
  local trace_id = "trace-controlled-fixture-1"
  local dedup_key = "controlled-fixture-1"
  local preauthorization = {
    schema = execution.schemas.preauthorization,
    authorization_id = "controlled-execution-approval-1",
    repository = repository,
    profile_sha256 = digest("9"),
    case_catalog_sha256 = digest("2"),
    capabilities = {
      cli = {},
      http = { {
        origin = "http://127.0.0.1:4173",
        methods = { "GET" },
        path_prefixes = { "/health" },
      } },
    },
    authority = { kind = "host-policy", ref = "fixtures/execution" },
    policy_revision = "controlled-policy-1",
    evidence_ref = { kind = "signed-attestation", ref = "fixtures/execution-approval-1" },
    issued_at = "2026-07-20T00:00:00Z",
    expires_at = "2026-07-20T01:00:00Z",
    max_uses = 1,
    trace_id = trace_id,
    dedup_key = dedup_key,
  }
  local plan = {
    schema = execution.schemas.plan,
    execution_mode = "structured-api-cli",
    repository = repository,
    environment_receipt_sha256 = digest("3"),
    browser_readiness_sha256 = digest("4"),
    case_catalog_sha256 = digest("2"),
    module_plan_sha256 = digest("8"),
    cases = { {
      case_id = "health",
      kind = "http",
      timeout_seconds = 10,
      request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} },
      assertions = { { type = "status-code", expected = 200 } },
    } },
    residual_risk_case_ids = {},
    trace_id = trace_id,
    dedup_key = dedup_key,
  }
  local request = {
    schema = execution.schemas.grant_request,
    execution_mode = "structured-api-cli",
    repository = repository,
    preauthorization_ref = ".testing/runs/controlled/execution/preauthorization.json",
    preauthorization_sha256 = digest("1"),
    plan_ref = ".testing/runs/controlled/execution/structured-plan.json",
    plan_sha256 = digest("a"),
    environment_receipt_ref = ".testing/runs/controlled/environment/environment-receipt-ready.json",
    environment_receipt_sha256 = digest("3"),
    grant_ref = ".testing/runs/controlled/execution/execution-grant.json",
    trace_id = trace_id,
    dedup_key = dedup_key,
    source_ref = { kind = "workflow-qa", ref = "controlled-run-1" },
  }
  local operation_state_ref = {
    kind = "artifact", ref = ".testing/runs/controlled/environment/operation-state.json",
  }
  local sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } }
  local environment = {
    schema = "environment-factory.receipt.v2",
    operation_id = "controlled-run-1",
    status = "ready",
    profile_revision = "controlled-profile-v1",
    profile_sha256 = digest("9"),
    repository = repository,
    workspace_ref = { kind = "workspace", ref = "controlled-run-1-workspace" },
    base_url = "http://127.0.0.1:4173/health",
    runtime_ports = { { name = "application", port = 4173 } },
    sessions = sessions,
    browser_readiness = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      sessions = {
        { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
        { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } }, cdp_url = "http://127.0.0.1:9222" },
      },
      source_ref = operation_state_ref,
      request_context = { dry_run = false },
      correlation = {
        schema = "environment-factory.browser-readiness-correlation.v1",
        attempt_id = "controlled-readiness-attempt",
        operation_id = "controlled-run-1",
        operation_state_ref = operation_state_ref,
        readiness_attempt_ref = { kind = "artifact", ref = ".testing/runs/controlled/environment/readiness-attempts/controlled-readiness-attempt.json" },
        readiness_attempt_sha256 = digest("8"),
        base_url = "http://127.0.0.1:4173/health",
        sessions = sessions,
        trace_id = trace_id,
        dedup_key = dedup_key,
      },
    },
    artifact_root = ".testing/runs/controlled/environment",
    diagnostic_refs = {},
    cleanup_ref = { kind = "environment-cleanup", ref = "controlled-run-1" },
    cleanup_status = "pending",
    trace_id = trace_id,
    dedup_key = dedup_key,
  }
  return request, {
    preauthorization = preauthorization,
    preauthorization_sha256 = digest("1"),
    plan = plan,
    plan_sha256 = digest("a"),
    environment = environment,
    environment_receipt_sha256 = digest("3"),
  }
end

local function values()
  return {
    grant_id = "controlled-grant-1",
    evidence_ref = { kind = "signed-attestation", ref = "fixtures/execution-grant-1" },
    issued_at = "2026-07-20T00:10:00Z",
    expires_at = "2026-07-20T00:20:00Z",
    now = "2026-07-20T00:15:00Z",
  }
end

local function runtime(request, materials, mutate_artifacts)
  local writes = 0
  local terminal
  local claim
  local claim_calls = 0
  local artifacts = {
    [request.preauthorization_ref] = {
      value = materials.preauthorization,
      digest = materials.preauthorization_sha256,
    },
    [request.plan_ref] = { value = materials.plan, digest = materials.plan_sha256 },
    [request.environment_receipt_ref] = {
      value = materials.environment,
      digest = request.environment_receipt_sha256,
    },
    [".testing/runs/controlled/aggregate-report.json"] = {
      value = {
        schema = "test-publication.qa-aggregate-report.v1", status = "passed",
        repository = { slug = "owner/repo", commit_sha = string.rep("1", 40) },
        run_id = "controlled-run-1",
        counts = { planned = 1, executed = 1, passed = 1, failed = 0, skipped = 0, error = 0, blocked = 0 },
        trace_id = "trace-controlled-fixture-1", dedup_key = "controlled-fixture-1",
      },
      digest = digest("4"),
    },
    [".testing/runs/controlled/publication-receipts/aggregate-report-1.json"] = {
      value = {
        schema = "test-publication.qa-publication-receipt.v2", status = "published",
        repository = { slug = "owner/repo", commit_sha = string.rep("1", 40) },
        run_id = "controlled-run-1", stage = "aggregate-report", attempt = 1,
        artifact_sha256 = digest("4"),
        receipt_ref = ".testing/runs/controlled/publication-receipts/aggregate-report-1.json",
        trace_id = "trace-controlled-fixture-1", dedup_key = "controlled-fixture-1",
      },
      digest = digest("5"),
    },
    [".testing/runs/controlled/environment/cleanup-receipt-complete.json"] = {
      value = {
        schema = "environment-factory.cleanup-receipt.v1", operation_id = "controlled-run-1",
        status = "complete", attempted_resources = {
          { resource_id = "workspace", resource_kind = "workspace", status = "cleaned" },
        }, verified_removals = { "workspace" }, remaining_resources = {},
        artifact_root = ".testing/runs/controlled/environment",
        trace_id = "trace-controlled-fixture-1", dedup_key = "controlled-fixture-1",
      },
      digest = digest("6"),
    },
  }
  if mutate_artifacts ~= nil then mutate_artifacts(artifacts) end
  local ports = {
    load_artifact = function(ref) return artifacts[ref] end,
    write_artifact = function(ref, value)
      if artifacts[ref] ~= nil then return false end
      writes = writes + 1
      artifacts[ref] = { value = value, digest = digest("b") }
      return true
    end,
    artifact_digest = function(ref) return artifacts[ref] and artifacts[ref].digest end,
    claim_preauthorization = function(value)
      claim_calls = claim_calls + 1
      if claim ~= nil and not workflow_qa.same_request(claim.value, value) then
        return { status = "blocked" }
      end
      claim = claim or { value = value, claim_id = "controlled-preauthorization-claim" }
      return { status = "claimed", claim_id = claim.claim_id, replayed = claim_calls > 1 }
    end,
    grant_values = function() return values() end,
    record_terminal = function(value)
      if terminal ~= nil and not workflow_qa.same_request(terminal, value) then return false end
      terminal = value
      return true
    end,
  }
  return ports, function() return writes end, function() return terminal end,
    function() return claim_calls end
end

local function terminal_payload()
  return {
    schema = workflow_qa.schemas.terminal,
    repository = "owner/repo",
    issue_number = 100,
    run_id = "controlled-run-1",
    status = "passed",
    counts = { planned = 1, executed = 1, passed = 1, failed = 0, skipped = 0, error = 0, blocked = 0 },
    artifact_root = ".testing/runs/controlled",
    aggregate_report_ref = ".testing/runs/controlled/aggregate-report.json",
    aggregate_report_sha256 = digest("4"),
    aggregate_publication_receipt_ref = ".testing/runs/controlled/publication-receipts/aggregate-report-1.json",
    aggregate_publication_receipt_sha256 = digest("5"),
    cleanup_receipt_ref = ".testing/runs/controlled/environment/cleanup-receipt-complete.json",
    cleanup_receipt_sha256 = digest("6"),
    terminal_policy = "host",
    trace_id = "trace-controlled-fixture-1",
    dedup_key = "controlled-fixture-1",
  }
end

return {
  test_host_derives_and_returns_one_use_execution_grant = function()
    local request, materials = fixture()
    local grant = adapter.derive_execution_grant(request, materials, values())
    t.eq(grant.schema, execution.schemas.grant)
    t.eq(grant.max_uses, 1)
    t.eq(grant.plan_sha256, request.plan_sha256)
    t.eq(grant.environment_receipt_sha256, request.environment_receipt_sha256)

    local event = adapter.execution_grant_result_event(request, digest("b"))
    t.eq(event.queue, "workflow-qa.execution_grant_result")
    t.eq(event.payload.schema, execution.schemas.grant_result)
    t.eq(event.payload.status, "granted")
    t.eq(event.payload.grant_ref, request.grant_ref)
    t.eq(event.payload.source_ref.ref, "controlled-run-1")
  end,

  test_host_wrapper_persists_grant_once_and_replays_same_result = function()
    local request, materials = fixture()
    local ports, writes, _, claim_calls = runtime(request, materials)
    local first = adapter.handle_execution_grant(request, ports)
    local replay = adapter.handle_execution_grant(request, ports)
    t.eq(writes(), 1)
    t.eq(claim_calls(), 1)
    t.eq(first.queue, "workflow-qa.execution_grant_result")
    t.eq(replay.payload.grant_sha256, first.payload.grant_sha256)
  end,

  test_host_rejects_changed_plan_after_preauthorization_claim = function()
    local request, materials = fixture()
    local ports, _, _, claim_calls = runtime(request, materials)
    adapter.handle_execution_grant(request, ports)
    local changed = execution.copy(request)
    changed.plan_sha256 = digest("7")
    t.raises(function() adapter.handle_execution_grant(changed, ports) end)
    t.eq(claim_calls(), 1)
  end,

  test_host_wrapper_records_only_valid_terminal_handoff = function()
    local request, materials = fixture()
    local ports, _, recorded = runtime(request, materials)
    local payload = terminal_payload()
    adapter.handle_terminal(payload, ports)
    t.eq(recorded().run_id, payload.run_id)
    local malformed = terminal_payload()
    malformed.terminal_policy = "package"
    t.raises(function() adapter.handle_terminal(malformed, ports) end)
  end,

  test_terminal_rejects_aggregate_report_status_mismatch_through_generic_host_wrapper = function()
    local request, materials = fixture()
    local ports = runtime(request, materials, function(artifacts)
      artifacts[".testing/runs/controlled/aggregate-report.json"].value.status = "failed"
    end)
    t.raises(function() adapter.handle_terminal(terminal_payload(), ports) end)
  end,
}
