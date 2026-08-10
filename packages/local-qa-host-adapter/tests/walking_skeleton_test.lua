local adapter = require("adapter")
local intake = require("departments.intake.main")
local testing = require("testkit.testing")
local t = fkst.test

local function digest(char) return string.rep(char, 64) end
local function pointer(path) return { kind = "artifact", ref = path } end

local function canonical_request()
  local root = ".testing/runs/local-qa-walking-skeleton"
  local repository = {
    slug = "owner/repo",
    url = "https://github.com/owner/repo.git",
    commit_sha = string.rep("a", 40),
  }

  return {
    schema = "workflow-qa.run-request.v2",
    issue = {
      repository = "owner/repo",
      number = 558,
      state = "open",
      labels = { "fkst-qa" },
    },
    run_id = "local-qa-walking-skeleton",
    repository = repository,
    artifact_root = root,
    state_ref = root .. "/workflow-state.json",
    proposed_cases = { {
      id = "seed-health",
      module_id = "api",
      priority = "P0",
      title = "Health endpoint",
      objective = "Verify the approved health endpoint.",
      case_kind = "api",
      actions = { {
        action = "http",
        target = "/health",
        expected = "HTTP 200",
      } },
      expected_observable = "The service reports healthy.",
      coverage_subject_ids = { "REQ-HEALTH" },
      review_status = "executable",
    } },
    environment_start = {
      schema = "environment-factory.start.v1",
      operation_id = "local-qa-walking-skeleton",
      repository = {
        url = repository.url,
        commit_sha = repository.commit_sha,
      },
      profile_ref = { kind = "host-profile", ref = "profiles/qa" },
      approval_ref = { kind = "approval", ref = "approvals/qa" },
      validation_receipt_ref = pointer(".testing/approvals/qa.json"),
      operation_state_ref = pointer(root .. "/environment/operation-state.json"),
      artifact_root = root .. "/environment",
      base_url = "http://127.0.0.1:4173/health",
      runtime_ports = { { name = "application", port = 4173 } },
      sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
      trace_id = "trace-local-qa-walking-skeleton",
      dedup_key = "dedup-local-qa-walking-skeleton",
    },
    analysis_request = {
      schema = "testing-design.analysis-request.v1",
      repository = {
        url = repository.url,
        commit_sha = repository.commit_sha,
        baseline_commit_sha = string.rep("b", 40),
        workspace_ref = { kind = "workspace", ref = "approved/local-qa-walking-skeleton" },
        approval_ref = pointer(".testing/approvals/repository.json"),
        approval_sha256 = digest("b"),
      },
      inputs = {},
      artifact_root = root .. "/analysis",
      source_ref = { kind = "workflow-qa", ref = "local-qa-walking-skeleton" },
      trace_id = "trace-local-qa-walking-skeleton",
      dedup_key = "dedup-local-qa-walking-skeleton",
    },
    design_module_start = {
      schema = "module-testing-pipeline.module-start.v1",
      module = "api",
      no_browser = false,
      dry_run = true,
      artifact_root = root .. "/design",
      source_ref = { kind = "workflow-qa", ref = "local-qa-walking-skeleton" },
      trace_id = "trace-local-qa-walking-skeleton",
      dedup_key = "dedup-local-qa-walking-skeleton",
      cdp_execution = {
        schema = "testing-runner.module-cdp-execution.v1",
      },
      ai_design_loop_request = {
        schema = "testing-runner.ai-design-loop.request.v1",
        artifact_root = root .. "/design/loop",
        seed_cases_ref = {
          artifact_pointer = root .. "/design/seed.json",
          artifact_digest = "seed",
        },
        deterministic_cases_ref = {
          artifact_pointer = root .. "/design/deterministic.json",
          artifact_digest = "deterministic",
        },
        coverage_scope_ref = {
          artifact_pointer = root .. "/design/coverage.json",
          artifact_digest = "coverage",
        },
        max_rounds = 3,
        case_budget = 16,
        action_budget = 32,
        trace_id = "trace-local-qa-walking-skeleton",
        dedup_key = "dedup-local-qa-walking-skeleton",
      },
    },
    structured_execution = {
      artifact_root = root .. "/execution",
      preauthorization_ref = root .. "/execution/preauthorization.json",
      preauthorization_sha256 = digest("1"),
      case_catalog_ref = root .. "/execution/catalog.json",
      case_catalog_sha256 = digest("2"),
      structured_plan_ref = root .. "/execution/plan.json",
      grant_ref = root .. "/execution/grant.json",
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
    trace_id = "trace-local-qa-walking-skeleton",
    dedup_key = "dedup-local-qa-walking-skeleton",
  }
end

return {
  test_canonical_local_qa_request_enters_workflow_qa_unchanged = function()
    t.eq(#intake.spec.consumes, 1)
    t.eq(intake.spec.consumes[1], "qa_run_request")
    t.eq(#intake.spec.published_seam, 1)
    t.eq(intake.spec.published_seam[1], "qa_run_request")
    t.eq(#intake.spec.produces, 1)
    t.eq(intake.spec.produces[1], "workflow-qa.qa_run_request")

    local request = canonical_request()
    local trace = testing.run_fake(intake, {
      queue = "qa_run_request",
      payload = request,
    })

    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "workflow-qa.qa_run_request")
    t.is_true(rawequal(trace.raises[1].payload, request))
    t.is_true(rawequal(trace.raises[1].payload.design_module_start.ai_design_loop_request,
      request.design_module_start.ai_design_loop_request))

    local direct = adapter.qa_run_event(request)
    t.eq(direct.source_ref.kind, "external")
    t.eq(direct.source_ref.reference, "local-qa-walking-skeleton")
  end,

  test_malformed_local_qa_request_fails_without_raise = function()
    local trace = testing.run_fake_expecting_failure(intake, {
      queue = "qa_run_request",
      payload = {},
    })

    t.eq(#trace.raises, 0)
    t.is_true(tostring(trace.failure.error):find("contract.workflow-qa:", 1, true) ~= nil)
  end,
}
