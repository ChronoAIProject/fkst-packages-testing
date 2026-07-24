local qa_publication = require("qa_publication")
local t = fkst.test

local commit_sha = string.rep("1", 40)
local plan_sha = string.rep("b", 64)
local results_sha = string.rep("c", 64)
local environment_sha = string.rep("d", 64)
local readiness_sha = string.rep("5", 64)
local cleanup_sha = string.rep("e", 64)
local report_sha = string.rep("f", 64)
local terminal_sha = string.rep("6", 64)
local catalog_sha = string.rep("7", 64)
local module_plan_sha = string.rep("8", 64)

local function request(channel)
  local root = ".testing/runs/qa-run-final"
  local value = {
    schema = "test-publication.qa-finalize.request.v2",
    repository = { slug = "owner/repo", commit_sha = commit_sha },
    run_id = "qa-run-final", issue_number = 107,
    artifact_root = root,
    ledger_ref = root .. "/run-ledger.json",
    terminal_summary_ref = root .. "/terminal-summary.json", terminal_summary_sha256 = terminal_sha,
    case_results_ref = root .. "/case-results.json", case_results_sha256 = results_sha,
    environment_receipt_ref = root .. "/environment-receipt-ready.json",
    environment_receipt_sha256 = environment_sha,
    browser_readiness_ref = root .. "/browser-readiness.json",
    browser_readiness_sha256 = readiness_sha,
    cleanup_receipt_ref = root .. "/cleanup-receipt-complete.json",
    cleanup_receipt_sha256 = cleanup_sha,
    aggregate_report_ref = root .. "/aggregate-report.json",
    trace_id = "trace-qa-run-final", dedup_key = "dedup-qa-run-final",
  }
  value["test_" .. "plan_ref"] = root .. "/test-plan.json"
  value["test_" .. "plan_sha256"] = plan_sha
  value.channel = channel
  return value
end

local function repository()
  return { slug = "owner/repo", url = "https://github.com/owner/repo.git", commit_sha = commit_sha }
end

local function readiness(root, run_id, trace_id, dedup_key)
  local operation_state_ref = { kind = "artifact", ref = root .. "/operation-state.json" }
  local correlation = {
    schema = "environment-factory.browser-readiness-correlation.v1",
    attempt_id = "readiness-attempt-1",
    operation_id = run_id,
    operation_state_ref = operation_state_ref,
    readiness_attempt_ref = { kind = "artifact", ref = root .. "/browser-readiness-attempt.json" },
    readiness_attempt_sha256 = string.rep("a", 64),
    base_url = "http://127.0.0.1:4173/health",
    sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
    trace_id = trace_id,
    dedup_key = dedup_key,
  }
  return {
    schema = "browser-readiness.result.v1",
    status = "ready",
    sessions = {
      { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
      { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } }, cdp_url = "http://127.0.0.1:9222" },
    },
    source_ref = operation_state_ref,
    request_context = { dry_run = false },
    correlation = correlation,
  }
end

local function environment_receipt(value, status)
  local root = value.artifact_root
  local receipt = {
    schema = "environment-factory.receipt.v2",
    operation_id = value.run_id,
    status = status or "ready",
    profile_revision = "qa-profile-v1",
    profile_sha256 = string.rep("9", 64),
    repository = { url = repository().url, commit_sha = commit_sha },
    workspace_ref = { kind = "workspace", ref = "qa-run-final-workspace" },
    base_url = "http://127.0.0.1:4173/health",
    runtime_ports = { { name = "application", port = 4173 } },
    sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
    artifact_root = root,
    diagnostic_refs = {},
    cleanup_ref = { kind = "runtime-cleanup", ref = "qa-run-final-cleanup" },
    cleanup_status = "pending",
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
  }
  if receipt.status == "ready" then
    receipt.browser_readiness = readiness(root, value.run_id, value.trace_id, value.dedup_key)
  else
    receipt.failure_class = "provisioning-failed"
    receipt.cleanup_status = "complete"
    receipt.cleanup_receipt_ref = { kind = "artifact", ref = value.cleanup_receipt_ref }
  end
  return receipt
end

local function cleanup_receipt(value)
  return {
    schema = "environment-factory.cleanup-receipt.v1",
    operation_id = value.run_id,
    status = "complete",
    attempted_resources = {
      { resource_id = "workspace", resource_kind = "workspace", status = "cleaned",
        diagnostic_ref = { kind = "artifact", ref = value.artifact_root .. "/diagnostics/cleanup-workspace.json" } },
    },
    verified_removals = { "workspace" },
    remaining_resources = {},
    artifact_root = value.artifact_root,
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
  }
