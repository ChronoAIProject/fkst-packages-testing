local department = require("departments.finalize_qa_run.main")
local testing = require("testkit.testing")
local t = fkst.test

local commit_sha = string.rep("1", 40)

local function run_finalize(channel)
    local root = ".testing/runs/qa-finalize-department"
    local plan_sha, results_sha = string.rep("b", 64), string.rep("c", 64)
    local environment_sha, cleanup_sha = string.rep("d", 64), string.rep("e", 64)
    local readiness_sha = string.rep("5", 64)
    local report_sha, terminal_sha = string.rep("f", 64), string.rep("6", 64)
    local trace_id, dedup_key = "trace-finalize-department", "dedup-finalize-department"
    local repository = { slug = "owner/repo", url = "https://github.com/owner/repo.git", commit_sha = commit_sha }
    local operation_state = { kind = "artifact", ref = root .. "/operation-state.json" }
    local readiness = {
      schema = "browser-readiness.result.v1", status = "ready",
      sessions = {
        { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
        { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } }, cdp_url = "http://127.0.0.1:9222" },
      },
      source_ref = operation_state, request_context = { dry_run = false },
      correlation = {
        schema = "environment-factory.browser-readiness-correlation.v1",
        attempt_id = "attempt-1", operation_id = "qa-finalize-department",
        operation_state_ref = operation_state,
        readiness_attempt_ref = { kind = "artifact", ref = root .. "/readiness-attempt.json" },
        readiness_attempt_sha256 = string.rep("a", 64),
        base_url = "http://127.0.0.1:4173/health",
        sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
        trace_id = trace_id, dedup_key = dedup_key,
      },
    }
    local state
    local writes = {}
    local artifacts = {
      [root .. "/terminal-summary.json"] = { digest = terminal_sha, value = {
        schema = "workflow-qa.terminal-summary.v2", status = "passed", repository = repository,
        run_id = "qa-finalize-department", phase = "cleanup-pending",
        counts = { planned = 1, executed = 1, passed = 1, failed = 0, skipped = 0, error = 0, blocked = 0 },
        environment_receipt_ref = root .. "/environment-receipt-ready.json",
        cleanup_receipt_ref = root .. "/cleanup-receipt-complete.json",
        browser_readiness_ref = root .. "/browser-readiness.json",
        browser_readiness_sha256 = readiness_sha,
        structured_plan_ref = root .. "/test-plan.json", case_results_ref = root .. "/case-results.json",
        trace_id = trace_id, dedup_key = dedup_key,
      } },
      [root .. "/test-plan.json"] = { digest = plan_sha, value = {
        schema = "testing-structured-plan.v2",
        execution_mode = "structured-api-cli",
        repository = { url = repository.url, commit_sha = commit_sha },
        environment_receipt_sha256 = environment_sha,
        browser_readiness_sha256 = readiness_sha,
        case_catalog_sha256 = string.rep("7", 64), module_plan_sha256 = string.rep("8", 64),
        cases = { {
          case_id = "health", kind = "http", timeout_seconds = 10,
          request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} },
          assertions = { { type = "status-code", expected = 200 } },
        } },
        residual_risk_case_ids = {}, trace_id = trace_id, dedup_key = dedup_key,
      } },
      [root .. "/case-results.json"] = { digest = results_sha, value = {
        schema = "testing-structured-case-results.v1", plan_sha256 = plan_sha,
        cases = { {
          case_id = "health", kind = "http", status = "passed", classification = "passed",
          assertions = { { type = "status-code", passed = true } },
          evidence_ref = root .. "/evidence/health.json",
        } },
      } },
      [root .. "/environment-receipt-ready.json"] = { digest = environment_sha, value = {
        schema = "environment-factory.receipt.v2", operation_id = "qa-finalize-department", status = "ready",
        profile_revision = "profile-v1", profile_sha256 = string.rep("9", 64),
        repository = { url = repository.url, commit_sha = commit_sha },
        workspace_ref = { kind = "workspace", ref = "qa-finalize-department-workspace" },
        base_url = "http://127.0.0.1:4173/health",
        runtime_ports = { { name = "application", port = 4173 } },
        sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
        browser_readiness = readiness, artifact_root = root, diagnostic_refs = {},
        cleanup_ref = { kind = "runtime-cleanup", ref = "qa-finalize-department-cleanup" },
        cleanup_status = "pending", trace_id = trace_id, dedup_key = dedup_key,
      } },
      [root .. "/browser-readiness.json"] = { digest = readiness_sha, value = {
        schema = readiness.schema, status = readiness.status, sessions = readiness.sessions,
        source_ref = { kind = "workflow-qa", ref = "qa-finalize-department" },
        request_context = readiness.request_context, correlation = readiness.correlation,
      } },
      [root .. "/cleanup-receipt-complete.json"] = { digest = cleanup_sha, value = {
        schema = "environment-factory.cleanup-receipt.v1", operation_id = "qa-finalize-department", status = "complete",
        attempted_resources = { { resource_id = "workspace", resource_kind = "workspace", status = "cleaned" } },
        verified_removals = { "workspace" }, remaining_resources = {}, artifact_root = root,
        trace_id = trace_id, dedup_key = dedup_key,
      } },
    }
    local trace = testing.run_fake(department, {
      queue = "qa_finalize_request",
      test_ports = {
        load_ledger = function() return state end,
        save_ledger = function(_, value) state = value return true end,
        load_artifact = function(path) return artifacts[path] end,
        write_artifact = function(path, value) writes[path] = value return true end,
        write_report = function(path, value)
          artifacts[path] = { digest = report_sha, value = value }
          return { status = "written", digest = report_sha }
        end,
        publish_artifact = function(value)
          if value.channel == "filesystem-dry-run-v1" then
            local receipt_ref = root .. "/materializations/" .. value.stage .. "-"
              .. tostring(value.attempt) .. ".json"
            local receipt_sha256 = string.rep("4", 64)
            artifacts[receipt_ref] = { digest = receipt_sha256, value = {
              schema = "test-publication.qa-materialization-receipt.v1",
              status = "materialized", channel = "filesystem-dry-run-v1",
              run_id = value.run_id, stage = value.stage, attempt = value.attempt,
              artifact_ref = value.artifact_ref, digest = value.digest,
              source_commit = commit_sha, receipt_ref = receipt_ref,
              trace_id = value.trace_id, dedup_key = value.dedup_key,
            } }
            return {
              status = "materialized", artifact_ref = value.artifact_ref,
              digest = value.digest, source_commit = commit_sha,
              receipt_ref = receipt_ref, receipt_sha256 = receipt_sha256,
            }
          end
          return {
            status = "published", digest = value.digest, source_commit = commit_sha,
            remote_url = "https://github.com/owner/repo/blob/" .. commit_sha .. "/qa/" .. value.stage .. ".json",
            receipt_ref = root .. "/publication/" .. value.stage .. "-1.json",
          }
        end,
      },
      payload = {
        schema = "test-publication.qa-finalize.request.v2",
        repository = { slug = "owner/repo", commit_sha = commit_sha },
        run_id = "qa-finalize-department", issue_number = 107, artifact_root = root,
        ledger_ref = root .. "/run-ledger.json",
        terminal_summary_ref = root .. "/terminal-summary.json", terminal_summary_sha256 = terminal_sha,
        test_plan_ref = root .. "/test-plan.json", test_plan_sha256 = plan_sha,
        case_results_ref = root .. "/case-results.json", case_results_sha256 = results_sha,
        environment_receipt_ref = root .. "/environment-receipt-ready.json",
        environment_receipt_sha256 = environment_sha,
        browser_readiness_ref = root .. "/browser-readiness.json",
        browser_readiness_sha256 = readiness_sha,
        cleanup_receipt_ref = root .. "/cleanup-receipt-complete.json",
        cleanup_receipt_sha256 = cleanup_sha,
        aggregate_report_ref = root .. "/aggregate-report.json",
        trace_id = trace_id, dedup_key = dedup_key,
        channel = channel,
      },
    })

    return trace, writes
end

return {
  test_finalize_department_raises_only_reconciled_host_github_request = function()
    local trace, writes = run_finalize()
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "github_issue_comment_request")
    t.eq(trace.raises[1].payload.schema, "github-proxy.v1")
    t.is_true(trace.raises[1].payload.body:find("planned=1 executed=1", 1, true) ~= nil)
    t.eq(next(writes), nil)
  end,

  test_finalize_department_raises_only_durable_filesystem_receipt = function()
    local trace, writes = run_finalize("filesystem-dry-run-v1")
    t.eq(#trace.raises, 1)
    t.eq(trace.raises[1].queue, "qa_publication_receipt")
    t.eq(trace.raises[1].payload.schema, "test-publication.qa-publication-receipt.v2")
    t.eq(trace.raises[1].payload.channel, "filesystem-dry-run-v1")
    t.eq(trace.raises[1].payload.github_publication_occurred, false)
    t.is_true(type(writes[trace.raises[1].payload.receipt_ref]) == "table")
  end,
}
