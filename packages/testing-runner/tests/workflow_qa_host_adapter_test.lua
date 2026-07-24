local design_loop = require("testing_ai.module_ai_design_loop")
local execution = require("contract.structured_execution")
local fixtures = require("tests.structured_execution_helpers")
local host_adapter = require("testing_runtime.workflow_qa_host_adapter")
local workflow_qa = require("contract.workflow_qa")
local t = fkst.test

local adapter = host_adapter.new({ error_prefix = "testing-runner-host-adapter-test" })

local function digest(char) return string.rep(char, 64) end
local function pointer(path) return { kind = "artifact", ref = path } end

local function workflow_request()
  local root = ".testing/runs/host-adapter-workflow"
  local repository = {
    slug = "owner/repo", url = "https://github.com/owner/repo.git", commit_sha = string.rep("a", 40),
  }
  return {
    schema = workflow_qa.schemas.request,
    issue = { repository = repository.slug, number = 100, state = "open", labels = { "fkst-qa" } },
    run_id = "host-adapter-workflow", repository = repository,
    artifact_root = root, state_ref = root .. "/workflow-state.json",
    proposed_cases = { {
      id = "seed-health", module_id = "api", priority = "P0", title = "Health endpoint",
      objective = "Verify the approved health endpoint.", case_kind = "api",
      actions = { { action = "http", target = "/health", expected = "HTTP 200" } },
      expected_observable = "The service reports healthy.",
      coverage_subject_ids = { "REQ-HEALTH" }, review_status = "executable",
    } },
    environment_start = {
      schema = "environment-factory.start.v1", operation_id = "host-adapter-workflow",
      repository = { url = repository.url, commit_sha = repository.commit_sha },
      profile_ref = { kind = "host-profile", ref = "profiles/qa" },
      approval_ref = { kind = "approval", ref = "approvals/qa" },
      validation_receipt_ref = pointer(".testing/approvals/qa.json"),
      operation_state_ref = pointer(root .. "/environment/operation-state.json"),
      artifact_root = root .. "/environment", base_url = "http://127.0.0.1:4173/health",
      runtime_ports = { { name = "application", port = 4173 } },
      sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
      trace_id = "trace-host-adapter-workflow", dedup_key = "dedup-host-adapter-workflow",
    },
    analysis_request = {
      schema = "testing-design.analysis-request.v1",
      repository = {
        url = repository.url, commit_sha = repository.commit_sha, baseline_commit_sha = string.rep("b", 40),
        workspace_ref = { kind = "workspace", ref = "approved/host-adapter-workflow" },
        approval_ref = pointer(".testing/approvals/repository.json"), approval_sha256 = digest("b"),
      },
      inputs = {}, artifact_root = root .. "/analysis",
      source_ref = { kind = "workflow-qa", ref = "host-adapter-workflow" },
      trace_id = "trace-host-adapter-workflow", dedup_key = "dedup-host-adapter-workflow",
    },
    design_module_start = {
      schema = "module-testing-pipeline.module-start.v1", module = "api", no_browser = false,
      dry_run = true, artifact_root = root .. "/design",
      source_ref = { kind = "workflow-qa", ref = "host-adapter-workflow" },
      trace_id = "trace-host-adapter-workflow", dedup_key = "dedup-host-adapter-workflow",
      cdp_execution = {
        schema = "testing-runner.module-cdp-execution.v1",
        ai_design_loop_request = {
          schema = design_loop.schemas.request, artifact_root = root .. "/design/loop",
          seed_cases_ref = { artifact_pointer = root .. "/design/seed.json", artifact_digest = "seed" },
          deterministic_cases_ref = { artifact_pointer = root .. "/design/deterministic.json", artifact_digest = "deterministic" },
          coverage_scope_ref = { artifact_pointer = root .. "/design/coverage.json", artifact_digest = "coverage" },
          max_rounds = 3, case_budget = 16, action_budget = 32,
          trace_id = "trace-host-adapter-workflow", dedup_key = "dedup-host-adapter-workflow",
        },
      },
    },
    structured_execution = {
      artifact_root = root .. "/execution",
      preauthorization_ref = root .. "/execution/preauthorization.json",
      preauthorization_sha256 = digest("1"), case_catalog_ref = root .. "/execution/catalog.json",
      case_catalog_sha256 = digest("2"), structured_plan_ref = root .. "/execution/plan.json",
      grant_ref = root .. "/execution/grant.json",
    },
    publication = {
      ledger_ref = root .. "/run-ledger.json", defect_ledger_ref = root .. "/execution/defect-ledger.json",
      defect_receipt_ref = root .. "/execution/defect-receipt.json",
      issue_drafts_ref = root .. "/execution/issue-drafts.json",
      aggregate_report_ref = root .. "/aggregate-report.json",
      terminal_summary_ref = root .. "/terminal-summary.json",
    },
    terminal_policy = { mode = "host" },
    trace_id = "trace-host-adapter-workflow", dedup_key = "dedup-host-adapter-workflow",
  }
