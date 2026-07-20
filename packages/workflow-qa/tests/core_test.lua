local contract = require("contract.workflow_qa")
local core = require("core")
local design_loop = require("testing_ai.module_ai_design_loop")
local t = fkst.test

local function digest(char) return string.rep(char or "a", 64) end
local function pointer(path) return { kind = "artifact", ref = path } end
local function reference(path, char)
  return { schema = "testing-design.artifact-reference.v1", artifact_schema = "testing-design.repository-analysis.v1", artifact_pointer = path, artifact_digest = digest(char) }
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
  local repository = { slug = "owner/repo", url = "https://github.com/owner/repo.git", commit_sha = string.rep("a", 40) }
  local env_root = root .. "/environment"
  local analysis_root = root .. "/analysis"
  local design_root = root .. "/design"
  local request = {
    schema = contract.schemas.request,
    issue = { repository = repository.slug, number = 100, state = "open", labels = { "fkst-qa" } },
    run_id = "qa-run-100", repository = repository, artifact_root = root,
    state_ref = root .. "/workflow-state.json", proposed_cases = { proposed_case() },
    environment_start = {
      schema = "environment-factory.start.v1", operation_id = "qa-run-100",
      repository = { url = repository.url, commit_sha = repository.commit_sha },
      profile_ref = { kind = "host-profile", ref = "profiles/qa" },
      approval_ref = { kind = "approval", ref = "approvals/qa" },
      validation_receipt_ref = pointer(".testing/approvals/qa.json"),
      operation_state_ref = pointer(env_root .. "/operation-state.json"), artifact_root = env_root,
      base_url = "http://127.0.0.1:4173/health", runtime_ports = { { name = "application", port = 4173 } },
      sessions = { { role = "headless", browser_harness_command = "true" } },
      testing = { module = "api", artifact_root = env_root .. "/testing", mutation_policy = "read-only" },
      trace_id = "trace-qa-100", dedup_key = "dedup-qa-100",
    },
    analysis_request = {
      schema = "testing-design.analysis-request.v1",
      repository = {
        url = repository.url, commit_sha = repository.commit_sha, baseline_commit_sha = string.rep("b", 40),
        workspace_ref = { kind = "workspace", ref = "approved/qa-run-100" },
        approval_ref = pointer(".testing/approvals/repository.json"), approval_sha256 = digest("b"),
      },
      inputs = {}, artifact_root = analysis_root, source_ref = { kind = "workflow-qa", ref = "qa-run-100" },
      trace_id = "trace-qa-100", dedup_key = "dedup-qa-100",
    },
    design_module_start = {
      schema = "testing-pipeline.module-start.v1", module = "api", no_browser = true, dry_run = true,
      artifact_root = design_root, source_ref = { kind = "workflow-qa", ref = "qa-run-100" },
      trace_id = "trace-qa-100", dedup_key = "dedup-qa-100",
      cdp_execution = {
        schema = "testing-runner.module-cdp-execution.v1",
        ai_design_loop_request = {
          schema = design_loop.schemas.request, artifact_root = design_root .. "/loop",
          seed_cases_ref = { artifact_pointer = design_root .. "/placeholder.json", artifact_digest = "placeholder" },
          deterministic_cases_ref = { artifact_pointer = design_root .. "/deterministic.json", artifact_digest = "deterministic" },
          coverage_scope_ref = { artifact_pointer = design_root .. "/coverage.json", artifact_digest = "coverage" },
          max_rounds = 3, case_budget = 16, action_budget = 32,
          trace_id = "trace-qa-100", dedup_key = "dedup-qa-100",
        },
      },
    },
    structured_execution = {
      artifact_root = root .. "/execution", execution_approval_ref = root .. "/execution/approval.json",
      execution_approval_sha256 = digest("c"),
    },
    publication = {
      ledger_ref = root .. "/run-ledger.json", defect_ledger_ref = root .. "/execution/defect-ledger.json",
      defect_receipt_ref = root .. "/execution/defect-receipt.json",
      issue_drafts_ref = root .. "/execution/issue-drafts.json", aggregate_report_ref = root .. "/aggregate-report.json",
    },
    terminal_policy = { mode = "host" }, trace_id = "trace-qa-100", dedup_key = "dedup-qa-100",
  }
  return request
end

