local structured_execution = require("structured_execution")
local t = fkst.test

local digest_a = string.rep("a", 64)
local digest_b = string.rep("b", 64)
local digest_c = string.rep("c", 64)

local function request()
  return {
    schema = "testing-runner.structured-execution.request.v1",
    repository = {
      url = "https://example.invalid/repository.git",
      commit_sha = string.rep("1", 40),
    },
    environment_receipt_ref = ".testing/runs/structured/environment-receipt.json",
    environment_receipt_sha256 = digest_a,
    test_plan_ref = ".testing/runs/structured/source-plan.json",
    test_plan_sha256 = digest_b,
    execution_approval_ref = ".testing/runs/structured/execution-approval.json",
    execution_approval_sha256 = digest_c,
    artifact_root = ".testing/runs/structured/execution",
    trace_id = "trace-structured",
    dedup_key = "dedup-structured",
    source_ref = { kind = "workflow-qa", ref = "run-110" },
  }
end

local function bound_attestation()
  return {
    approval_sha256 = digest_c,
    authority = { kind = "policy", ref = "testing-authority" },
    policy_revision = "policy-v1",
    evidence_ref = { kind = "attestation", ref = "approval-110" },
  }
end

local function single_case_artifact(path, expires_at)
  if path:find("environment%-receipt") then return { raw = "environment", digest = digest_a, value = {
    schema = "environment-factory.environment-result.v1", status = "ready", repository = request().repository,
    trace_id = "trace-structured", dedup_key = "dedup-structured",
  } } end
  if path:find("source%-plan") then return { raw = "plan", digest = digest_b, value = {
    schema = "testing-structured-plan.v1", repository = request().repository,
    environment_receipt_sha256 = digest_a,
    cases = { { case_id = "cli-version", kind = "cli", argv = { "fixture-cli", "--version" },
      timeout_seconds = 10, assertions = { { type = "exit-code", expected = 0 } } } },
  } } end
  return { raw = "approval", digest = digest_c, value = {
    schema = "testing-structured-execution-approval.v1", approval_id = "approval-110",
    plan_sha256 = digest_b, environment_receipt_sha256 = digest_a, repository = request().repository,
    cli_capabilities = { { argv_prefix = { "fixture-cli" } } }, http_capabilities = {},
    authority = { kind = "policy", ref = "testing-authority" }, policy_revision = "policy-v1",
    evidence_ref = { kind = "attestation", ref = "approval-110" },
    issued_at = "2026-07-20T00:00:00Z", expires_at = expires_at or "2026-07-20T01:00:00Z", max_uses = 1,
    trace_id = "trace-structured", dedup_key = "dedup-structured",
  } }
end