end

local function fixture()
  local root = ".testing/runs/host-adapter"
  local execution_request = fixtures.request(root, "host-adapter-run")
  execution_request.trace_id = "trace-host-adapter"
  execution_request.dedup_key = "dedup-host-adapter"
  local environment = fixtures.receipt(execution_request)
  local plan = fixtures.plan(execution_request, { {
    case_id = "health", kind = "http", timeout_seconds = 10,
    request = { method = "GET", url = environment.base_url, headers = {} },
    assertions = { { type = "status-code", expected = 200 } },
  } })
  local origin = environment.base_url:match("^(http://[^/]+)")
  local preauthorization = {
    schema = execution.schemas.preauthorization,
    authorization_id = "host-adapter-authorization",
    repository = fixtures.copy(execution_request.repository),
    profile_sha256 = digest("9"),
    case_catalog_sha256 = fixtures.digest_catalog,
    capabilities = {
      cli = {},
      http = { { origin = origin, methods = { "GET" }, path_prefixes = { "/health" } } },
    },
    authority = { kind = "host-policy", ref = "host-adapter-policy" },
    policy_revision = "host-adapter-policy-v1",
    evidence_ref = { kind = "attestation", ref = "host-adapter-preauthorization" },
    issued_at = "2026-07-20T00:00:00Z",
    expires_at = "2026-07-20T01:00:00Z",
    max_uses = 1,
    trace_id = execution_request.trace_id,
    dedup_key = execution_request.dedup_key,
  }
  local request = {
    schema = execution.schemas.grant_request,
    execution_mode = "structured-api-cli",
    repository = fixtures.copy(execution_request.repository),
    preauthorization_ref = root .. "/preauthorization.json",
    preauthorization_sha256 = digest("1"),
    plan_ref = root .. "/plan.json",
    plan_sha256 = fixtures.digest_plan,
    environment_receipt_ref = execution_request.environment_receipt_ref,
    environment_receipt_sha256 = execution_request.environment_receipt_sha256,
    grant_ref = root .. "/grant.json",
    trace_id = execution_request.trace_id,
    dedup_key = execution_request.dedup_key,
    source_ref = { kind = "workflow-qa", ref = "host-adapter-run" },
  }
  return request, {
    preauthorization = preauthorization,
    preauthorization_sha256 = request.preauthorization_sha256,
    plan = plan,
    plan_sha256 = request.plan_sha256,
    environment = environment,
    environment_receipt_sha256 = request.environment_receipt_sha256,
  }
end

local function values()
  return {
    grant_id = "host-adapter-grant",
    evidence_ref = { kind = "attestation", ref = "host-adapter-grant" },
    issued_at = "2026-07-20T00:10:00Z",
    expires_at = "2026-07-20T00:20:00Z",
    now = "2026-07-20T00:15:00Z",
  }
end

local function browser_fixture()
  local request, materials = fixture()
  request.execution_mode = "agentic-browser"
  materials.plan.execution_mode = "agentic-browser"
  materials.plan.cases = { {
    case_id = "login", kind = "browser", goal = "Verify the approved login flow.",
    success_conditions = { "Authenticated status is visible" },
  } }
  return request, materials
end

local function browser_values()
  return {
    grant_id = "host-adapter-browser-grant",
    readiness_attempt_id = "readiness-attempt-1",
    readiness_attempt_sha256 = digest("8"),
    target_id = "target-1", target_sha256 = digest("7"),
    allowed_auth_origins = { "https://auth.example.invalid" },
    callback = { origin = "http://127.0.0.1:43119", path = "/callback" },
    allowed_actions = { "click", "type", "submit", "press_tab", "finish" },
    approved_secret_refs = { "primary-identity", "primary-secret" },
    step_budget = 3, time_budget_seconds = 120,
    evidence_ref = { kind = "attestation", ref = "host-adapter-browser-grant" },
    issued_at = "2026-07-20T00:10:00Z", expires_at = "2026-07-20T00:20:00Z",
    now = "2026-07-20T00:15:00Z",
  }
end