end

local function workflow_readiness(value)
  local result = readiness(value.artifact_root, value.run_id, value.trace_id, value.dedup_key)
  result.source_ref = { kind = "workflow-qa", ref = value.run_id }
  return result
end

local function plan(value)
  return {
    schema = "testing-structured-plan.v2",
    execution_mode = "structured-api-cli",
    repository = { url = repository().url, commit_sha = commit_sha },
    environment_receipt_sha256 = environment_sha,
    browser_readiness_sha256 = readiness_sha,
    case_catalog_sha256 = catalog_sha,
    module_plan_sha256 = module_plan_sha,
    cases = {
      { case_id = "health", kind = "http", request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} }, timeout_seconds = 10, assertions = { { type = "status-code", expected = 200 } } },
      { case_id = "version", kind = "cli", argv = { "fixture", "--version" }, timeout_seconds = 10, assertions = { { type = "exit-code", expected = 0 } } },
    },
    residual_risk_case_ids = {},
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
  }
end

local function counts()
  return { planned = 2, executed = 2, passed = 1, failed = 1, skipped = 0, error = 0, blocked = 0 }
end

local function terminal_summary(value, status, terminal_counts)
  return {
    schema = "workflow-qa.terminal-summary.v2",
    status = status or "failed",
    repository = repository(),
    run_id = value.run_id,
    phase = "cleanup-pending",
    counts = terminal_counts or counts(),
    environment_receipt_ref = value.environment_receipt_ref,
    cleanup_receipt_ref = value.cleanup_receipt_ref,
    browser_readiness_ref = value.browser_readiness_ref,
    browser_readiness_sha256 = value.browser_readiness_sha256,
    structured_plan_ref = value.test_plan_ref,
    case_results_ref = value.case_results_ref,
    trace_id = value.trace_id,
    dedup_key = value.dedup_key,
  }
end

local function runtime(mutate, supplied, options)
  local value = supplied or request()
  options = options or {}
  local state
  local artifacts = {
    [value.terminal_summary_ref] = { digest = terminal_sha, value = terminal_summary(value) },
    [value.environment_receipt_ref] = { digest = environment_sha, value = environment_receipt(value) },
    [value.cleanup_receipt_ref] = { digest = cleanup_sha, value = cleanup_receipt(value) },
  }
  if value.browser_readiness_ref ~= nil then
    artifacts[value.browser_readiness_ref] = { digest = readiness_sha, value = workflow_readiness(value) }
  end
  if value.test_plan_ref ~= nil then
    artifacts[value.test_plan_ref] = { digest = plan_sha, value = plan(value) }
  end
  if value.case_results_ref ~= nil then
    artifacts[value.case_results_ref] = { digest = results_sha, value = {
      schema = "testing-structured-case-results.v1", plan_sha256 = plan_sha,
      cases = {
        { case_id = "health", kind = "http", status = "passed", classification = "passed", evidence_ref = value.artifact_root .. "/evidence/health.json" },
        { case_id = "version", kind = "cli", status = "failed", classification = "product-defect", evidence_ref = value.artifact_root .. "/evidence/version.json" },
      },
    } }
  end
  if mutate then mutate(artifacts, value) end
  local reports = {}
  local report_writes = 0
  return {
    load_ledger = function() return state end,
    save_ledger = function(_, next_state, expected)
      if state ~= nil and state.version ~= expected then return false end
      if state == nil and expected ~= 0 then return false end
      state = next_state return true
    end,
    load_artifact = function(path) return artifacts[path] end,
    write_artifact = function(path, artifact) reports[path] = artifact return true end,
    write_report = function(path, report)
      report_writes = report_writes + 1
      reports[path] = report
      artifacts[path] = { digest = report_sha, value = report }
      return { status = "written", digest = report_sha }
    end,
    publish_artifact = function(publication)
      if publication.channel == "filesystem-dry-run-v1" then
        local receipt_ref = value.artifact_root .. "/materializations/" .. publication.stage .. "-"
          .. tostring(publication.attempt) .. ".json"
        local receipt_sha256 = string.rep("4", 64)
        if not options.missing_materialization_receipt then
          artifacts[receipt_ref] = { digest = options.materialization_receipt_digest_mismatch
            and string.rep("3", 64) or receipt_sha256, value = {
            schema = "test-publication.qa-materialization-receipt.v1",
            status = "materialized", channel = "filesystem-dry-run-v1",
            run_id = publication.run_id,
            stage = options.materialization_receipt_binding_mismatch and "foreign-stage" or publication.stage,
            attempt = publication.attempt, artifact_ref = publication.artifact_ref,
            digest = publication.digest, source_commit = commit_sha, receipt_ref = receipt_ref,
            trace_id = publication.trace_id, dedup_key = publication.dedup_key,
          } }
        end
        return {
          status = "materialized", artifact_ref = publication.artifact_ref,
          digest = publication.digest, source_commit = commit_sha,
          receipt_ref = receipt_ref, receipt_sha256 = receipt_sha256,
        }
      end
      return {
        status = "published", digest = publication.digest, source_commit = commit_sha,
        remote_url = "https://github.com/owner/repo/blob/" .. commit_sha .. "/qa/" .. publication.stage .. ".json",
        receipt_ref = value.artifact_root .. "/publication/" .. publication.stage .. "-" .. tostring(publication.attempt) .. ".json",
      }
    end,
    reports = reports,
    report_writes = function() return report_writes end,
    state = function() return state end,
    artifacts = artifacts,
  }
