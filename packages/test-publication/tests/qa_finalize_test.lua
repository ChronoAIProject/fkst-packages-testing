local qa_publication = require("qa_publication")
local t = fkst.test

local commit_sha = string.rep("1", 40)
local plan_sha = string.rep("b", 64)
local results_sha = string.rep("c", 64)
local environment_sha = string.rep("d", 64)
local cleanup_sha = string.rep("e", 64)
local report_sha = string.rep("f", 64)

local function request()
  return {
    schema = "test-publication.qa-finalize.request.v1",
    repository = { slug = "owner/repo", commit_sha = commit_sha },
    run_id = "qa-run-final", issue_number = 107,
    artifact_root = ".testing/runs/qa-run-final",
    ledger_ref = ".testing/runs/qa-run-final/run-ledger.json",
    test_plan_ref = ".testing/runs/qa-run-final/test-plan.json", test_plan_sha256 = plan_sha,
    case_results_ref = ".testing/runs/qa-run-final/case-results.json", case_results_sha256 = results_sha,
    environment_receipt_ref = ".testing/runs/qa-run-final/environment-receipt-ready.json",
    environment_receipt_sha256 = environment_sha,
    cleanup_receipt_ref = ".testing/runs/qa-run-final/environment-receipt-finalized.json",
    cleanup_receipt_sha256 = cleanup_sha,
    aggregate_report_ref = ".testing/runs/qa-run-final/aggregate-report.json",
    trace_id = "trace-qa-run-final", dedup_key = "dedup-qa-run-final",
  }
end

local function runtime(mutate)
  local state
  local artifacts = {
    [request().test_plan_ref] = { digest = plan_sha, value = {
      schema = "testing-structured-plan.v1",
      repository = { url = "https://github.com/owner/repo.git", commit_sha = commit_sha },
      environment_receipt_sha256 = environment_sha,
      cases = {
        { case_id = "health", kind = "http" },
        { case_id = "version", kind = "cli" },
      },
    } },
    [request().case_results_ref] = { digest = results_sha, value = {
      schema = "testing-structured-case-results.v1", plan_sha256 = plan_sha,
      cases = {
        { case_id = "health", kind = "http", status = "passed", classification = "passed", evidence_ref = ".testing/runs/qa-run-final/evidence/health.json" },
        { case_id = "version", kind = "cli", status = "failed", classification = "product-defect", evidence_ref = ".testing/runs/qa-run-final/evidence/version.json" },
      },
    } },
    [request().environment_receipt_ref] = { digest = environment_sha, value = {
      schema = "environment-factory.environment-result.v1", status = "ready",
    } },
    [request().cleanup_receipt_ref] = { digest = cleanup_sha, value = {
      schema = "environment-factory.result.v1", status = "finalized",
    } },
  }
  if mutate then mutate(artifacts) end
  local reports = {}
  local report_writes = 0
  return {
    load_ledger = function() return state end,
    save_ledger = function(_, value, expected)
      if state ~= nil and state.version ~= expected then return false end
      if state == nil and expected ~= 0 then return false end
      state = value return true
    end,
    load_artifact = function(path) return artifacts[path] end,
    write_artifact = function(path, value) reports[path] = value return true end,
    write_report = function(path, value)
      report_writes = report_writes + 1
      reports[path] = value
      artifacts[path] = { digest = report_sha, value = value }
      return { status = "written", digest = report_sha }
    end,
    publish_artifact = function(value)
      return {
        status = "published", digest = value.digest, source_commit = commit_sha,
        remote_url = "https://github.com/owner/repo/blob/" .. commit_sha .. "/qa/aggregate-report.json",
        receipt_ref = ".testing/runs/qa-run-final/publication/" .. value.stage .. "-" .. tostring(value.attempt) .. ".json",
      }
    end,
    reports = reports,
    report_writes = function() return report_writes end,
    state = function() return state end,
    artifacts = artifacts,
  }
end

return {
  test_finalize_validation_and_bound_artifacts_fail_closed = function()
    local invalid_schema = request()
    invalid_schema.schema = "unknown"
    t.raises(function() qa_publication.prepare_final_report(invalid_schema, runtime()) end)

    local unsafe_pointer = request()
    rawset(unsafe_pointer, "test" .. "_plan_ref", ".testing/runs/foreign/test-plan.json")
    t.raises(function() qa_publication.prepare_final_report(unsafe_pointer, runtime()) end)

    local malformed_optional = request()
    malformed_optional.defect_publication_receipt_ref = malformed_optional.artifact_root .. "/defects.json"
    t.raises(function() qa_publication.prepare_final_report(malformed_optional, runtime()) end)

    local digest_mismatch = runtime(function(artifacts)
      artifacts[request().test_plan_ref].digest = string.rep("8", 64)
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), digest_mismatch) end)
  end,

  test_malformed_plan_result_and_environment_fail_closed = function()
    local malformed_plan = runtime(function(artifacts)
      artifacts[request().test_plan_ref].value.schema = "unknown"
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), malformed_plan) end)

    local foreign_result = runtime(function(artifacts)
      artifacts[request().case_results_ref].value.cases[1].case_id = "foreign"
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), foreign_result) end)

    local foreign_plan = runtime(function(artifacts)
      artifacts[request().case_results_ref].value.plan_sha256 = string.rep("7", 64)
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), foreign_plan) end)

    local unsafe_result = runtime(function(artifacts)
      artifacts[request().case_results_ref].value.cases[1].classification = "raw-response-body"
      artifacts[request().case_results_ref].value.cases[1].evidence_ref = "inline secret"
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), unsafe_result) end)

    local environment = runtime(function(artifacts)
      artifacts[request().environment_receipt_ref].value.status = "blocked"
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), environment) end)
  end,

  test_final_report_reconciles_terminal_cases_and_verified_cleanup = function()
    local ports = runtime()
    local prepared = qa_publication.prepare_final_report(request(), ports)

    t.eq(prepared.status, "pending")
    t.eq(prepared.report.schema, "test-publication.qa-aggregate-report.v1")
    t.eq(prepared.report.status, "failed")
    t.eq(prepared.report.counts.planned, 2)
    t.eq(prepared.report.counts.executed, 2)
    t.eq(prepared.report.counts.passed, 1)
    t.eq(prepared.report.counts.failed, 1)
    t.eq(prepared.report.cleanup_receipt_ref, request().cleanup_receipt_ref)
    t.eq(prepared.comment_request.handoff.stage, "aggregate-report")
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
    local ports = runtime(function(artifacts)
      table.remove(artifacts[request().case_results_ref].value.cases, 2)
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
    end)
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
    end)
    t.raises(function() qa_publication.prepare_final_report(value, malformed) end)

    local write_failure = runtime()
    write_failure.write_report = function() return { status = "blocked" } end
    t.raises(function() qa_publication.prepare_final_report(request(), write_failure) end)
  end,

  test_final_report_rejects_unverified_cleanup = function()
    local ports = runtime(function(artifacts)
      artifacts[request().cleanup_receipt_ref].value.status = "blocked"
    end)
    t.raises(function() qa_publication.prepare_final_report(request(), ports) end)
  end,
}