local function runtime(request, materials, mutate)
  local writes, claims, terminal = 0, 0, nil
  local claimed
  local artifacts = {
    [request.preauthorization_ref] = {
      value = fixtures.copy(materials.preauthorization), digest = request.preauthorization_sha256,
    },
    [request.plan_ref] = { value = fixtures.copy(materials.plan), digest = request.plan_sha256 },
    [request.environment_receipt_ref] = {
      value = fixtures.copy(materials.environment), digest = request.environment_receipt_sha256,
    },
    [".testing/runs/host-adapter/aggregate-report.json"] = {
      value = {
        schema = "test-publication.qa-aggregate-report.v1", status = "passed",
        repository = { slug = "owner/repo", commit_sha = string.rep("1", 40) },
        run_id = "host-adapter-run",
        counts = { planned = 1, executed = 1, passed = 1, failed = 0, skipped = 0, error = 0, blocked = 0 },
        trace_id = request.trace_id, dedup_key = request.dedup_key,
      },
      digest = digest("4"),
    },
    [".testing/runs/host-adapter/publication-receipts/aggregate-report-1.json"] = {
      value = {
        schema = "test-publication.qa-publication-receipt.v2", status = "published",
        repository = { slug = "owner/repo", commit_sha = string.rep("1", 40) },
        run_id = "host-adapter-run", stage = "aggregate-report", attempt = 1,
        artifact_sha256 = digest("4"),
        receipt_ref = ".testing/runs/host-adapter/publication-receipts/aggregate-report-1.json",
        trace_id = request.trace_id, dedup_key = request.dedup_key,
      },
      digest = digest("5"),
    },
    [".testing/runs/host-adapter/environment/cleanup-receipt-complete.json"] = {
      value = {
        schema = "environment-factory.cleanup-receipt.v1", operation_id = "host-adapter-run",
        status = "complete",
        attempted_resources = { { resource_id = "workspace", resource_kind = "workspace", status = "cleaned" } },
        verified_removals = { "workspace" }, remaining_resources = {},
        artifact_root = ".testing/runs/host-adapter/environment",
        trace_id = request.trace_id, dedup_key = request.dedup_key,
      },
      digest = digest("6"),
    },
  }
  if mutate then mutate(artifacts) end
  local ports = {
    load_artifact = function(ref) return artifacts[ref] end,
    write_artifact = function(ref, value)
      if artifacts[ref] ~= nil then return false end
      writes = writes + 1
      artifacts[ref] = { value = fixtures.copy(value), digest = digest("b") }
      return true
    end,
    artifact_digest = function(ref) return artifacts[ref] and artifacts[ref].digest end,
    claim_preauthorization = function(value)
      claims = claims + 1
      if claimed ~= nil and not workflow_qa.same_request(claimed.value, value) then return { status = "blocked" } end
      claimed = claimed or { value = fixtures.copy(value), claim_id = "host-adapter-claim" }
      return { status = "claimed", claim_id = claimed.claim_id }
    end,
    grant_values = function() return values() end,
    record_terminal = function(value) terminal = fixtures.copy(value) return true end,
  }
  return ports, artifacts, function() return writes end, function() return claims end,
    function() return terminal end
end

local function terminal_payload()
  return {
    schema = workflow_qa.schemas.terminal,
    repository = "owner/repo", issue_number = 100, run_id = "host-adapter-run", status = "passed",
    counts = { planned = 1, executed = 1, passed = 1, failed = 0, skipped = 0, error = 0, blocked = 0 },
    artifact_root = ".testing/runs/host-adapter",
    aggregate_report_ref = ".testing/runs/host-adapter/aggregate-report.json",
    aggregate_report_sha256 = digest("4"),
    aggregate_publication_receipt_ref = ".testing/runs/host-adapter/publication-receipts/aggregate-report-1.json",
    aggregate_publication_receipt_sha256 = digest("5"),
    cleanup_receipt_ref = ".testing/runs/host-adapter/environment/cleanup-receipt-complete.json",
    cleanup_receipt_sha256 = digest("6"), terminal_policy = "host",
    trace_id = "trace-host-adapter", dedup_key = "dedup-host-adapter",
  }
end

