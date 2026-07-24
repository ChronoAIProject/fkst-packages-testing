local contract = require("contract.workflow_qa")
local browser_contract = require("contract.browser_control")
local checkpoints = require("checkpoints")
local core = require("core")
local workflow_ports = require("ports")
local design_loop = require("testing_ai.module_ai_design_loop")
local execution_contract = require("contract.structured_execution")
local t = fkst.test

local function digest(char) return string.rep(char or "a", 64) end
local function pointer(path) return { kind = "artifact", ref = path } end
local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function expect_failure(fragment, fn)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(fragment, 1, true) ~= nil)
end

local function proposed_case()
  return {
    id = "seed-health", module_id = "api", priority = "P0", title = "Health endpoint",
    objective = "Verify the approved health endpoint.", case_kind = "api",
    actions = { { action = "http", target = "/health", expected = "HTTP 200" } },
    expected_observable = "The service reports healthy.", coverage_subject_ids = { "REQ-HEALTH" },
    review_status = "executable",
  }
end

local function fixture()
  local root = ".testing/runs/workflow-qa-fixture"
  local repository = {
    slug = "owner/repo",
    url = "https://github.com/owner/repo.git",
    commit_sha = string.rep("a", 40),
  }
  local env_root = root .. "/environment"
  local design_root = root .. "/design"
  return {
    schema = contract.schemas.request,
    issue = { repository = repository.slug, number = 100, state = "open", labels = { "fkst-qa" } },
    run_id = "qa-run-100",
    repository = repository,
    artifact_root = root,
    state_ref = root .. "/workflow-state.json",
    proposed_cases = { proposed_case() },
    environment_start = {
      schema = "environment-factory.start.v1",
      operation_id = "qa-run-100",
      repository = { url = repository.url, commit_sha = repository.commit_sha },
      profile_ref = { kind = "host-profile", ref = "profiles/qa" },
      approval_ref = { kind = "approval", ref = "approvals/qa" },
      validation_receipt_ref = pointer(".testing/approvals/qa.json"),
      operation_state_ref = pointer(env_root .. "/operation-state.json"),
      artifact_root = env_root,
      base_url = "http://127.0.0.1:4173/health",
      runtime_ports = { { name = "application", port = 4173 } },
      sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
      trace_id = "trace-qa-100",
      dedup_key = "dedup-qa-100",
    },
    analysis_request = {
      schema = "testing-design.analysis-request.v1",
      repository = {
        url = repository.url,
        commit_sha = repository.commit_sha,
        baseline_commit_sha = string.rep("b", 40),
        workspace_ref = { kind = "workspace", ref = "approved/qa-run-100" },
        approval_ref = pointer(".testing/approvals/repository.json"),
        approval_sha256 = digest("b"),
      },
      inputs = {},
      artifact_root = root .. "/analysis",
      source_ref = { kind = "workflow-qa", ref = "qa-run-100" },
      trace_id = "trace-qa-100",
      dedup_key = "dedup-qa-100",
    },
    design_module_start = {
      schema = "module-testing-pipeline.module-start.v1",
      module = "api",
      no_browser = false,
      dry_run = true,
      artifact_root = design_root,
      source_ref = { kind = "workflow-qa", ref = "qa-run-100" },
      trace_id = "trace-qa-100",
      dedup_key = "dedup-qa-100",
      cdp_execution = {
        schema = "testing-runner.module-cdp-execution.v1",
        ai_design_loop_request = {
          schema = design_loop.schemas.request,
          artifact_root = design_root .. "/loop",
          seed_cases_ref = { artifact_pointer = design_root .. "/placeholder.json", artifact_digest = "placeholder" },
          deterministic_cases_ref = { artifact_pointer = design_root .. "/deterministic.json", artifact_digest = "deterministic" },
          coverage_scope_ref = { artifact_pointer = design_root .. "/coverage.json", artifact_digest = "coverage" },
          max_rounds = 3, case_budget = 16, action_budget = 32,
          trace_id = "trace-qa-100", dedup_key = "dedup-qa-100",
        },
      },
    },
    structured_execution = {
      artifact_root = root .. "/execution",
      preauthorization_ref = root .. "/execution/preauthorization.json",
      preauthorization_sha256 = digest("1"),
      case_catalog_ref = root .. "/execution/case-catalog.json",
      case_catalog_sha256 = digest("2"),
      structured_plan_ref = root .. "/execution/structured-plan.json",
      grant_ref = root .. "/execution/execution-grant.json",
    },
    publication = {
      ledger_ref = root .. "/run-ledger.json",
      defect_ledger_ref = root .. "/execution/defect-ledger.json",
      defect_receipt_ref = root .. "/execution/defect-receipt.json",
      issue_drafts_ref = root .. "/execution/issue-drafts.json",
      aggregate_report_ref = root .. "/aggregate-report.json",
      terminal_summary_ref = root .. "/terminal-summary.json",
    },
    terminal_policy = { mode = "host" },
    trace_id = "trace-qa-100",
    dedup_key = "dedup-qa-100",
  }
end

