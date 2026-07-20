local acknowledge = require("departments.acknowledge_product_defect.main")
local publish = require("departments.publish_product_defects.main")
local testing = require("testkit.testing")
local t = fkst.test

local commit_sha = string.rep("1", 40)
local plan_sha = string.rep("a", 64)
local results_sha = string.rep("b", 64)
local drafts_sha = string.rep("c", 64)

local function request()
  local root = ".testing/runs/defect-department"
  return {
    schema = "test-publication.defect-publication.request.v1",
    publication = {
      schema = "test-publication.publication-request.v1",
      publication_kind = "testing-summary", channel = "testing", severity = "failure",
      subject = "Testing failed: structured-execution", status = "failed", job = "structured-execution",
      artifact_root = root, metadata_path = root .. "/metadata.json",
      test_plan_path = root .. "/test-plan.json", case_results_path = root .. "/case-results.json",
      execution_path = root .. "/execution.json", source_ref = { kind = "workflow-qa", ref = "run-99" },
      trace_id = "trace-defect-department", dedup_key = "publication-defect-department",
    },
    repository = { slug = "owner/repo", commit_sha = commit_sha },
    plan_sha256 = plan_sha,
    case_results_ref = root .. "/case-results.json", case_results_sha256 = results_sha,
    issue_drafts_ref = root .. "/defect-issue-drafts.json", issue_drafts_sha256 = drafts_sha,
    ledger_ref = root .. "/defect-publication-ledger.json",
    receipt_ref = root .. "/defect-publication-receipt.json",
    trace_id = "trace-defect-department", dedup_key = "dedup-defect-department",
  }
end

local function runtime(case_results, issue_drafts)
  local value = request()
  local ledger
  local artifacts = {
    [value.case_results_ref] = { digest = results_sha, value = {
      schema = "testing-structured-case-results.v1", plan_sha256 = plan_sha, cases = case_results,
    } },
    [value.issue_drafts_ref] = { digest = drafts_sha, value = {
      schema = "test-publication.defect-issue-drafts.v1", plan_sha256 = plan_sha, cases = issue_drafts,
    } },
  }
  return {
    load_ledger = function() return ledger end,
    save_ledger = function(_, next_ledger, expected)
      if ledger == nil and expected ~= 0 then return false end
      if ledger ~= nil and ledger.version ~= expected then return false end
      ledger = next_ledger
      return true
    end,
    load_artifact = function(path) return artifacts[path] end,
    write_artifact = function() return true end,
    ledger = function() return ledger end,
  }
end

local function defect(case_id)
  local root = request().publication.artifact_root
  return {
    case_id = case_id, kind = "cli", status = "failed", classification = "product-defect",
    assertions = { { type = "exit-code", passed = false } },
    evidence_ref = root .. "/evidence/" .. case_id .. ".json",
  }
end

local function draft(case_id)
  local root = request().publication.artifact_root
  return {
    case_id = case_id, title = case_id .. " differs", expected_summary = "Expected success",
    actual_summary = "Observed failure", evidence_ref = root .. "/evidence/" .. case_id .. ".json",
  }
end

local function run(department, queue, payload, ports)
  return testing.run_fake(department, {
    queue = queue, payload = payload, test_ports = ports,
  })
end

return {
  test_publish_department_emits_one_issue_intent_for_verified_product_defect = function()
    local ports = runtime({
      defect("version"),
      { case_id = "health", kind = "http", status = "error", classification = "environment-session-issue", assertions = {}, evidence_ref = request().publication.artifact_root .. "/evidence/health.json" },
    }, { draft("version") })
    local trace = run(publish, "defect_publication_request", request(), ports)

    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "github_issue_create_request")
    t.eq(trace.raises[1].payload.handoff.kind, "test-publication.product-defect")
  end,

  test_environment_only_run_emits_summary_receipt_and_terminal_without_issue = function()
    local root = request().publication.artifact_root
    local ports = runtime({ {
      case_id = "health", kind = "http", status = "error",
      classification = "environment-session-issue", assertions = {}, evidence_ref = root .. "/evidence/health.json",
    } }, {})
    local trace = run(publish, "defect_publication_request", request(), ports)

    t.eq(#trace.raises, 2)
    t.eq(trace.raises[1].queue, "defect_publication_receipt")
    t.eq(trace.raises[1].payload.cases[1].status, "summary-only")
    t.eq(trace.raises[2].queue, "defect_publication_terminal")
  end,

  test_ack_department_waits_for_every_issue_before_terminal = function()
    local ports = runtime({ defect("version"), defect("login") }, { draft("version"), draft("login") })
    local prepared = run(publish, "defect_publication_request", request(), ports)
    local first = prepared.raises[1].payload
    local trace = run(acknowledge, "github_issue_written", {
        schema = "github-proxy.issue-written.v1", status = "created", issue_number = 501,
        issue_url = "https://github.com/owner/repo/issues/501",
        request_dedup_key = first.dedup_key, handoff = first.handoff,
      }, ports)

    t.eq(#trace.raises, 0)
    t.eq(ports.ledger().cases.version.status, "created")
    t.eq(ports.ledger().cases.login.status, "pending")
  end,

  test_final_issue_ack_emits_durable_receipt_and_terminal = function()
    local ports = runtime({ defect("version") }, { draft("version") })
    local prepared = run(publish, "defect_publication_request", request(), ports)
    local intent = prepared.raises[1].payload
    local trace = run(acknowledge, "github_issue_written", {
        schema = "github-proxy.issue-written.v1", status = "deduplicated", issue_number = 501,
        issue_url = "https://github.com/owner/repo/issues/501",
        request_dedup_key = intent.dedup_key, handoff = intent.handoff,
      }, ports)

    t.eq(#trace.raises, 2)
    t.eq(trace.raises[1].queue, "defect_publication_receipt")
    t.eq(trace.raises[1].payload.cases[1].status, "deduplicated")
    t.eq(trace.raises[2].queue, "defect_publication_terminal")
    t.eq(trace.raises[2].payload.receipt_ref, request().receipt_ref)
  end,

  test_ack_department_rejects_foreign_handoff = function()
    local trace = testing.run_fake(acknowledge, {
      queue = "github_issue_written", payload = { handoff = { kind = "other-package" } },
    })
    t.eq(#trace.raises, 0)
  end,
}