return {
  test_structured_grant_derivation_persistence_and_replay = function()
    local request, materials = fixture()
    local grant = adapter.derive_execution_grant(request, materials, values())
    t.eq(grant.schema, execution.schemas.grant)
    t.eq(grant.max_uses, 1)
    local event = adapter.execution_grant_result_event(request, digest("b"))
    t.eq(event.queue, "workflow-qa.execution_grant_result")

    local ports, artifacts, writes, claims = runtime(request, materials)
    local first = adapter.handle_execution_grant(request, ports)
    local replay = adapter.handle_execution_grant(request, ports)
    t.eq(first.payload.grant_sha256, replay.payload.grant_sha256)
    t.eq(writes(), 1)
    t.eq(claims(), 1)
    t.eq(artifacts[request.grant_ref].value.grant_id, "host-adapter-grant")
  end,

  test_grant_binding_environment_and_runtime_ports_fail_closed = function()
    local request, materials = fixture()
    local ports = runtime(request, materials)
    adapter.handle_execution_grant(request, ports)
    local changed = fixtures.copy(request)
    changed.plan_sha256 = digest("7")
    t.raises(function() adapter.handle_execution_grant(changed, ports) end)

    request, materials = fixture()
    materials.environment.base_url = "https://example.invalid/health"
    t.raises(function() adapter.derive_execution_grant(request, materials, values()) end)
    request, materials = fixture()
    local foreign = runtime(request, materials, function(artifacts)
      artifacts[request.environment_receipt_ref].value.repository.commit_sha = string.rep("9", 40)
    end)
    t.raises(function() adapter.handle_execution_grant(request, foreign) end)
    request, materials = fixture()
    t.raises(function() adapter.handle_execution_grant(request, {}) end)
  end,

  test_replayed_grant_rejects_foreign_http_origin_and_malformed_artifact = function()
    local request, materials = fixture()
    local ports, artifacts = runtime(request, materials)
    adapter.handle_execution_grant(request, ports)
    artifacts[request.grant_ref].value.http_capabilities[1].origin = "http://127.0.0.1:43110"
    t.raises(function() adapter.handle_execution_grant(request, ports) end)
    artifacts[request.grant_ref] = { value = "bad", digest = digest("b") }
    t.raises(function() adapter.handle_execution_grant(request, ports) end)
  end,

  test_terminal_validates_publication_report_and_cleanup_before_recording = function()
    local request, materials = fixture()
    local ports, _, _, _, recorded = runtime(request, materials)
    local payload = terminal_payload()
    t.eq(adapter.handle_terminal(payload, ports).run_id, payload.run_id)
    t.eq(recorded().run_id, payload.run_id)

    ports = runtime(request, materials, function(artifacts)
      artifacts[payload.aggregate_report_ref].value.status = "failed"
    end)
    t.raises(function() adapter.handle_terminal(payload, ports) end)
    ports = runtime(request, materials, function(artifacts)
      artifacts[payload.cleanup_receipt_ref].value.status = "incomplete"
      artifacts[payload.cleanup_receipt_ref].value.verified_removals = {}
      artifacts[payload.cleanup_receipt_ref].value.remaining_resources = { {
        resource_id = "workspace", resource_kind = "workspace",
        cleanup_ref = { kind = "resource-cleanup", ref = "workspace" },
      } }
      artifacts[payload.cleanup_receipt_ref].value.attempted_resources[1].status = "remaining"
    end)
    t.raises(function() adapter.handle_terminal(payload, ports) end)
  end,

  test_browser_grant_branch_and_binding_are_enforced = function()
    local request, materials = browser_fixture()
    local grant = adapter.derive_execution_grant(request, materials, browser_values())
    t.eq(grant.schema, "testing-runner.ai-browser-control.grant.v1")
    t.eq(grant.reviewed_plan_sha256, request.plan_sha256)
    local ports, artifacts = runtime(request, materials)
    ports.grant_values = function() return browser_values() end
    adapter.handle_execution_grant(request, ports)
    artifacts[request.grant_ref].value.reviewed_plan_sha256 = digest("7")
    t.raises(function() adapter.handle_execution_grant(request, ports) end)
  end,

  test_default_runtime_and_failure_branches_are_covered = function()
    t.raises(function() host_adapter.new({ error_prefix = "" }) end)
    t.raises(function() host_adapter.new({ default_ports = "bad" }) end)
    local request, materials = fixture()
    t.raises(function() adapter.execution_grant_result_event(request, "bad") end)
    local ports = runtime(request, materials)
    t.raises(function() adapter.handle_terminal(terminal_payload()) end)
    local configured_adapter = host_adapter.new({
      error_prefix = "configured-host-adapter-test", default_ports = function() return ports end,
    })
    t.eq(configured_adapter.handle_terminal(terminal_payload()).run_id, "host-adapter-run")

    ports = runtime(request, materials)
    ports.load_artifact = function() return nil end
    t.raises(function() adapter.handle_execution_grant(request, ports) end)
    ports = runtime(request, materials)
    ports.claim_preauthorization = function() return { status = "blocked" } end
    t.raises(function() adapter.handle_execution_grant(request, ports) end)
    ports = runtime(request, materials, function(artifacts)
      artifacts[terminal_payload().aggregate_publication_receipt_ref].value.stage = "intake"
    end)
    t.raises(function() adapter.handle_terminal(terminal_payload(), ports) end)
    ports = runtime(request, materials)
    ports.record_terminal = function() return false end
    t.raises(function() adapter.handle_terminal(terminal_payload(), ports) end)
  end,

  test_valid_and_invalid_public_entrypoints = function()
    local run = workflow_request()
    local event = adapter.qa_run_event(run)
    t.eq(event.queue, "workflow-qa.qa_run_request")
    t.eq(event.payload.run_id, run.run_id)
    t.raises(function() adapter.qa_run_event({}) end)
    local request = fixture()
    t.raises(function() adapter.derive_execution_grant(request, nil, values()) end)
  end,
}
