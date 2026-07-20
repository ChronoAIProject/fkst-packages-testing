local department = require("departments.finalize_qa_run.main")
local testing = require("testkit.testing")
local t = fkst.test

local commit_sha = string.rep("1", 40)

return {
  test_finalize_department_raises_reconciled_host_github_request = function()
    local root = ".testing/runs/qa-finalize-department"
    local plan_sha, results_sha = string.rep("b", 64), string.rep("c", 64)
    local environment_sha, cleanup_sha, report_sha = string.rep("d", 64), string.rep("e", 64), string.rep("f", 64)
    local state
    local artifacts = {
      [root .. "/test-plan.json"] = { digest = plan_sha, value = {
        schema = "testing-structured-plan.v1", cases = { { case_id = "health", kind = "http" } },
      } },
      [root .. "/case-results.json"] = { digest = results_sha, value = {
        schema = "testing-structured-case-results.v1", plan_sha256 = plan_sha,
        cases = { { case_id = "health", kind = "http", status = "passed", classification = "passed", evidence_ref = root .. "/evidence/health.json" } },
      } },
      [root .. "/environment-receipt-ready.json"] = { digest = environment_sha, value = {
        schema = "environment-factory.environment-result.v1", status = "ready",
      } },
      [root .. "/environment-receipt-finalized.json"] = { digest = cleanup_sha, value = {
        schema = "environment-factory.result.v1", status = "finalized",
      } },
    }
    local trace = testing.run_fake(department, {
      queue = "qa_finalize_request",
      test_ports = {
        load_ledger = function() return state end,
        save_ledger = function(_, value) state = value return true end,
        load_artifact = function(path) return artifacts[path] end,
        write_artifact = function() return true end,
        write_report = function() return { status = "written", digest = report_sha } end,
        publish_artifact = function(value)
          return {
            status = "published", digest = value.digest, source_commit = commit_sha,
            remote_url = "https://github.com/owner/repo/blob/" .. commit_sha .. "/qa/" .. value.stage .. ".json",
            receipt_ref = root .. "/publication/" .. value.stage .. "-1.json",
          }
        end,
      },
      payload = {
        schema = "test-publication.qa-finalize.request.v1",
        repository = { slug = "owner/repo", commit_sha = commit_sha },
        run_id = "qa-finalize-department", issue_number = 107, artifact_root = root,
        ledger_ref = root .. "/run-ledger.json",
        test_plan_ref = root .. "/test-plan.json", test_plan_sha256 = plan_sha,
        case_results_ref = root .. "/case-results.json", case_results_sha256 = results_sha,
        environment_receipt_ref = root .. "/environment-receipt-ready.json",
        environment_receipt_sha256 = environment_sha,
        cleanup_receipt_ref = root .. "/environment-receipt-finalized.json",
        cleanup_receipt_sha256 = cleanup_sha,
        aggregate_report_ref = root .. "/aggregate-report.json",
        trace_id = "trace-finalize-department", dedup_key = "dedup-finalize-department",
      },
    })

    t.eq(trace.raises[1].queue, "github_issue_comment_request")
    t.eq(trace.raises[1].payload.schema, "github-proxy.v1")
    t.is_true(trace.raises[1].payload.body:find("planned=1 executed=1", 1, true) ~= nil)
  end,
}
