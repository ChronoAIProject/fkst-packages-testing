local department = require("departments.run_structured_execution.main")
local testing = require("testkit.testing")
local t = fkst.test

local digest_a = string.rep("a", 64)
local digest_b = string.rep("b", 64)
local digest_c = string.rep("c", 64)
local repository = { url = "https://example.invalid/repository.git", commit_sha = string.rep("1", 40) }

return {
  test_namespaced_structured_request_raises_pipeline_testing_result = function()
    local writes = {}
    local test_ports = {
      load_artifact = function(path)
        if path:find("environment%-receipt") then return { raw = "environment", digest = digest_a, value = {
          schema = "environment-factory.environment-result.v1", status = "ready", repository = repository,
          trace_id = "trace-structured", dedup_key = "dedup-structured",
        } } end
        if path:find("source%-plan") then return { raw = "plan", digest = digest_b, value = {
          schema = "testing-structured-plan.v1", repository = repository, environment_receipt_sha256 = digest_a,
          cases = { { case_id = "cli-version", kind = "cli", argv = { "fixture-cli", "--version" },
            timeout_seconds = 10, assertions = { { type = "exit-code", expected = 0 } } } },
        } } end
        return { raw = "approval", digest = digest_c, value = {
          schema = "testing-structured-execution-approval.v1", approval_id = "approval-110",
          plan_sha256 = digest_b, environment_receipt_sha256 = digest_a, repository = repository,
          cli_capabilities = { { argv_prefix = { "fixture-cli" } } }, http_capabilities = {},
          authority = { kind = "policy", ref = "testing-authority" }, policy_revision = "policy-v1",
          evidence_ref = { kind = "attestation", ref = "approval-110" },
          issued_at = "2026-07-20T00:00:00Z", expires_at = "2026-07-20T01:00:00Z", max_uses = 1,
          trace_id = "trace-structured", dedup_key = "dedup-structured",
        } }
      end,
      now = function() return "2026-07-20T00:30:00Z" end,
      verify_approval = function()
        return {
          approval_sha256 = digest_c,
          authority = { kind = "policy", ref = "testing-authority" },
          policy_revision = "policy-v1",
          evidence_ref = { kind = "attestation", ref = "approval-110" },
        }
      end,
      replay_guard = function() return { status = "claimed", claim_id = "claim-110" } end,
      exec_argv = function() return { exit_code = 0, stdout = "fixture 1.0", stderr = "" } end,
      http_request = function() error("unexpected HTTP request") end,
      write_artifact = function(path, value) writes[path] = value return true end,
      load_result = function() return nil end,
      complete_replay = function() return true end,
    }

    local trace = testing.run_fake(department, {
      queue = "structured_execution_request",
      test_ports = test_ports,
      payload = {
        schema = "testing-runner.structured-execution.request.v1", repository = repository,
        environment_receipt_ref = ".testing/runs/structured/environment-receipt.json",
        environment_receipt_sha256 = digest_a,
        test_plan_ref = ".testing/runs/structured/source-plan.json", test_plan_sha256 = digest_b,
        execution_approval_ref = ".testing/runs/structured/execution-approval.json",
        execution_approval_sha256 = digest_c, artifact_root = ".testing/runs/structured/execution",
        trace_id = "trace-structured", dedup_key = "dedup-structured",
        source_ref = { kind = "workflow-qa", ref = "run-110" },
      },
    })
    t.eq(trace.raises[1].queue, "testing_result")
    local result = trace.raises[1].payload
    t.eq(result.schema, "testing-runner.result.v1")
    t.eq(result.job, "structured-execution")
    t.eq(result.status, "passed")
    t.eq(result.trace_id, "trace-structured")
    t.eq(result.dedup_key, "dedup-structured")
    t.eq(result.native_summary.schema, "testing-runner.structured-execution-summary.v1")
    t.eq(result.native_summary.case_results_path, result.artifact_root .. "/case-results.json")
    t.is_true(type(writes[result.artifact_root .. "/metadata.json"]) == "table")
  end,
}
