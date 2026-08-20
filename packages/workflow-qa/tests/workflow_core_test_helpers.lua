local M = {}

function M.build(deps)
  local browser_contract = deps.browser_contract
  local contract = deps.contract
  local design_loop = deps.design_loop
  local execution_contract = deps.execution_contract
  local t = deps.t

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
        },
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
    put(request.environment_start.profile_ref.ref, {
      schema = "testing-project-profile.v1", revision = "qa-profile-v1",
      repository = { url = request.repository.url, commit_sha = request.repository.commit_sha },
      working_directory = ".",
      commands = { install = { "fixture", "install" }, build = { "fixture", "build" },
        start = { "fixture", "start" }, cleanup = { "fixture", "cleanup" } },
      application_listener_mode = "fkst-inherited-listeners-v1",
      readiness_checks = { { type = "http", url = "http://127.0.0.1:4173/health", expected_status = 200 } },
      allowed_origins = { "http://127.0.0.1:4173" }, mutation_policy = { mode = "read-only" },
      timeouts = { install_seconds = 10, build_seconds = 10, migrate_seconds = 10,
        seed_seconds = 10, start_seconds = 10, readiness_seconds = 10,
        cleanup_seconds = 10, total_seconds = 60, receipt_ttl_seconds = 60 },
      resource_budgets = { cpu_millis = 1000, memory_mb = 256, disk_mb = 128,
        processes = 4, network_requests = 16, output_bytes = 32768 },
    }, digest("9"))
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
      completion_assertions = {
        { assertion_id = "callback-observed", type = "browser-callback-observed", required = true, completion_field = "callback_observed" },
        { assertion_id = "process-exit-zero", type = "browser-process-exit-zero", required = true, completion_field = "process_exit_zero" },
        { assertion_id = "whoami-succeeded", type = "browser-whoami-succeeded", required = true, completion_field = "whoami_succeeded" },
        { assertion_id = "status-authenticated", type = "browser-status-authenticated", required = true, completion_field = "status_authenticated" },
      },
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
        schema = "testing-runner.structured-execution-summary.v1",
        ["test_" .. "plan_path"] = root .. "/test-plan.json",
        execution_path = root .. "/execution.json",
        case_results_path = root .. "/case-results.json",
        case_count = 2, passed_count = 2 - failures, failed_count = failures,
        skipped_count = 0, error_count = 0,
      },
    }
  end

  local function artifact_summary(request, failures, put, canonical)
    local result = execution_result(request, failures)
    put(result.native_summary.case_results_path, {
      schema = "testing-structured-case-results.v1",
      plan_sha256 = digest("a"), cases = {},
    }, digest("c"))
    if canonical then
      local root = result.artifact_root
      put(result.native_summary.test_plan_path, { schema = execution_contract.schemas.plan }, digest("a"))
      result.native_summary.case_result_set_path = root .. "/case-result-set.json"
      result.native_summary.case_result_set_artifact_sha256 = digest("4")
      result.native_summary.evidence_manifest_path = root .. "/evidence-manifest.json"
      result.native_summary.evidence_manifest_artifact_sha256 = digest("5")
      put(result.native_summary.case_result_set_path, { schema = "testing.case-result-set.v1" }, digest("4"))
      put(result.native_summary.evidence_manifest_path, { schema = "testing.evidence-manifest.v1" }, digest("5"))
    end
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

  return {
    analysis_result = analysis_result,
    artifact_summary = artifact_summary,
    checkpoint_receipt = checkpoint_receipt,
    copy = copy,
    digest = digest,
    execution_result = execution_result,
    expect_failure = expect_failure,
    finalized = finalized,
    fixture = fixture,
    grant_result = grant_result,
    module_terminal = module_terminal,
    plan_result = plan_result,
    pointer = pointer,
    ready_result = ready_result,
    runtime = runtime,
    workflow_readiness_result = workflow_readiness_result,
  }
end

return M