end

local function terminal_request()
  local value = request()
  rawset(value, "test" .. "_plan_ref", nil)
  rawset(value, "test" .. "_plan_sha256", nil)
  value.case_results_ref = nil
  value.case_results_sha256 = nil
  value.browser_readiness_ref = nil
  value.browser_readiness_sha256 = nil
  value.environment_receipt_ref = value.artifact_root .. "/environment-receipt-blocked.json"
  return value
end

return {
  test_finalize_validation_and_bound_artifacts_fail_closed = function()
    local invalid_schema = request()
    invalid_schema.schema = "unknown"
    t.raises(function() qa_publication.prepare_final_report(invalid_schema, runtime()) end)

    local partial = request()
    partial.case_results_sha256 = nil
    t.raises(function() qa_publication.prepare_final_report(partial, runtime()) end)

    local unsafe_pointer = request()
    unsafe_pointer.terminal_summary_ref = ".testing/runs/foreign/terminal-summary.json"
    t.raises(function() qa_publication.prepare_final_report(unsafe_pointer, runtime()) end)

    local digest_mismatch = runtime(function(artifacts, value)
      artifacts[value.terminal_summary_ref].digest = string.rep("0", 64)
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), digest_mismatch) end)
  end,

  test_malformed_plan_result_and_environment_fail_closed = function()
    local malformed_plan = runtime(function(artifacts, value)
      artifacts[value.test_plan_ref].value.schema = "unknown"
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), malformed_plan) end)

    local foreign_result = runtime(function(artifacts, value)
      artifacts[value.case_results_ref].value.cases[1].case_id = "foreign"
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), foreign_result) end)

    local missing_browser_gate = runtime(function(artifacts, value)
      artifacts[value.environment_receipt_ref].value.browser_readiness = nil
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), missing_browser_gate) end)

    local foreign_environment = runtime(function(artifacts, value)
      artifacts[value.environment_receipt_ref].value.repository.commit_sha = string.rep("2", 40)
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), foreign_environment) end)
  end,

  test_final_report_reconciles_terminal_cases_and_verified_cleanup = function()
    local ports = runtime()
    local prepared = qa_publication.prepare_final_report(request(), ports)

    t.eq(prepared.status, "pending")
    t.eq(prepared.report.schema, "test-publication.qa-aggregate-report.v1")
    t.eq(prepared.report.finalization_kind, "full")
    t.eq(prepared.report.status, "failed")
    t.eq(prepared.report.counts.planned, 2)
    t.eq(prepared.report.counts.executed, 2)
    t.eq(prepared.report.counts.passed, 1)
    t.eq(prepared.report.counts.failed, 1)
    t.eq(prepared.report.cleanup_receipt_ref, request().cleanup_receipt_ref)
    t.eq(prepared.comment_request.handoff.stage, "aggregate-report")

    local explicit_value = request("github-comment-v1")
    local explicit = qa_publication.prepare_final_report(explicit_value, runtime(nil, explicit_value))
    t.eq(explicit.status, "pending")
    t.eq(explicit.report.channel, nil)
    t.eq(explicit.report.github_publication_occurred, nil)
    t.is_true(explicit.report.artifact_links.terminal_summary:find("https://github.com/", 1, true) ~= nil)
  end,

  test_filesystem_finalization_materializes_local_links_and_receipt_without_github = function()
    local value = request("filesystem-dry-run-v1")
    local ports = runtime(nil, value)
    local prepared = qa_publication.prepare_final_report(value, ports)

    t.eq(prepared.status, "published")
    t.eq(prepared.comment_request, nil)
    t.eq(prepared.receipt.channel, "filesystem-dry-run-v1")
    t.eq(prepared.receipt.github_publication_occurred, false)
    t.eq(prepared.report.channel, "filesystem-dry-run-v1")
    t.eq(prepared.report.github_publication_occurred, false)
    for _, link in pairs(prepared.report.artifact_links) do
      t.is_true(link:sub(1, #value.artifact_root + 1) == value.artifact_root .. "/")
      t.eq(link:find("github.com", 1, true), nil)
    end
    t.eq(ports.report_writes(), 1)

    local replay = qa_publication.prepare_final_report(value, ports)
    t.eq(replay.replayed, true)
    t.eq(replay.status, "published")
    t.eq(replay.comment_request, nil)
    t.eq(replay.receipt.receipt_ref, prepared.receipt.receipt_ref)
    t.eq(ports.report_writes(), 1)
  end,

  test_filesystem_finalization_rejects_missing_or_mismatched_materialization_receipt = function()
    for _, options in ipairs({
      { missing_materialization_receipt = true },
      { materialization_receipt_digest_mismatch = true },
      { materialization_receipt_binding_mismatch = true },
    }) do
      local value = request("filesystem-dry-run-v1")
      local ports = runtime(nil, value, options)
      t.raises(function() qa_publication.prepare_final_report(value, ports) end)
      t.eq(ports.report_writes(), 0)
    end
  end,

  test_terminal_summary_variant_writes_and_publishes_real_aggregate_report = function()
    local value = terminal_request()
    local blocked_counts = { planned = 0, executed = 0, passed = 0, failed = 0, skipped = 0, error = 0, blocked = 1 }
    local ports = runtime(function(artifacts)
      artifacts[value.terminal_summary_ref].value = terminal_summary(value, "blocked", blocked_counts)
      artifacts[value.terminal_summary_ref].value.structured_plan_ref = value.artifact_root .. "/partial-plan.json"
      artifacts[value.environment_receipt_ref].value = environment_receipt(value, "blocked")
    end, value)
    local prepared = qa_publication.prepare_final_report(value, ports)

    t.eq(prepared.status, "pending")
    t.eq(prepared.report.finalization_kind, "terminal-summary")
    t.eq(prepared.report.status, "blocked")
    t.eq(prepared.report.counts.blocked, 1)
    t.eq(prepared.report.artifact_links.test_plan, nil)
    t.is_true(prepared.report.artifact_links.terminal_summary ~= nil)
    t.eq(prepared.comment_request.handoff.stage, "aggregate-report")
    t.eq(ports.report_writes(), 1)
  end,

  test_final_report_replay_reuses_existing_report_without_second_write = function()
    local ports = runtime()
    local first = qa_publication.prepare_final_report(request(), ports)
    qa_publication.acknowledge_comment({
      schema = "github-proxy.comment-written.v1", comment_id = "501",
      request_dedup_key = first.comment_request.dedup_key,
      handoff = first.comment_request.handoff,
    }, ports)

    local replay = qa_publication.prepare_final_report(request(), ports)
    t.eq(replay.replayed, true)
    t.eq(replay.status, "published")
    t.eq(replay.comment_request, nil)
    t.eq(replay.report.schema, "test-publication.qa-aggregate-report.v1")
    t.eq(ports.report_writes(), 1)
  end,

  test_final_report_replay_rejects_foreign_ledger_changed_pointer_and_changed_report = function()
    local foreign = runtime()
    qa_publication.prepare_final_report(request(), foreign)
    foreign.state().run_id = "foreign"
    t.raises(function() qa_publication.prepare_final_report(request(), foreign) end)

    local moved = runtime()
    qa_publication.prepare_final_report(request(), moved)
    moved.state().checkpoints["aggregate-report/1"].artifact_ref = request().artifact_root .. "/other.json"
    t.raises(function() qa_publication.prepare_final_report(request(), moved) end)

    local changed = runtime()
    qa_publication.prepare_final_report(request(), changed)
    changed.artifacts[request().aggregate_report_ref].value.trace_id = "foreign"
    t.raises(function() qa_publication.prepare_final_report(request(), changed) end)
  end,

  test_final_report_rejects_planned_case_without_terminal_disposition = function()
    local ports = runtime(function(artifacts, value)
      table.remove(artifacts[value.case_results_ref].value.cases, 2)
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), ports) end)
  end,

  test_final_report_consumes_optional_defect_publication_receipt = function()
    local value = request()
    value.defect_publication_receipt_ref = value.artifact_root .. "/defect-publication-receipt.json"
    value.defect_publication_receipt_sha256 = string.rep("9", 64)
    local ports = runtime(function(artifacts)
      artifacts[value.defect_publication_receipt_ref] = { digest = value.defect_publication_receipt_sha256, value = {
        schema = "test-publication.defect-publication-receipt.v1",
        cases = {
          { case_id = "version", status = "created", issue_url = "https://github.com/owner/repo/issues/501" },
          { case_id = "health", status = "summary-only" },
        },
      } }
    end, value)
    local prepared = qa_publication.prepare_final_report(value, ports)
    t.eq(prepared.report.defect_issue_links[1], "https://github.com/owner/repo/issues/501")
  end,

  test_final_report_rejects_malformed_defect_receipt_and_report_write_failure = function()
    local value = request()
    value.defect_publication_receipt_ref = value.artifact_root .. "/defect-publication-receipt.json"
    value.defect_publication_receipt_sha256 = string.rep("9", 64)
    local malformed = runtime(function(artifacts)
      artifacts[value.defect_publication_receipt_ref] = {
        digest = value.defect_publication_receipt_sha256,
        value = { schema = "unknown", cases = {} },
      }
    end, value)
    t.raises(function() qa_publication.prepare_final_report(value, malformed) end)

    local write_failure = runtime()
    write_failure.write_report = function() return { status = "blocked" } end
    t.raises(function() qa_publication.prepare_final_report(request(), write_failure) end)
  end,

  test_final_report_rejects_unverified_cleanup = function()
    local ports = runtime(function(artifacts, value)
      artifacts[value.cleanup_receipt_ref].value.status = "incomplete"
      artifacts[value.cleanup_receipt_ref].value.attempted_resources[1].status = "remaining"
      artifacts[value.cleanup_receipt_ref].value.verified_removals = {}
      artifacts[value.cleanup_receipt_ref].value.remaining_resources = {
        { resource_id = "workspace", resource_kind = "workspace", cleanup_ref = { kind = "runtime-cleanup", ref = "remaining-workspace" } },
      }
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), ports) end)
  end,

  test_finalize_request_and_terminal_artifacts_reject_mutation_matrix = function()
    local request_mutations = {
      function(value) value.browser_readiness_ref = "foreign" end,
      function(value) value.browser_readiness_sha256 = nil end,
      function(value) value.test_plan_ref = ".testing/runs/foreign/test-plan.json" end,
      function(value) value.case_results_ref = nil end,
      function(value) value.browser_readiness_ref = nil value.browser_readiness_sha256 = nil end,
      function(value)
        value.defect_publication_receipt_ref = value.artifact_root .. "/defect-receipt.json"
      end,
    }
    for _, mutate in ipairs(request_mutations) do
      local value = request()
      local ports = runtime(nil, value)
      mutate(value)
      t.raises(function() qa_publication.prepare_final_report(value, ports) end)
    end

    local artifact_mutations = {
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.counts.failed = -1 end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.run_id = "foreign" end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.structured_plan_ref = "foreign" end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.browser_readiness_sha256 = nil end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.case_results_ref = value.artifact_root .. "/other.json" end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.interruption = "stopped" end,
      function(artifacts, value) artifacts[value.environment_receipt_ref].value.schema = "foreign" end,
      function(artifacts, value) artifacts[value.environment_receipt_ref].value.status = "blocked" end,
      function(artifacts, value) artifacts[value.browser_readiness_ref].value.source_ref.ref = "foreign" end,
      function(artifacts, value) artifacts[value.test_plan_ref].value.cases[2].case_id = "health" end,
      function(artifacts, value) artifacts[value.case_results_ref].value.plan_sha256 = string.rep("0", 64) end,
      function(artifacts, value) artifacts[value.case_results_ref].value.cases[1].evidence_ref = "foreign" end,
      function(artifacts, value) artifacts[value.terminal_summary_ref].value.counts.failed = 0 end,
    }
    for _, mutate in ipairs(artifact_mutations) do
      local ports = runtime(mutate)
      t.raises(function() qa_publication.prepare_final_report(request(), ports) end)
    end

    local terminal = terminal_request()
    local terminal_ports = runtime(function(artifacts, value)
      artifacts[value.environment_receipt_ref].value = environment_receipt(value, "blocked")
      artifacts[value.environment_receipt_ref].value.cleanup_receipt_ref = nil
    end, terminal)
    t.raises(function() qa_publication.prepare_final_report(terminal, terminal_ports) end)
  end,
}