return {
  test_request_rejects_inline_plan_before_loading_artifacts = function()
    local loads = 0
    local invalid = request()
    invalid.repository.commit_sha = "main"
    invalid.test_plan = { cases = {} }
    local result = structured_execution.run(invalid, {
      load_artifact = function()
        loads = loads + 1
        error("must not load malformed request artifacts")
      end,
    })

    t.eq(result.status, "blocked")
    t.eq(result.classification, "harness-tooling-issue")
    t.eq(loads, 0)
  end,

  test_unauthenticated_plan_performs_zero_effects = function()
    local cli_calls = 0
    local http_calls = 0
    local result = structured_execution.run(request(), {
      load_artifact = function(path)
        if path:find("environment%-receipt") then
          return { raw = "environment", digest = digest_a, value = {
            schema = "environment-factory.environment-result.v1",
            status = "ready",
            repository = request().repository,
            trace_id = "trace-structured",
            dedup_key = "dedup-structured",
          } }
        end
        if path:find("source%-plan") then
          return { raw = "plan", digest = digest_b, value = {
            schema = "testing-structured-plan.v1",
            repository = request().repository,
            environment_receipt_sha256 = digest_a,
            cases = { {
              case_id = "cli-version",
              kind = "cli",
              argv = { "fixture-cli", "--version" },
              timeout_seconds = 10,
              assertions = { { type = "exit-code", expected = 0 } },
            } },
          } }
        end
        return { raw = "approval", digest = digest_c, value = {
          schema = "testing-structured-execution-approval.v1",
          approval_id = "approval-110",
          plan_sha256 = digest_b,
          environment_receipt_sha256 = digest_a,
          repository = request().repository,
          cli_capabilities = { { argv_prefix = { "fixture-cli" } } },
          http_capabilities = {},
          authority = { kind = "policy", ref = "testing-authority" },
          policy_revision = "policy-v1",
          evidence_ref = { kind = "attestation", ref = "approval-110" },
          issued_at = "2026-07-20T00:00:00Z",
          expires_at = "2026-07-20T01:00:00Z",
          max_uses = 1,
          trace_id = "trace-structured",
          dedup_key = "dedup-structured",
        } }
      end,
      now = function() return "2026-07-20T00:30:00Z" end,
      verify_approval = function() return false end,
      replay_guard = function() error("must not claim unauthorized work") end,
      exec_argv = function()
        cli_calls = cli_calls + 1
        return { exit_code = 0, stdout = "", stderr = "" }
      end,
      http_request = function()
        http_calls = http_calls + 1
        return { status = 200, body = "ok" }
      end,
      write_artifact = function() return true end,
      load_result = function() return nil end,
      complete_replay = function() return true end,
    })

    t.eq(result.status, "blocked")
    t.eq(result.classification, "harness-tooling-issue")
    t.eq(cli_calls, 0)
    t.eq(http_calls, 0)
  end,

  test_authorized_cli_and_http_cases_execute_in_plan_order = function()
    local writes = {}
    local effects = {}
    local completed
    local plan = {
      schema = "testing-structured-plan.v1",
      repository = request().repository,
      environment_receipt_sha256 = digest_a,
      cases = {
        {
          case_id = "cli-version",
          kind = "cli",
          argv = { "fixture-cli", "--version" },
          timeout_seconds = 10,
          assertions = { { type = "exit-code", expected = 0 } },
        },
        {
          case_id = "health-api",
          kind = "http",
          request = { method = "GET", url = "http://127.0.0.1:43110/health", headers = {} },
          timeout_seconds = 10,
          assertions = {
            { type = "status-code", expected = 200 },
            { type = "body-contains", expected = "healthy" },
          },
        },
      },
    }
    local approval = {
      schema = "testing-structured-execution-approval.v1",
      approval_id = "approval-110",
      plan_sha256 = digest_b,
      environment_receipt_sha256 = digest_a,
      repository = request().repository,
      cli_capabilities = { { argv_prefix = { "fixture-cli" } } },
      http_capabilities = { {
        origin = "http://127.0.0.1:43110",
        methods = { "GET" },
        path_prefixes = { "/health" },
      } },
      authority = { kind = "policy", ref = "testing-authority" },
      policy_revision = "policy-v1",
      evidence_ref = { kind = "attestation", ref = "approval-110" },
      issued_at = "2026-07-20T00:00:00Z",
      expires_at = "2026-07-20T01:00:00Z",
      max_uses = 1,
      trace_id = "trace-structured",
      dedup_key = "dedup-structured",
    }
    local result = structured_execution.run(request(), {
      load_artifact = function(path)
        if path:find("environment%-receipt") then
          return { raw = "environment", digest = digest_a, value = {
            schema = "environment-factory.environment-result.v1",
            status = "ready",
            repository = request().repository,
            trace_id = "trace-structured",
            dedup_key = "dedup-structured",
          } }
        end
        if path:find("source%-plan") then return { raw = "plan", digest = digest_b, value = plan } end
        return { raw = "approval", digest = digest_c, value = approval }
      end,
      now = function() return "2026-07-20T00:30:00Z" end,
      verify_approval = function(input)
        t.eq(input.approval_sha256, digest_c)
        t.eq(input.approval.authority.ref, "testing-authority")
        return {
          approval_sha256 = digest_c,
          authority = { kind = "policy", ref = "testing-authority" },
          policy_revision = "policy-v1",
          evidence_ref = { kind = "attestation", ref = "approval-110" },
        }
      end,
      replay_guard = function(claim)
        t.eq(claim.plan_sha256, digest_b)
        t.eq(claim.approval_id, "approval-110")
        return { status = "claimed", claim_id = "claim-110" }
      end,
      exec_argv = function(argv)
        table.insert(effects, "cli:" .. table.concat(argv, " "))
        return { exit_code = 0, stdout = "fixture 1.0\n", stderr = "" }
      end,
      http_request = function(value)
        table.insert(effects, "http:" .. value.method .. " " .. value.url)
        return { status = 200, body = '{"status":"healthy"}', headers = {} }
      end,
      write_artifact = function(path, value)
        writes[path] = value
        return true
      end,
      load_result = function() return nil end,
      complete_replay = function(claim, result_ref)
        completed = { claim = claim, result_ref = result_ref }
        return true
      end,
    })

    t.eq(result.status, "passed")
    t.eq(result.classification, "passed")
    t.eq(result.case_count, 2)
    t.eq(result.passed_count, 2)
    t.eq(result.failed_count, 0)
    t.eq(effects[1], "cli:fixture-cli --version")
    t.eq(effects[2], "http:GET http://127.0.0.1:43110/health")
    t.eq(result.case_results_path, request().artifact_root .. "/case-results.json")
    t.eq(result.execution_path, request().artifact_root .. "/execution.json")
    t.is_true(type(writes[result.case_results_path]) == "table")
    t.is_true(type(writes[result.execution_path]) == "table")
    t.eq(completed.claim.claim_id, "claim-110")
    t.eq(completed.result_ref, result.execution_path)
  end,

  test_expired_approval_fails_before_replay_claim_or_effect = function()
    local claims, effects = 0, 0
    local result = structured_execution.run(request(), {
      load_artifact = function(path) return single_case_artifact(path, "2026-07-20T00:10:00Z") end,
      now = function() return "2026-07-20T00:30:00Z" end,
      verify_approval = bound_attestation,
      replay_guard = function() claims = claims + 1 return { status = "claimed", claim_id = "late" } end,
      exec_argv = function() effects = effects + 1 return { exit_code = 0 } end,
      http_request = function() effects = effects + 1 return { status = 200 } end,
      write_artifact = function() return true end,
      load_result = function() return nil end,
      complete_replay = function() return true end,
    })
    t.eq(result.status, "blocked")
    t.eq(claims, 0)
    t.eq(effects, 0)
  end,

  test_unsupported_assertion_fails_before_replay_claim_or_effect = function()
    local claims, effects = 0, 0
    local result = structured_execution.run(request(), {
      load_artifact = function(path)
        local artifact = single_case_artifact(path)
        if path:find("source%-plan") then artifact.value.cases[1].assertions[1].type = "stdout-contains" end
        return artifact
      end,
      now = function() return "2026-07-20T00:30:00Z" end,
      verify_approval = bound_attestation,
      replay_guard = function() claims = claims + 1 return { status = "claimed", claim_id = "unsafe" } end,
      exec_argv = function() effects = effects + 1 return { exit_code = 0 } end,
      http_request = function() effects = effects + 1 return { status = 200 } end,
      write_artifact = function() return true end,
      load_result = function() return nil end,
      complete_replay = function() return true end,
    })
    t.eq(result.status, "blocked")
    t.eq(claims, 0)
    t.eq(effects, 0)
  end,

  test_completed_replay_reuses_result_without_effects_or_writes = function()
    local effects, writes = 0, 0
    local artifact_root = request().artifact_root
    local result = structured_execution.run(request(), {
      load_artifact = function(path) return single_case_artifact(path) end,
      now = function() return "2026-07-20T00:30:00Z" end,
      verify_approval = function() return bound_attestation() end,
      replay_guard = function() return { status = "completed", result_ref = artifact_root .. "/execution.json" } end,
      exec_argv = function() effects = effects + 1 return { exit_code = 0 } end,
      http_request = function() effects = effects + 1 return { status = 200 } end,
      write_artifact = function() writes = writes + 1 return true end,
      load_result = function()
        return {
          status = "passed", classification = "passed", case_count = 1, passed_count = 1,
          failed_count = 0, skipped_count = 0, error_count = 0,
          test_plan_path = artifact_root .. "/test-plan.json",
          case_results_path = artifact_root .. "/case-results.json",
          execution_path = artifact_root .. "/execution.json",
        }
      end,
      complete_replay = function() error("completed replay must not complete twice") end,
    })
    t.eq(result.status, "passed")
    t.eq(result.replayed, true)
    t.eq(effects, 0)
    t.eq(writes, 0)
  end,

  test_typed_skip_records_not_executed_risk_without_effect = function()
    local effects = 0
    local result = structured_execution.run(request(), {
      load_artifact = function(path)
        local artifact = single_case_artifact(path)
        if path:find("source%-plan") then
          artifact.value.cases[1].skip_reason = "fixture does not expose the optional command"
          artifact.value.cases[1].skip_classification = "not-executed-risk"
        end
        return artifact
      end,
      now = function() return "2026-07-20T00:30:00Z" end,
      verify_approval = function() return bound_attestation() end,
      replay_guard = function() return { status = "claimed", claim_id = "claim-skip" } end,
      exec_argv = function() effects = effects + 1 return { exit_code = 0 } end,
      http_request = function() effects = effects + 1 return { status = 200 } end,
      write_artifact = function() return true end,
      load_result = function() return nil end,
      complete_replay = function() return true end,
    })
    t.eq(result.status, "degraded")
    t.eq(result.classification, "not-executed-risk")
    t.eq(result.skipped_count, 1)
    t.eq(effects, 0)
  end,
}