local function runtime(request)
  local state, version = nil, 0
  local artifacts = {}
  local function put(path, value, sha)
    artifacts[path] = { value = copy(value), digest = sha or digest("d") }
  end
  put(request.structured_execution.preauthorization_ref, {
    schema = execution_contract.schemas.preauthorization,
    authorization_id = "qa-authorization",
    repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
    profile_sha256 = digest("9"),
    case_catalog_sha256 = request.structured_execution.case_catalog_sha256,
    capabilities = { cli = {}, http = { {
      origin = "http://127.0.0.1:4173", methods = { "GET" }, path_prefixes = { "/health" },
    } } },
    authority = { kind = "policy", ref = "qa-policy" }, policy_revision = "policy-v1",
    evidence_ref = { kind = "attestation", ref = "qa-authorization" },
    issued_at = "2026-07-20T00:00:00Z", expires_at = "2026-07-20T01:00:00Z", max_uses = 1,
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }, request.structured_execution.preauthorization_sha256)
  put(request.structured_execution.case_catalog_ref, {
    schema = execution_contract.schemas.case_catalog,
    repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
    cases = { {
      design_case_id = "seed-health", case_id = "health", kind = "http", timeout_seconds = 10,
      request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} },
      assertions = { { type = "status-code", expected = 200 } },
    } },
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }, request.structured_execution.case_catalog_sha256)
  put(request.environment_start.validation_receipt_ref.ref, {
    schema = "testing-project-profile-validation-receipt.v1",
    profile_schema = "testing-project-profile.v1", profile_revision = "qa-profile-v1",
    canonicalization = "fkst-project-profile-canonical-json.v1", profile_sha256 = digest("9"),
    repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
    approval_ref = copy(request.environment_start.approval_ref), approval_id = "qa-approval",
    approval_sha256 = digest("7"), authority = { kind = "policy", ref = "qa-policy" },
    policy_revision = "policy-v1", evidence_ref = { kind = "attestation", ref = "qa-approval" },
    issued_at = "2026-07-20T00:00:00Z", trace_id = request.trace_id, dedup_key = request.dedup_key,
  }, digest("6"))
  local ports = {
    load_state = function() return state end,
    load_run = function(trace_id, dedup_key)
      if trace_id == request.trace_id and dedup_key == request.dedup_key then return request end
    end,
    load_run_by_id = function(run_id) if run_id == request.run_id then return request end end,
    list_pending_runs = function() return { request } end,
    save_state = function(_, value, expected)
      if expected ~= version then return false end
      state = copy(value)
      version = value.version
      return true
    end,
    load_artifact = function(path) return artifacts[path] end,
    write_artifact = function(path, value) put(path, value) return true end,
    artifact_digest = function(path)
      if artifacts[path] == nil then put(path, { external = path }) end
      return artifacts[path].digest
    end,
  }
  return ports, function() return state end, put, artifacts
end

local function readiness(request)
  local root = request.environment_start.artifact_root
  local operation_state_ref = request.environment_start.operation_state_ref
  local sessions = request.environment_start.sessions
  return {
    schema = "browser-readiness.result.v1",
    status = "ready",
    sessions = {
      { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
      { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } }, cdp_url = sessions[1].cdp_url },
    },
    source_ref = copy(operation_state_ref),
    request_context = { dry_run = false },
    correlation = {
      schema = "environment-factory.browser-readiness-correlation.v1",
      attempt_id = "attempt-1",
      operation_id = request.run_id,
      operation_state_ref = copy(operation_state_ref),
      readiness_attempt_ref = pointer(root .. "/readiness-attempts/attempt-1.json"),
      readiness_attempt_sha256 = digest("4"),
      base_url = request.environment_start.base_url,
      sessions = copy(sessions),
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    },
  }
end

local function workflow_readiness_result(request)
  local result = readiness(request)
  result.source_ref = { kind = "workflow-qa", ref = request.run_id }
  result.request_context = {
    dry_run = request.design_module_start.dry_run == true,
    no_browser = request.design_module_start.no_browser == true,
  }
  return result
end