local function runtime(request)
  local state, artifacts, saves, version, draft_materializations = nil, {}, 0, 0, 0
  local ports = {
    load_state = function() return state end,
    load_run = function(trace_id, dedup_key)
      if trace_id == request.trace_id and dedup_key == request.dedup_key then return request end
    end,
    save_state = function(_, value, expected)
      if expected ~= version then return false end
      state = value; version = value.version; saves = saves + 1; return true
    end,
    write_artifact = function(path, value) artifacts[path] = value; return true end,
    artifact_digest = function(path)
      if artifacts[path] == nil then artifacts[path] = { external = path } end
      return digest(({ a = "d", b = "e", c = "f" })[path:sub(-1)] or "d")
    end,
    materialize_issue_drafts = function(value)
      draft_materializations = draft_materializations + 1
      artifacts[value.issue_drafts_ref] = { schema = "test-publication.defect-issue-drafts.v1", plan_sha256 = value.plan_sha256, cases = {} }
      return { ref = value.issue_drafts_ref }
    end,
  }
  return ports, function() return state end, artifacts, function() return saves end,
    function() return draft_materializations end
end

local function ready(request)
  local ref = pointer(request.environment_start.artifact_root .. "/environment-receipt-ready.json")
  return {
    schema = "environment-factory.result.v1", operation_id = request.run_id, status = "ready",
    base_url = request.environment_start.base_url, sessions = request.environment_start.sessions,
    readiness_correlation = {
      schema = "environment-factory.browser-readiness-correlation.v1", attempt_id = "attempt-1",
      operation_id = request.run_id, operation_state_ref = request.environment_start.operation_state_ref,
      environment_receipt_ref = ref, base_url = request.environment_start.base_url,
      sessions = request.environment_start.sessions, trace_id = request.trace_id, dedup_key = request.dedup_key,
    },
    environment_receipt_ref = ref, cleanup_ref = { kind = "environment-cleanup", ref = request.run_id },
    diagnostic_refs = {}, cleanup_status = "pending", trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
end

local function analysis(request)
  local root = request.analysis_request.artifact_root
  local function ref(schema, name, char)
    return { schema = "testing-design.artifact-reference.v1", artifact_schema = schema,
      artifact_pointer = root .. "/" .. name, artifact_digest = digest(char) }
  end
  return {
    schema = "testing-design.analysis-result.v1", status = "complete", replayed = false,
    analysis_key = digest("1"), context = {
      schema = "testing-design.context-reference.v1", analysis_key = digest("1"),
      repository_analysis = ref("testing-design.repository-analysis.v1", "repository-analysis.v1.json", "2"),
      requirements_index = ref("testing-design.requirements-index.v1", "requirements-index.v1.json", "3"),
      traceability_seed = ref("testing-design.traceability-seed.v1", "traceability-seed.v1.json", "4"),
    },
    source_ref = { kind = "workflow-qa", ref = request.run_id }, trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
end

local function design_result(request)
  local plan_path_field = "test_" .. "plan_path"
  return {
    schema = "testing-runner.result.v1", job = "module-test-loop", status = "passed",
    artifact_root = request.design_module_start.artifact_root, source_ref = { kind = "workflow-qa", ref = request.run_id },
    trace_id = request.trace_id, dedup_key = request.dedup_key,
    native_summary = { [plan_path_field] = request.design_module_start.artifact_root .. "/test-plan.json" },
  }
end

local function execution_result(request, failures)
  local root = request.structured_execution.artifact_root
  local plan_path_field = "test_" .. "plan_path"
  return {
    schema = "testing-runner.result.v1", job = "structured-execution", status = failures > 0 and "failed" or "passed",
    artifact_root = root, source_ref = { kind = "workflow-qa", ref = request.run_id },
    trace_id = request.trace_id, dedup_key = request.dedup_key,
    native_summary = {
      [plan_path_field] = root .. "/test-plan.json", execution_path = root .. "/execution.json",
      case_results_path = root .. "/case-results.json", case_count = 2,
      passed_count = 2 - failures, failed_count = failures, skipped_count = 0, error_count = 0,
    },
  }
end

local function finalized(request)
  return {
    schema = "environment-factory.result.v1", operation_id = request.run_id, status = "finalized",
    environment_receipt_ref = pointer(request.environment_start.artifact_root .. "/environment-receipt-finalized.json"),
    cleanup_receipt_ref = pointer(request.environment_start.artifact_root .. "/cleanup-receipt-complete.json"),
    cleanup_ref = { kind = "environment-cleanup", ref = request.run_id }, diagnostic_refs = {}, cleanup_status = "complete",
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
end

local function blocked_environment(request)
  return {
    schema = "environment-factory.result.v1", operation_id = request.run_id, status = "blocked",
    failure_class = "readiness-failed",
    environment_receipt_ref = pointer(request.environment_start.artifact_root .. "/environment-receipt-blocked.json"),
    cleanup_receipt_ref = pointer(request.environment_start.artifact_root .. "/cleanup-receipt-complete.json"),
    cleanup_ref = { kind = "environment-cleanup", ref = request.run_id }, diagnostic_refs = {}, cleanup_status = "complete",
    trace_id = request.trace_id, dedup_key = request.dedup_key,
  }
end

return {
  test_open_fkst_qa_run_traverses_environment_design_execution_cleanup_and_terminal = function()
    local request = fixture(); local ports, state, _, _, draft_materializations = runtime(request)
    local started = core.start(request, ports)
    t.eq(started[2].queue, "environment-factory.environment_start")
    t.eq(core.start(request, ports)[2].payload.operation_id, request.run_id)
    local environment = core.handle_environment_result(ready(request), request, ports)
    t.eq(environment[2].queue, "testing-design.analysis_request")
    local designed = core.handle_analysis_result(analysis(request), request, ports)
    t.eq(designed[2].queue, "testing-pipeline.module_start")
    t.eq(designed[2].payload.cdp_execution.ai_design_loop_request.seed_cases_ref.artifact_pointer,
      request.artifact_root .. "/design/seed-cases.json")
    t.eq(designed[2].payload.config.workflow_qa_requirements_index_ref,
      request.analysis_request.artifact_root .. "/requirements-index.v1.json")
    local execution = core.handle_design_result(design_result(request), request, ports)
    t.eq(execution[2].queue, "testing-runner.structured_execution_request")
    local cleanup = core.handle_execution_result(execution_result(request, 0), request, ports)
    t.eq(cleanup[1].queue, "test-publication.qa_checkpoint_request")
    t.eq(cleanup[2].queue, "environment-factory.environment_finalize")
    t.eq(draft_materializations(), 0)
    local publication = core.handle_cleanup_result(finalized(request), request, ports)
    t.eq(publication[2].queue, "test-publication.qa_finalize_request")
    local terminal = core.handle_publication_receipt({
      schema = "test-publication.qa-publication-receipt.v1", status = "published", run_id = request.run_id,
      stage = "aggregate-report", receipt_ref = request.artifact_root .. "/publication-receipts/aggregate-report-1.json",
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }, request, ports)
    t.eq(terminal[1].queue, "workflow_qa_terminal_request")
    t.eq(state().phase, "terminal")
  end,

  test_failed_cases_wait_for_durable_defect_receipt_before_cleanup = function()
    local request = fixture(); local ports, state, _, _, draft_materializations = runtime(request)
    core.start(request, ports); core.handle_environment_result(ready(request), request, ports)
    core.handle_analysis_result(analysis(request), request, ports); core.handle_design_result(design_result(request), request, ports)
    local defects = core.handle_execution_result(execution_result(request, 1), request, ports)
    t.eq(defects[2].queue, "test-publication.defect_publication_request")
    t.eq(draft_materializations(), 1)
    t.eq(state().phase, "defects-pending")
    local cleanup = core.handle_defect_terminal({
      schema = "test-publication.defect-publication-terminal.v1", status = "published",
      receipt_ref = request.publication.defect_receipt_ref, trace_id = request.trace_id, dedup_key = request.dedup_key,
    }, request, ports)
    t.eq(cleanup[1].queue, "environment-factory.environment_finalize")
  end,

  test_claim_and_closed_identity_fail_closed = function()
    local request = fixture(); request.issue.labels = { "fkst-dev:enabled" }
    t.raises(function() contract.validate_request(request) end)
    request = fixture(); request.issue.state = "closed"
    t.raises(function() contract.validate_request(request) end)
    request = fixture(); request.environment_start.repository.commit_sha = string.rep("c", 40)
    t.raises(function() contract.validate_request(request) end)
  end,

  test_early_environment_block_waits_for_github_visible_summary_before_terminal = function()
    local request = fixture(); local ports, state = runtime(request)
    core.start(request, ports)
    local publication = core.handle_environment_result(blocked_environment(request), request, ports)
    t.eq(publication[1].queue, "test-publication.qa_checkpoint_request")
    t.eq(publication[1].payload.stage, "aggregate-report")
    t.eq(state().phase, "early-publication-pending")
    local terminal = core.handle_publication_receipt({
      schema = "test-publication.qa-publication-receipt.v1", status = "published", run_id = request.run_id,
      stage = "aggregate-report", receipt_ref = request.artifact_root .. "/publication-receipts/aggregate-report-1.json",
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }, request, ports)
    t.eq(terminal[1].queue, "workflow_qa_terminal_request")
  end,

  test_cancelled_run_uses_owned_environment_interrupt_path = function()
    local request = fixture(); local ports = runtime(request)
    core.start(request, ports); core.handle_environment_result(ready(request), request, ports)
    local actions = core.handle_interrupt({
      schema = "workflow-qa.interrupt.v1", interruption = "cancelled",
      trace_id = request.trace_id, dedup_key = request.dedup_key,
    }, ports)
    t.eq(actions[1].queue, "environment-factory.environment_interrupt")
    t.eq(actions[1].payload.interruption, "cancelled")
  end,
}
