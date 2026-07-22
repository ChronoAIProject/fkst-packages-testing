local fixtures = require("tests.structured_execution_helpers")
local structured_execution = require("structured_execution")
local t = fkst.test

local function runtime(artifacts, options)
  options = options or {}
  local effects, writes = {}, {}
  local ports = {
    load_artifact = function(path) return artifacts[path] end,
    now = function() return options.now or "2026-07-20T00:30:00Z" end,
    verify_grant = function(input)
      if options.verify_grant then return options.verify_grant(input) end
      return fixtures.attestation()
    end,
    replay_guard = function(claim)
      if options.replay_guard then return options.replay_guard(claim) end
      return { status = "claimed", claim_id = "claim-110" }
    end,
    exec_argv = function(argv)
      table.insert(effects, "cli:" .. table.concat(argv, " "))
      if options.exec_error then error("cli unavailable") end
      return options.exec_result or { exit_code = 0, stdout = "fixture 1.0\n", stderr = "" }
    end,
    http_request = function(value)
      table.insert(effects, "http:" .. value.method .. " " .. value.url)
      if options.http_error then error("http unavailable") end
      return options.http_result or { status = 200, body = '{"status":"healthy"}', headers = {} }
    end,
    write_artifact = function(path, value)
      if options.write_artifact then return options.write_artifact(path, value, writes) end
      writes[path] = value
      return true
    end,
    load_result = function(path)
      if options.load_result then return options.load_result(path) end
    end,
    complete_replay = function(claim, result_ref)
      if options.complete_replay then return options.complete_replay(claim, result_ref) end
      return true
    end,
  }
  return ports, effects, writes
end

return {
  test_request_rejects_inline_plan_before_loading_artifacts = function()
    local loads = 0
    local request = fixtures.request()
    request.repository.commit_sha = "main"
    request.test_plan = { cases = {} }
    local result = structured_execution.run(request, {
      load_artifact = function()
        loads = loads + 1
        error("must not load malformed request artifacts")
      end,
    })
    t.eq(result.status, "blocked")
    t.eq(result.classification, "harness-tooling-issue")
    t.eq(loads, 0)
  end,

  test_unauthenticated_grant_performs_zero_effects = function()
    local request = fixtures.request()
    local claims = 0
    local ports, effects = runtime(fixtures.artifacts(request), {
      verify_grant = function() return false end,
      replay_guard = function()
        claims = claims + 1
        return { status = "claimed", claim_id = "unexpected" }
      end,
    })
    local result = structured_execution.run(request, ports)
    t.eq(result.status, "blocked")
    t.eq(claims, 0)
    t.eq(#effects, 0)
  end,

  test_authorized_cli_and_http_cases_execute_in_plan_order = function()
    local request = fixtures.request()
    local plan = fixtures.plan(request, {
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
    })
    local grant = fixtures.grant(request, {
      cli = { { argv_prefix = { "fixture-cli" } } },
      http = { {
        origin = "http://127.0.0.1:43110",
        methods = { "GET" },
        path_prefixes = { "/health" },
      } },
    })
    local completed
    local ports, effects, writes = runtime(fixtures.artifacts(request, plan, grant), {
      verify_grant = function(input)
        t.eq(input.grant_sha256, fixtures.digest_grant)
        t.eq(input.grant.authority.ref, "testing-authority")
        return fixtures.attestation()
      end,
      replay_guard = function(claim)
        t.eq(claim.plan_sha256, fixtures.digest_plan)
        t.eq(claim.grant_id, "grant-110")
        return { status = "claimed", claim_id = "claim-110" }
      end,
      complete_replay = function(claim, result_ref)
        completed = { claim = claim, result_ref = result_ref }
        return true
      end,
    })
    local result = structured_execution.run(request, ports)
    t.eq(result.status, "passed")
    t.eq(result.case_count, 2)
    t.eq(result.passed_count, 2)
    t.eq(effects[1], "cli:fixture-cli --version")
    t.eq(effects[2], "http:GET http://127.0.0.1:43110/health")
    t.is_true(type(writes[result.case_results_path]) == "table")
    t.is_true(type(writes[result.execution_path]) == "table")
    t.eq(completed.claim.claim_id, "claim-110")
    t.eq(completed.result_ref, result.execution_path)
  end,

  test_expired_grant_fails_before_replay_claim_or_effect = function()
    local request = fixtures.request()
    local grant = fixtures.grant(request, nil, "2026-07-20T00:10:00Z")
    local claims = 0
    local ports, effects = runtime(fixtures.artifacts(request, nil, grant), {
      replay_guard = function()
        claims = claims + 1
        return { status = "claimed", claim_id = "late" }
      end,
    })
    local result = structured_execution.run(request, ports)
    t.eq(result.status, "blocked")
    t.eq(claims, 0)
    t.eq(#effects, 0)
  end,

  test_malformed_plan_fails_before_replay_claim_or_effect = function()
    local request = fixtures.request()
    local plan = fixtures.plan(request)
    plan.cases[1].assertions[1].type = "stdout-contains"
    local claims = 0
    local ports, effects = runtime(fixtures.artifacts(request, plan), {
      replay_guard = function()
        claims = claims + 1
        return { status = "claimed", claim_id = "unsafe" }
      end,
    })
    local result = structured_execution.run(request, ports)
    t.eq(result.status, "blocked")
    t.eq(claims, 0)
    t.eq(#effects, 0)
  end,

  test_completed_replay_reuses_result_without_effects_or_writes = function()
    local request = fixtures.request()
    local writes = 0
    local ports, effects = runtime(fixtures.artifacts(request), {
      replay_guard = function()
        return { status = "completed", result_ref = request.artifact_root .. "/execution.json" }
      end,
      load_result = function()
        return {
          status = "passed", classification = "passed", case_count = 1, passed_count = 1,
          failed_count = 0, skipped_count = 0, error_count = 0,
          test_plan_path = request.artifact_root .. "/test-plan.json",
          case_results_path = request.artifact_root .. "/case-results.json",
          execution_path = request.artifact_root .. "/execution.json",
        }
      end,
      write_artifact = function()
        writes = writes + 1
        return true
      end,
      complete_replay = function() error("completed replay must not complete twice") end,
    })
    local result = structured_execution.run(request, ports)
    t.eq(result.status, "passed")
    t.eq(result.replayed, true)
    t.eq(#effects, 0)
    t.eq(writes, 0)
  end,

  test_typed_skip_records_not_executed_risk_without_effect = function()
    local request = fixtures.request()
    local plan = fixtures.plan(request)
    plan.cases[1].skip_reason = "fixture does not expose the optional command"
    plan.cases[1].skip_classification = "not-executed-risk"
    local ports, effects = runtime(fixtures.artifacts(request, plan))
    local result = structured_execution.run(request, ports)
    t.eq(result.status, "degraded")
    t.eq(result.classification, "not-executed-risk")
    t.eq(result.skipped_count, 1)
    t.eq(#effects, 0)
  end,
}