local function ready_receipt(request)
  return {
    schema = "environment-factory.receipt.v2",
    operation_id = request.run_id,
    status = "ready",
    profile_revision = "qa-profile-v1",
    profile_sha256 = digest("9"),
    repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
    workspace_ref = { kind = "workspace", ref = "qa-run-100-workspace" },
    base_url = request.environment_start.base_url,
    runtime_ports = copy(request.environment_start.runtime_ports),
    sessions = copy(request.environment_start.sessions),
    browser_readiness = readiness(request),
    artifact_root = request.environment_start.artifact_root,
    diagnostic_refs = {},
    cleanup_ref = { kind = "environment-cleanup", ref = request.run_id },
    cleanup_status = "pending",
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
end

local function ready_result(request, put)
  local ref = request.environment_start.artifact_root .. "/environment-receipt-ready.json"
  put(ref, ready_receipt(request), digest("3"))
  return {
    schema = "environment-factory.result.v1",
    operation_id = request.run_id,
    status = "ready",
    environment_receipt_ref = pointer(ref),
    cleanup_ref = { kind = "environment-cleanup", ref = request.run_id },
    diagnostic_refs = {}, cleanup_status = "pending",
    source_ref = copy(request.environment_start.operation_state_ref),
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
end

local function analysis_result(request)
  local root = request.analysis_request.artifact_root
  local function ref(schema, name, char)
    return {
      schema = "testing-design.artifact-reference.v1", artifact_schema = schema,
      artifact_pointer = root .. "/" .. name, artifact_digest = digest(char),
    }
  end
  return {
    schema = "testing-design.analysis-result.v1", status = "complete", replayed = false,
    analysis_key = digest("4"),
    context = {
      schema = "testing-design.context-reference.v1", analysis_key = digest("4"),
      repository_analysis = ref("testing-design.repository-analysis.v1", "repository-analysis.v1.json", "5"),
      requirements_index = ref("testing-design.requirements-index.v1", "requirements-index.v1.json", "6"),
      traceability_seed = ref("testing-design.traceability-seed.v1", "traceability-seed.v1.json", "7"),
    },
    source_ref = { kind = "workflow-qa", ref = request.run_id },
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
end

local function module_terminal(request, put)
  local plan_ref = request.design_module_start.artifact_root .. "/test-plan.json"
  put(plan_ref, { schema = "testing-runner.module-test-plan.v1", modules = {} }, digest("8"))
  return {
    schema = "module-test-loop.terminal.v1",
    status = "passed", attempt = 1, max_attempts = 1,
    runner_result = {
      schema = "testing-runner.result.v1", job = "module-test-loop", status = "passed",
      artifact_root = request.design_module_start.artifact_root,
      source_ref = { kind = "module-test-loop-attempt", ref = request.artifact_root .. "/module-loop-state.json" },
      trace_id = request.trace_id, dedup_key = request.dedup_key .. "/attempt/1",
      native_summary = { ["test_" .. "plan_path"] = plan_ref },
    },
    module_plan_ref = plan_ref,
    module_plan_sha256 = digest("8"),
    state_ref = request.artifact_root .. "/module-loop-state.json",
    source_ref = { kind = "workflow-qa", ref = request.run_id },
    trace_id = request.trace_id, dedup_key = request.dedup_key .. "/terminal",
  }
end

local function plan_result(request, put, execution_mode)
  execution_mode = execution_mode or "structured-api-cli"
  local cases = execution_mode == "agentic-browser" and { {
    case_id = "browser-login", kind = "browser", goal = "Authenticate the existing user.",
    success_conditions = { "Exact loopback callback", "Authenticated CLI status" },
  } } or { {
    case_id = "health", kind = "http", timeout_seconds = 10,
    request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} },
    assertions = { { type = "status-code", expected = 200 } },
  } }
  put(request.structured_execution.structured_plan_ref, {
    schema = execution_contract.schemas.plan,
    execution_mode = execution_mode,
    repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
    environment_receipt_sha256 = digest("3"),
    browser_readiness_sha256 = digest("d"),
    case_catalog_sha256 = request.structured_execution.case_catalog_sha256,
    module_plan_sha256 = digest("8"), cases = cases, residual_risk_case_ids = {},
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }, digest("a"))
  return {
    schema = execution_contract.schemas.plan_result,
    status = "compiled",
    plan_ref = request.structured_execution.structured_plan_ref,
    plan_sha256 = digest("a"), residual_risk_count = 0,
    source_ref = { kind = "workflow-qa", ref = request.run_id },
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
end

local function grant_result(request, put, execution_mode)
  execution_mode = execution_mode or "structured-api-cli"
  local grant
  if execution_mode == "agentic-browser" then
    grant = {
      schema = browser_contract.schemas.grant,
      grant_id = "browser-grant",
      parent_authorization_sha256 = request.structured_execution.preauthorization_sha256,
      repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
      environment_receipt_sha256 = digest("3"), readiness_attempt_id = "attempt-1",
      readiness_attempt_sha256 = digest("4"), target_id = "target-1", target_sha256 = digest("5"),
      reviewed_plan_sha256 = digest("a"), allowed_auth_origins = { "https://auth.example.test" },
      callback = { origin = "http://127.0.0.1:43119", path = "/callback" },
      allowed_actions = { "click", "type", "submit", "press_tab", "finish" },
      approved_secret_refs = { "primary-identity", "primary-secret" },
      step_budget = 4, time_budget_seconds = 120,
      authority = { kind = "policy", ref = "browser-policy" }, policy_revision = "policy-v1",
      evidence_ref = { kind = "attestation", ref = "browser-grant" },
      issued_at = "2026-07-20T00:00:00Z", expires_at = "2026-07-20T01:00:00Z", max_uses = 1,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }
  else
    grant = {
      schema = execution_contract.schemas.grant, grant_id = "structured-grant",
      parent_authorization_sha256 = request.structured_execution.preauthorization_sha256,
      plan_sha256 = digest("a"), environment_receipt_sha256 = digest("3"),
      repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
      cli_capabilities = {}, http_capabilities = { {
        origin = "http://127.0.0.1:4173", methods = { "GET" }, path_prefixes = { "/health" },
      } },
      authority = { kind = "policy", ref = "structured-policy" }, policy_revision = "policy-v1",
      evidence_ref = { kind = "attestation", ref = "structured-grant" },
      issued_at = "2026-07-20T00:00:00Z", expires_at = "2026-07-20T01:00:00Z", max_uses = 1,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }
  end
  put(request.structured_execution.grant_ref, grant, digest("b"))
  return {
    schema = execution_contract.schemas.grant_result, status = "granted",
    grant_ref = request.structured_execution.grant_ref, grant_sha256 = digest("b"),
    source_ref = { kind = "workflow-qa", ref = request.run_id },
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
end

local function execution_result(request, failures)
  local root = request.structured_execution.artifact_root
  return {
    schema = "testing-runner.result.v1", job = "structured-execution",
    status = failures > 0 and "failed" or "passed",
    artifact_root = root,
    source_ref = { kind = "workflow-qa", ref = request.run_id },
    trace_id = request.trace_id, dedup_key = request.dedup_key,
    native_summary = {
      ["test_" .. "plan_path"] = root .. "/test-plan.json",
      execution_path = root .. "/execution.json",
      case_results_path = root .. "/case-results.json",
      case_count = 2, passed_count = 2 - failures, failed_count = failures,
      skipped_count = 0, error_count = 0,
    },
  }
end

local function artifact_summary(request, failures, put)
  local result = execution_result(request, failures)
  put(result.native_summary.case_results_path, {
    schema = "testing-structured-case-results.v1",
    plan_sha256 = digest("a"), cases = {},
  }, digest("c"))
  return {
    schema = "test-artifacts.summary.v1",
    job = "structured-execution",
    status = result.status,
    artifact_root = result.artifact_root,
    metadata_path = result.artifact_root .. "/metadata.json",
    source_ref = copy(result.source_ref),
    trace_id = result.trace_id, dedup_key = result.dedup_key,
    native_summary = copy(result.native_summary),
  }
end

local function finalized(request, put)
  local cleanup_ref = request.environment_start.artifact_root .. "/cleanup-receipt-complete.json"
  put(cleanup_ref, { schema = "environment-factory.cleanup-receipt.v1" }, digest("e"))
  return {
    schema = "environment-factory.result.v1", operation_id = request.run_id, status = "finalized",
    environment_receipt_ref = pointer(request.environment_start.artifact_root .. "/environment-receipt-finalized.json"),
    cleanup_receipt_ref = pointer(cleanup_ref),
    cleanup_ref = { kind = "environment-cleanup", ref = request.run_id },
    diagnostic_refs = {}, cleanup_status = "complete",
    source_ref = copy(request.environment_start.operation_state_ref),
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
end

local function checkpoint_receipt(request, pending)
  return {
    schema = "test-publication.qa-publication-receipt.v2",
    status = "published",
    repository = { slug = request.repository.slug, commit_sha = request.repository.commit_sha },
    run_id = request.run_id,
    stage = pending.stage,
    attempt = pending.attempt,
    comment_id = "comment-" .. pending.stage .. "-" .. tostring(pending.attempt),
    remote_url = "https://github.com/" .. request.repository.slug .. "/blob/"
      .. request.repository.commit_sha .. "/qa/" .. pending.stage .. ".json",
    artifact_sha256 = pending.artifact_sha256,
    source_commit = request.repository.commit_sha,
    receipt_ref = pending.receipt_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    request_dedup_key = pending.request_dedup_key,
  }
end

local function release_checkpoint(request, ports, state, expected_queue)
  local pending = state().active_checkpoint
  t.is_true(type(pending) == "table")
  local receipt = checkpoint_receipt(request, pending)
  t.eq(ports.write_artifact(receipt.receipt_ref, receipt), true)
  local actions = core.handle_publication_receipt(receipt, request, ports)
  if expected_queue ~= nil then t.eq(actions[1].queue, expected_queue) end
  return actions
end

local function drive_to_browser_pending(request, ports, state, put)
  core.start(request, ports)
  release_checkpoint(request, ports, state, "environment-factory.environment_start")
  core.handle_environment_result(ready_result(request, put), request, ports)
  release_checkpoint(request, ports, state, "testing-design.analysis_request")
  core.handle_analysis_result(analysis_result(request), request, ports)
  return release_checkpoint(request, ports, state, "browser-readiness.browser_readiness_check")
end

local function drive_to_grant(request, ports, state, put, execution_mode)
  local intake = core.start(request, ports)
  t.eq(intake[1].queue, "test-publication.qa_checkpoint_request")
  release_checkpoint(request, ports, state, "environment-factory.environment_start")

  local environment = core.handle_environment_result(ready_result(request, put), request, ports)
  t.eq(environment[1].queue, "test-publication.qa_checkpoint_request")
  release_checkpoint(request, ports, state, "testing-design.analysis_request")

  local design = core.handle_analysis_result(analysis_result(request), request, ports)
  t.eq(design[1].queue, "test-publication.qa_checkpoint_request")
  local readiness = release_checkpoint(request, ports, state, "browser-readiness.browser_readiness_check")
  t.eq(readiness[1].payload.source_ref.kind, "workflow-qa")

  local browser = core.handle_browser_readiness_result(workflow_readiness_result(request), request, ports)
  t.eq(browser[1].queue, "test-publication.qa_checkpoint_request")
  local module = release_checkpoint(request, ports, state, "module-testing-pipeline.module_start")
  t.eq(module[1].payload.preflight_result.status, "ready")

  local closure = core.handle_module_terminal(module_terminal(request, put), request, ports)
  t.eq(closure[1].queue, "test-publication.qa_checkpoint_request")
  release_checkpoint(request, ports, state, "testing-runner.structured_plan_request")

  local grant = core.handle_plan_result(plan_result(request, put, execution_mode), request, ports)
  t.eq(grant[1].queue, "workflow_qa_execution_grant_request")
  t.eq(grant[1].payload.execution_mode, execution_mode or "structured-api-cli")
  return core.handle_grant_result(grant_result(request, put, execution_mode), request, ports)
end

local tests = {
  test_run_traverses_plan_grant_execution_cleanup_and_terminal = function()
    local request = fixture()
    request.publication.channel = "filesystem-dry-run-v1"
    local ports, state, put = runtime(request)
    local execution = drive_to_grant(request, ports, state, put)
    t.eq(execution[1].queue, "testing-runner.structured_execution_request")
    t.eq(state().phase, "structured-execution-pending")
    local summarize = core.handle_execution_result(execution_result(request, 0), request, ports)
    t.eq(summarize[1].queue, "test-artifacts.testing_result")
    local execution_checkpoint = core.handle_artifact_summary(artifact_summary(request, 0, put), request, ports)
    t.eq(execution_checkpoint[1].queue, "test-publication.qa_checkpoint_request")
    release_checkpoint(request, ports, state, "environment-factory.environment_finalize")
    local cleanup_checkpoint = core.handle_cleanup_result(finalized(request, put), request, ports)
    t.eq(cleanup_checkpoint[1].queue, "test-publication.qa_checkpoint_request")
    t.eq(cleanup_checkpoint[1].payload.channel, "filesystem-dry-run-v1")
    local finalization = release_checkpoint(request, ports, state, "test-publication.qa_finalize_request")
    t.eq(finalization[1].payload.channel, "filesystem-dry-run-v1")
    t.eq(state().request.publication.channel, "filesystem-dry-run-v1")
    put(request.publication.aggregate_report_ref, {
      schema = "test-publication.qa-aggregate-report.v1", run_id = request.run_id,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }, digest("f"))
    local aggregate = checkpoints.aggregate_expectation(state(), digest("f"))
    local aggregate_receipt = checkpoint_receipt(request, aggregate)
    t.eq(ports.write_artifact(aggregate_receipt.receipt_ref, aggregate_receipt), true)
    local terminal = core.handle_publication_receipt(aggregate_receipt, request, ports)
    t.eq(terminal[1].queue, "workflow_qa_terminal_request")
    t.eq(state().phase, "terminal")
  end,

  test_agentic_browser_plan_routes_only_to_browser_controller = function()
    local request = fixture()
    local ports, state, put = runtime(request)
    local execution = drive_to_grant(request, ports, state, put, "agentic-browser")
    t.eq(execution[1].queue, "testing-runner.ai_browser_control_request")
    t.eq(execution[1].payload.schema, browser_contract.schemas.request)
    t.eq(state().phase, "browser-control-pending")
    t.eq(state().execution_job, "ai-browser-control")
  end,

  test_failed_cases_wait_for_defect_preparation_and_terminal_receipt = function()
    local request = fixture()
    local ports, state, put = runtime(request)
    drive_to_grant(request, ports, state, put)
    core.handle_execution_result(execution_result(request, 1), request, ports)
    local execution_checkpoint = core.handle_artifact_summary(artifact_summary(request, 1, put), request, ports)
    t.eq(execution_checkpoint[1].queue, "test-publication.qa_checkpoint_request")
    release_checkpoint(request, ports, state, "test-publication.defect_preparation_request")
    t.eq(state().phase, "defects-pending")
    local defect_checkpoint = core.handle_defect_terminal({
      schema = "test-publication.defect-publication-terminal.v1", status = "published",
      receipt_ref = request.publication.defect_receipt_ref,
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }, request, ports)
    t.eq(defect_checkpoint[1].queue, "test-publication.qa_checkpoint_request")
    release_checkpoint(request, ports, state, "environment-factory.environment_finalize")
  end,

  test_plan_and_grant_redelivery_are_idempotent = function()
    local request = fixture()
    local ports, state, put = runtime(request)
    core.start(request, ports)
    release_checkpoint(request, ports, state, "environment-factory.environment_start")
    core.handle_environment_result(ready_result(request, put), request, ports)
    release_checkpoint(request, ports, state, "testing-design.analysis_request")
    core.handle_analysis_result(analysis_result(request), request, ports)
    release_checkpoint(request, ports, state, "browser-readiness.browser_readiness_check")
    core.handle_browser_readiness_result(workflow_readiness_result(request), request, ports)
    release_checkpoint(request, ports, state, "module-testing-pipeline.module_start")
    core.handle_module_terminal(module_terminal(request, put), request, ports)
    release_checkpoint(request, ports, state, "testing-runner.structured_plan_request")
    local first = core.handle_plan_result(plan_result(request, put), request, ports)
    local second = core.handle_plan_result(plan_result(request, put), request, ports)
    t.eq(second[1].queue, first[1].queue)
    core.handle_grant_result(grant_result(request, put), request, ports)
    local replay = core.handle_grant_result(grant_result(request, put), request, ports)
    t.eq(replay[1].queue, "testing-runner.structured_execution_request")
    t.eq(state().phase, "structured-execution-pending")
  end,

  test_claim_and_closed_identity_fail_closed = function()
    local request = fixture()
    request.issue.labels = { "fkst-dev:enabled" }
    t.raises(function() contract.validate_request(request) end)
    request = fixture()
    request.issue.state = "closed"
    t.raises(function() contract.validate_request(request) end)
    request = fixture()
    request.environment_start.repository.commit_sha = string.rep("c", 40)
    t.raises(function() contract.validate_request(request) end)
  end,

  test_contract_rejects_malformed_closed_inputs = function()
    local mutations = {
      function(value) value.repository.url = "https://user@example.invalid/repo.git" end,
      function(value) value.proposed_cases = {} end,
      function(value) value.proposed_cases[1].actions[1].extra = true end,
      function(value) value.proposed_cases[1].actions[1].action = nil end,
      function(value) value.proposed_cases[1].actions[1].target_module_id = "" end,
      function(value) value.proposed_cases[1].actions[1].evidence_pointer = "/tmp/evidence.json" end,
      function(value) value.proposed_cases[1].id = nil end,
      function(value) value.proposed_cases[1].review_status = "approved" end,
      function(value) value.run_id = "" end,
      function(value) value.state_ref = value.artifact_root .. "/other.json" end,
      function(value) value.analysis_request.trace_id = "foreign" end,
      function(value) value.design_module_start.source_ref.ref = "foreign" end,
      function(value) value.structured_execution.grant_ref = ".testing/runs/foreign/grant.json" end,
      function(value) value.publication.aggregate_report_ref = ".testing/runs/foreign/report.json" end,
      function(value) value.publication.channel = "email-v1" end,
      function(value) value.terminal_policy.mode = "package" end,
    }
    for _, mutate in ipairs(mutations) do
      local value = fixture()
      mutate(value)
      expect_failure("contract.workflow-qa:", function() contract.validate_request(value) end)
    end
    expect_failure("malformed-interruption", function()
      contract.validate_interrupt({
        schema = contract.schemas.interrupt,
        interruption = "stop",
        trace_id = "trace",
        dedup_key = "dedup",
      })
    end)
  end,

  test_terminal_contract_accepts_complete_handoff_and_rejects_mutations = function()
    local request = fixture()
    local terminal = {
      schema = contract.schemas.terminal,
      repository = request.repository.slug,
      issue_number = request.issue.number,
      run_id = request.run_id,
      status = "passed",
      counts = { planned = 1, executed = 1, passed = 1, failed = 0, skipped = 0, error = 0, blocked = 0 },
      artifact_root = request.artifact_root,
      aggregate_report_ref = request.publication.aggregate_report_ref,
      aggregate_report_sha256 = digest("a"),
      aggregate_publication_receipt_ref = request.artifact_root .. "/publication/aggregate-receipt.json",
      aggregate_publication_receipt_sha256 = digest("b"),
      cleanup_receipt_ref = request.artifact_root .. "/environment/cleanup-receipt.json",
      cleanup_receipt_sha256 = digest("c"),
      terminal_policy = "host",
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    }
    t.eq(contract.validate_terminal(terminal), terminal)

    local mutations = {
      function(value) value.status = "unknown" end,
      function(value) value.counts.failed = -1 end,
      function(value) value.aggregate_report_ref = ".testing/runs/foreign/report.json" end,
      function(value) value.cleanup_receipt_sha256 = "bad" end,
    }
    for _, mutate in ipairs(mutations) do
      local value = copy(terminal)
      mutate(value)
      expect_failure("malformed-terminal", function() contract.validate_terminal(value) end)
    end
  end,

  test_checkpoint_lease_rejects_overlap_and_foreign_receipts = function()
    local request = fixture()
    local ref = request.artifact_root .. "/checkpoint.json"
    local state = {
      request = request,
      phase = "testing",
      digests = { [ref] = digest("d") },
    }
    checkpoints.gate(state, "coverage", "passed", ref, nil, "next", {})
    expect_failure("checkpoint-already-pending", function()
      checkpoints.gate(state, "other", "passed", ref, nil, "next", {})
    end)
    local persisted = {}
    local checkpoint_ports = {
      load_artifact = function(ref) return persisted[ref] end,
    }
    expect_failure("foreign-checkpoint-receipt", function()
      checkpoints.release(state, { stage = "foreign" }, checkpoint_ports)
    end)
    local receipt = checkpoint_receipt(request, state.active_checkpoint)
    persisted[receipt.receipt_ref] = { value = {}, digest = digest("f") }
    expect_failure("checkpoint-receipt-unavailable", function()
      checkpoints.release(state, receipt, checkpoint_ports)
    end)
    persisted[receipt.receipt_ref] = { value = copy(receipt), digest = digest("f") }
    local actions = checkpoints.release(state, receipt, checkpoint_ports)
    t.eq(#actions, 0)
    t.eq(state.phase, "next")
    t.eq(checkpoints.release(state, {}, checkpoint_ports), nil)
  end,

  test_start_fails_closed_at_authorization_and_storage_boundaries = function()
    do
      local request = fixture()
      local ports = runtime(request)
      ports.artifact_digest = function() return "bad" end
      expect_failure("artifact-digest-unavailable", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports, _, _, artifacts = runtime(request)
      artifacts[request.structured_execution.preauthorization_ref] = nil
      expect_failure("artifact-binding-unavailable", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports, _, _, artifacts = runtime(request)
      artifacts[request.environment_start.validation_receipt_ref.ref] = nil
      expect_failure("validation-receipt-unavailable", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports = runtime(request)
      ports.save_state = function() return false end
      expect_failure("state-save-conflict", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports = runtime(request)
      ports.write_artifact = function() return false end
      expect_failure("intake-artifact-write-failed", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports, _, _, artifacts = runtime(request)
      core.start(request, ports)
      artifacts[request.structured_execution.preauthorization_ref].value.profile_sha256 = digest("8")
      artifacts[request.environment_start.validation_receipt_ref.ref].value.profile_sha256 = digest("8")
      expect_failure("authorization-binding-changed", function() core.start(request, ports) end)
    end
  end,

  test_environment_and_browser_results_enforce_owned_bindings = function()
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      core.start(request, ports)
      release_checkpoint(request, ports, state, "environment-factory.environment_start")
      local result = ready_result(request, put)
      result.operation_id = "foreign"
      expect_failure("foreign-environment-result", function()
        core.handle_environment_result(result, request, ports)
      end)
    end
    do
      local request = fixture()
      local ports, state, put, artifacts = runtime(request)
      core.start(request, ports)
      release_checkpoint(request, ports, state, "environment-factory.environment_start")
      local result = ready_result(request, put)
      artifacts[result.environment_receipt_ref.ref].value.repository.commit_sha = string.rep("c", 40)
      expect_failure("environment-readiness-unverified", function()
        core.handle_environment_result(result, request, ports)
      end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_browser_pending(request, ports, state, put)
      local result = workflow_readiness_result(request)
      result.correlation.attempt_id = "foreign"
      expect_failure("foreign-browser-readiness-result", function()
        core.handle_browser_readiness_result(result, request, ports)
      end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_browser_pending(request, ports, state, put)
      local result = workflow_readiness_result(request)
      result.status = "blocked"
      for _, session in ipairs(result.sessions) do session.status = "blocked" end
      local cleanup = core.handle_browser_readiness_result(result, request, ports)
      t.eq(cleanup[1].queue, "environment-factory.environment_finalize")
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_browser_pending(request, ports, state, put)
      local original = ports.write_artifact
      ports.write_artifact = function(path, value)
        if path == request.artifact_root .. "/browser-readiness.json" then return false end
        return original(path, value)
      end
      expect_failure("browser-readiness-write-failed", function()
        core.handle_browser_readiness_result(workflow_readiness_result(request), request, ports)
      end)
    end
  end,

  test_interrupt_and_redrive_respect_durable_phase = function()
    local request = fixture()
    local ports, state = runtime(request)
    core.start(request, ports)
    release_checkpoint(request, ports, state, "environment-factory.environment_start")
    local pending = core.handle_interrupt({
      schema = contract.schemas.interrupt,
      interruption = "timed-out",
      trace_id = request.trace_id,
      dedup_key = request.dedup_key,
    }, ports)
    t.eq(pending[1].queue, "environment-factory.environment_start")
    t.eq(state().interruption_requested, "timed-out")

    local replay = core.redrive({ limit = 1 }, ports)
    t.eq(replay[1].queue, "environment-factory.environment_start")
    for _, limit in ipairs({ 0, 65, 1.5 }) do
      expect_failure("malformed-redrive", function() core.redrive({ limit = limit }, ports) end)
    end
    local original_list = ports.list_pending_runs
    ports.list_pending_runs = function() return "invalid" end
    expect_failure("redrive-unavailable", function() core.redrive({}, ports) end)
    ports.list_pending_runs = original_list
    state().phase = "terminal"
    t.eq(#core.redrive({}, ports), 0)
  end,

  test_production_ports_require_and_return_host_runtime = function()
    local request = fixture()
    local ports = runtime(request)
    local previous = _G.workflow_qa_runtime
    _G.workflow_qa_runtime = ports
    t.eq(workflow_ports.production(), ports)
    _G.workflow_qa_runtime = {}
    expect_failure("runtime-port-unavailable", function() workflow_ports.production() end)
    _G.workflow_qa_runtime = previous
  end,

  test_cancelled_run_uses_owned_environment_interrupt_path = function()
    local request = fixture()
    local ports, state, put = runtime(request)
    core.start(request, ports)
    release_checkpoint(request, ports, state, "environment-factory.environment_start")
    core.handle_environment_result(ready_result(request, put), request, ports)
    local actions = core.handle_interrupt({
      schema = contract.schemas.interrupt, interruption = "cancelled",
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }, ports)
    t.eq(actions[1].queue, "environment-factory.environment_interrupt")
    t.eq(actions[1].payload.interruption, "cancelled")
  end,

  test_replay_and_identity_boundaries_fail_closed = function()
    do
      local request = fixture()
      local ports, state = runtime(request)
      local first = core.start(request, ports)
      local replay = core.start(request, ports)
      t.eq(replay[1].queue, first[1].queue)
      state().request.run_id = "foreign"
      expect_failure("foreign-state", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports, _, _, artifacts = runtime(request)
      artifacts[request.environment_start.validation_receipt_ref.ref].value.trace_id = "foreign"
      expect_failure("authorization-binding-mismatch", function() core.start(request, ports) end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      local result = execution_result(request, 0)
      result.job = "foreign"
      expect_failure("foreign-execution-result", function() core.handle_execution_result(result, nil, ports) end)
      result = execution_result(request, 0)
      result.source_ref.ref = "foreign"
      expect_failure("foreign-result", function() core.handle_execution_result(result, request, ports) end)
    end
  end,

  test_environment_event_routes_ready_and_cleanup_results = function()
    local request = fixture()
    local ports, state, put = runtime(request)
    core.start(request, ports)
    release_checkpoint(request, ports, state, "environment-factory.environment_start")
    local ready = core.handle_environment_event(ready_result(request, put), ports)
    t.eq(ready[1].queue, "test-publication.qa_checkpoint_request")
    release_checkpoint(request, ports, state, "testing-design.analysis_request")
    state().phase = "cleanup-pending"
    state().environment_result = ready_result(request, put)
    state().environment_result.status = "ready"
    local cleanup = core.handle_environment_event(finalized(request, put), ports)
    t.eq(cleanup[1].queue, "test-publication.qa_checkpoint_request")
    t.eq(#core.saga_conformance_errors(), 0)
  end,

  test_terminal_handlers_reject_foreign_bindings = function()
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      local result = execution_result(request, 0)
      result.job = "foreign"
      expect_failure("foreign-execution-result", function() core.handle_execution_result(result, request, ports) end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      core.handle_execution_result(execution_result(request, 0), request, ports)
      local summary = artifact_summary(request, 0, put)
      summary.artifact_root = request.artifact_root
      expect_failure("foreign-artifact-summary", function() core.handle_artifact_summary(summary, request, ports) end)
    end
    do
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_grant(request, ports, state, put)
      core.handle_execution_result(execution_result(request, 1), request, ports)
      core.handle_artifact_summary(artifact_summary(request, 1, put), request, ports)
      release_checkpoint(request, ports, state, "test-publication.defect_preparation_request")
      local payload = {
        schema = "test-publication.defect-publication-terminal.v1", status = "published",
        receipt_ref = "foreign", trace_id = request.trace_id, dedup_key = request.dedup_key,
      }
      expect_failure("receipt pointer differs", function() core.handle_defect_terminal(payload, request, ports) end)
      payload.schema = "foreign"
      expect_failure("publication receipt binding differs", function() core.handle_defect_terminal(payload, request, ports) end)
    end
  end,

  test_module_plan_and_grant_blocked_paths_begin_owned_cleanup = function()
    local function module_pending()
      local request = fixture()
      local ports, state, put = runtime(request)
      drive_to_browser_pending(request, ports, state, put)
      core.handle_browser_readiness_result(workflow_readiness_result(request), request, ports)
      release_checkpoint(request, ports, state, "module-testing-pipeline.module_start")
      return request, ports, state, put
    end

    do
      local request, ports, _, put = module_pending()
      local payload = module_terminal(request, put)
      payload.runner_result.schema = "foreign"
      expect_failure("runner result is invalid", function() core.handle_module_terminal(payload, request, ports) end)
    end
    do
      local request, ports, state, put = module_pending()
      local payload = module_terminal(request, put)
      payload.runner_result.status = "blocked"
      local actions = core.handle_module_terminal(payload, request, ports)
      t.eq(actions[1].queue, "environment-factory.environment_finalize")
      t.eq(state().phase, "cleanup-pending")
    end
    do
      local request, ports, _, put = module_pending()
      local payload = module_terminal(request, put)
      payload.module_plan_sha256 = digest("0")
      expect_failure("module plan digest differs", function() core.handle_module_terminal(payload, request, ports) end)
    end
    do
      local request, ports, state, put = module_pending()
      core.handle_module_terminal(module_terminal(request, put), request, ports)
      release_checkpoint(request, ports, state, "testing-runner.structured_plan_request")
      local blocked = plan_result(request, put)
      blocked.status = "blocked"
      blocked.plan_ref = nil
      blocked.plan_sha256 = nil
      blocked.failure_class = "plan-compilation-failed"
      local actions = core.handle_plan_result(blocked, request, ports)
      t.eq(actions[1].queue, "environment-factory.environment_finalize")
    end
    do
      local request, ports, state, put = module_pending()
      core.handle_module_terminal(module_terminal(request, put), request, ports)
      release_checkpoint(request, ports, state, "testing-runner.structured_plan_request")
      local result = plan_result(request, put)
      state().phase = "structured-plan-pending"
      local original = ports.load_artifact
      ports.load_artifact = function(path)
        local artifact = original(path)
        if path == result.plan_ref then artifact.value.repository.commit_sha = string.rep("c", 40) end
        return artifact
      end
      expect_failure("compiled plan binding differs", function() core.handle_plan_result(result, request, ports) end)
    end
  end,

}

local workflow_core_coverage_cases = require("tests.workflow_core_coverage_helpers").build({
  artifact_summary = artifact_summary, checkpoint_receipt = checkpoint_receipt, checkpoints = checkpoints,
  contract = contract, core = core, digest = digest, drive_to_grant = drive_to_grant,
  execution_result = execution_result, expect_failure = expect_failure, finalized = finalized, fixture = fixture,
  grant_result = grant_result, pointer = pointer, ready_result = ready_result,
  release_checkpoint = release_checkpoint, runtime = runtime, t = t,
})
tests.test_blocked_environment_summary_cleanup_and_publication_fail_closed =
  workflow_core_coverage_cases.blocked_environment_summary_cleanup_and_publication_fail_closed
tests.test_remaining_workflow_identity_grant_and_publication_boundaries =
  workflow_core_coverage_cases.remaining_workflow_identity_grant_and_publication_boundaries

return tests
