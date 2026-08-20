local manifest_contract = require("contract.testing_evidence_manifest")
local compat = require("contract.testing_results_compat")
local fixtures = require("tests.structured_execution_helpers")
local json = require("testing_runtime.json")
local sha256_bytes = require("tests.fixtures.sha256_helpers")
local structured_execution = require("structured_execution")
local t = fkst.test

local function runtime(artifacts, options)
  options = options or {}
  local effects, writes, now_index = {}, {}, 0
  local ports = {
    sha256_bytes = options.sha256_bytes or sha256_bytes,
    load_artifact = function(path)
      if options.load_artifact then
        local handled, value = options.load_artifact(path, artifacts)
        if handled then return value end
      end
      return artifacts[path]
    end,
    now = function(input)
      if options.now_request then options.now_request(input) end
      if type(options.now) == "table" then
        now_index = now_index + 1
        return options.now[now_index] or options.now[#options.now]
      end
      return options.now or "2026-07-20T00:30:00Z"
    end,

    verify_grant = function(input)
      if options.verify_grant then return options.verify_grant(input) end
      return fixtures.attestation()
    end,
    replay_guard = function(claim)
      if options.replay_guard then return options.replay_guard(claim) end
      return { status = "claimed", claim_id = "claim-110" }
    end,
    authorize_cli_effect = function(input)
      if options.authorize_cli_effect then return options.authorize_cli_effect(input) end
      return fixtures.authorization_receipt(input.action_envelope)
    end,
    exec_argv = function(input)
      table.insert(effects, { kind = "cli", request = input })
      if options.exec_error then error("cli unavailable") end
      return options.exec_result or { exit_code = 0, stdout = "fixture 1.0\n", stderr = "" }
    end,
    http_request = function(input)
      table.insert(effects, { kind = "http", request = input })
      if options.http_error then error("http unavailable") end
      return options.http_result or { status = 200, body = '{"status":"healthy"}', headers = {} }
    end,
    write_artifact = function(path, value)
      if options.write_artifact then return options.write_artifact(path, value, writes, artifacts) end
      fixtures.persist_write(artifacts, writes, path, value)
      return true
    end,
    load_result = function(input)
      if options.load_result then return options.load_result(input) end
    end,
    complete_replay = function(input)
      if options.complete_replay then return options.complete_replay(input) end
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

  test_divergent_run_identity_fails_before_loading_or_effects = function()
    local request = fixtures.request()
    request.source_ref.ref = "foreign-run"
    local loads = 0
    local result = structured_execution.run(request, {
      load_artifact = function()
        loads = loads + 1
        error("must not load artifacts for a foreign run")
      end,
    })
    t.eq(result.status, "blocked")
    t.eq(result.classification, "harness-tooling-issue")
    t.eq(loads, 0)
  end,

  test_overlong_matching_run_identity_fails_before_loading_or_claim = function()
    local run_id = string.rep("r", 181)
    local request = fixtures.request(".testing/runs/" .. run_id, run_id)
    local loads, claims = 0, 0
    local result = structured_execution.run(request, {
      load_artifact = function()
        loads = loads + 1
        error("must not load artifacts for an overlong run")
      end,
      replay_guard = function()
        claims = claims + 1
        error("must not claim an overlong run")
      end,
    })
    t.eq(result.status, "blocked")
    t.eq(result.classification, "harness-tooling-issue")
    t.eq(loads, 0)
    t.eq(claims, 0)
  end,

  test_foreign_environment_operation_fails_before_replay_claim_or_effect = function()
    local request = fixtures.request()
    local artifacts = fixtures.artifacts(request)
    artifacts[request.environment_receipt_ref].value.operation_id = "foreign-operation"
    local claims = 0
    local ports, effects = runtime(artifacts, {
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

  test_local_pep_denial_records_receipt_and_performs_zero_cli_effects = function()
    local request = fixtures.request()
    local ports, effects, writes = runtime(fixtures.artifacts(request), {
      authorize_cli_effect = function(input)
        return fixtures.authorization_receipt(input.action_envelope, "deny", "scope-denied")
      end,
    })
    local result = structured_execution.run(request, ports)
    t.eq(result.status, "blocked")
    t.eq(result.error_count, 1)
    t.eq(#effects, 0)
    local receipt_path = request.artifact_root .. "/authorization/cli-version.json"
    t.eq(writes[receipt_path].decision, "deny")
  end,

  test_unpersisted_local_pep_receipt_blocks_before_cli_effect = function()
    local request = fixtures.request()
    local ports, effects = runtime(fixtures.artifacts(request), {
      write_artifact = function(path, value, writes, artifacts)
        if path == request.artifact_root .. "/authorization/cli-version.json" then return false end
        fixtures.persist_write(artifacts, writes, path, value)
        return true
      end,
    })
    local result = structured_execution.run(request, ports)
    t.eq(result.status, "blocked")
    t.eq(result.classification, "harness-tooling-issue")
    t.is_true(result.message:find("malformed CLI authorization receipt", 1, true) ~= nil)
    t.eq(#effects, 0)
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
        request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} },
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
        origin = "http://127.0.0.1:4173",
        methods = { "GET" },
        path_prefixes = { "/health" },
      } },
    })
    local completed
    local artifacts = fixtures.artifacts(request, plan, grant)
    local ports, effects, writes = runtime(artifacts, {
      now = {
        "2026-07-20T00:30:00Z", "2026-07-20T00:30:01Z", "2026-07-20T00:30:02Z",
        "2026-07-20T00:30:03Z", "2026-07-20T00:30:05Z",
      },
      verify_grant = function(input)
        t.eq(input.grant_sha256, fixtures.digest_grant)
        t.eq(input.grant.authority.ref, "testing-authority")
        return fixtures.attestation()
      end,
      replay_guard = function(claim)
        t.eq(claim.plan_sha256, request.test_plan_sha256)
        t.eq(claim.grant_id, "grant-110")
        return { status = "claimed", claim_id = "claim-110" }
      end,
      complete_replay = function(input)
        completed = input
        return true
      end,
    })
    local result = structured_execution.run(request, ports)
    t.eq(result.status, "passed")
    t.eq(result.case_count, 2)
    t.eq(result.passed_count, 2)
    t.eq(effects[1].kind, "cli")
    t.eq(effects[1].request.action_envelope.operation_id, request.source_ref.ref)
    t.eq(effects[1].request.action_envelope.workspace_ref.kind, "workspace")
    t.eq(effects[1].request.action_envelope.repository.commit_sha, request.repository.commit_sha)
    t.eq(effects[1].request.action_envelope.case.argv[2], "--version")
    t.eq(effects[2].kind, "http")
    t.eq(effects[2].request.base_url, "http://127.0.0.1:4173/health")
    t.eq(effects[2].request.request.url, "http://127.0.0.1:4173/health")
    local set = writes[result.case_result_set_path]
    local manifest = writes[result.evidence_manifest_path]
    local legacy = writes[result.case_results_path]
    t.eq(set.schema, "testing-case-result-set.v2")
    t.eq(set.run_id, request.source_ref.ref)
    t.eq(set.set_id, request.source_ref.ref)
    t.eq(set.run_id, request.artifact_root:match("^%.testing/runs/([^/]+)"))
    t.eq(set.evidence_manifest_artifact_sha256, artifacts[result.evidence_manifest_path].digest)
    t.eq(set.evidence_manifest_ref.sha256, set.evidence_manifest_artifact_sha256)
    t.eq(set.cases[1].case_id, "cli-version")
    t.eq(set.cases[2].case_id, "health-api")
    t.eq(set.cases[1].repository.source_sha256,
      sha256_bytes(request.repository.url .. "\n" .. request.repository.commit_sha))
    t.eq(set.cases[1].assertions[1].required, true)
    t.eq(set.cases[1].assertions[1].status, "passed")
    t.eq(set.cases[2].assertions[2].assertion_id, "assertion-2")
    t.eq(set.cases[1].timing.duration_ms, 1000)
    t.eq(set.cases[2].timing.duration_ms, 2000)
    t.eq(manifest.schema, "testing-evidence-manifest.v1")
    t.eq(#manifest.entries, 2)
    t.eq(manifest.entries[1].artifact_ref.ref, request.artifact_root .. "/evidence/cli-version.json")
    t.eq(manifest.entries[1].sha256, artifacts[manifest.entries[1].artifact_ref.ref].digest)
    t.eq(manifest.entries[1].size_bytes, #artifacts[manifest.entries[1].artifact_ref.ref].raw)
    t.eq(manifest.entries[1].provenance.source_sha256, manifest.entries[1].sha256)
    t.eq(manifest.canonical_sha256,
      manifest_contract.sha256(manifest, sha256_bytes, { artifact_root = request.artifact_root }))
    t.eq(artifacts[result.evidence_manifest_path].digest == manifest.canonical_sha256, false)
    local projected = compat.project_v1(set, manifest, {
      artifact_root = request.artifact_root, plan_sha256 = request.test_plan_sha256, plan = plan,
      repository = set.cases[1].repository, run_id = request.source_ref.ref, plan_ref = set.plan_ref,
      trace_id = request.trace_id, dedup_key = request.dedup_key, sha256_bytes = sha256_bytes,
    })
    t.eq(json.encode(projected), json.encode(legacy))
    t.eq(writes[result.execution_path].case_result_set_artifact_sha256,
      artifacts[result.case_result_set_path].digest)
    t.eq(writes[result.execution_path].evidence_manifest_artifact_sha256,
      artifacts[result.evidence_manifest_path].digest)
    t.eq(completed.claim.claim_id, "claim-110")
    t.eq(completed.result_ref, result.execution_path)
  end,

  test_http_assertion_failure_is_canonical_and_projects_to_v1 = function()
    local request = fixtures.request()
    local plan = fixtures.plan(request, { {
      case_id = "health-api", kind = "http",
      request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} },
      timeout_seconds = 10, assertions = { { type = "status-code", expected = 200 } },
    } })
    local grant = fixtures.grant(request, { cli = {}, http = { {
      origin = "http://127.0.0.1:4173", methods = { "GET" }, path_prefixes = { "/health" },
    } } })
    local ports, _, writes = runtime(fixtures.artifacts(request, plan, grant), {
      http_result = { status = 503, body = '{"status":"unavailable"}', headers = {} },
    })
    local result = structured_execution.run(request, ports)
    local set = writes[result.case_result_set_path]
    local legacy = writes[result.case_results_path]
    local manifest = writes[result.evidence_manifest_path]
    t.eq(result.status, "failed")
    t.eq(set.cases[1].execution_status, "failed")
    t.eq(set.cases[1].classification, "assertion_failure")
    t.eq(set.cases[1].assertions[1].status, "failed")
    t.eq(legacy.cases[1].assertions[1].passed, false)
    t.eq(#manifest.entries, 1)
    t.eq(manifest.entries[1].case_id, "health-api")
  end,

  test_malformed_effect_response_emits_canonical_error_and_legacy_projection = function()
    local request = fixtures.request()
    local ports, _, writes = runtime(fixtures.artifacts(request), { exec_result = "invalid-response" })
    local result = structured_execution.run(request, ports)
    local set = writes[result.case_result_set_path]
    local legacy = writes[result.case_results_path]
    t.eq(result.status, "blocked")
    t.eq(set.cases[1].execution_status, "error")
    t.eq(set.cases[1].assertions[1].status, "skipped")
    t.is_true(set.cases[1].error.message:find("malformed response", 1, true) ~= nil)
    t.eq(#legacy.cases[1].assertions, 0)
  end,

  test_malformed_table_effect_responses_cannot_pass_or_report_product_defects = function()
    local request = fixtures.request()
    local ports, _, writes = runtime(fixtures.artifacts(request), { exec_result = {} })
    local result = structured_execution.run(request, ports)
    t.eq(writes[result.case_result_set_path].cases[1].execution_status, "error")

    request = fixtures.request()
    local plan = fixtures.plan(request, { {
      case_id = "health-api", kind = "http",
      request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} },
      timeout_seconds = 10, assertions = { { type = "status-code", expected = 200 } },
    } })
    local grant = fixtures.grant(request, { cli = {}, http = { {
      origin = "http://127.0.0.1:4173", methods = { "GET" }, path_prefixes = { "/health" },
    } } })
    ports, _, writes = runtime(fixtures.artifacts(request, plan, grant), {
      http_result = { status = 200, headers = {} },
    })
    result = structured_execution.run(request, ports)
    t.eq(writes[result.case_result_set_path].cases[1].execution_status, "error")
  end,

  test_persisted_raw_digest_mismatch_fails_before_completion = function()
    local request = fixtures.request()
    local completed = 0
    local ports = runtime(fixtures.artifacts(request), {
      write_artifact = function(path, value, writes, artifacts)
        fixtures.persist_write(artifacts, writes, path, value)
        artifacts[path].digest = string.rep("0", 64)
        return true
      end,
      complete_replay = function() completed = completed + 1 return true end,
    })
    local result = structured_execution.run(request, ports)
    t.eq(result.status, "blocked")
    t.eq(completed, 0)
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

  test_canonical_failed_skipped_and_error_outcomes_project_to_v1 = function()
    local function run_outcome(mutate, options)
      local request = fixtures.request()
      local plan = fixtures.plan(request)
      if mutate then mutate(plan) end
      local artifacts = fixtures.artifacts(request, plan)
      local ports, effects, writes = runtime(artifacts, options)
      local result = structured_execution.run(request, ports)
      return result, writes[result.case_result_set_path], writes[result.case_results_path], effects
    end

    local failed, failed_set, failed_v1 = run_outcome(nil, {
      exec_result = { exit_code = 1, stdout = "", stderr = "failed" },
    })
    t.eq(failed.status, "failed")
    t.eq(failed_set.cases[1].execution_status, "failed")
    t.eq(failed_set.cases[1].classification, "assertion_failure")
    t.eq(failed_set.cases[1].assertions[1].status, "failed")
    t.eq(failed_set.cases[1].assertions[1].required, true)
    t.eq(failed_v1.cases[1].status, "failed")
    t.eq(failed_v1.cases[1].assertions[1].passed, false)

    local skipped, skipped_set, skipped_v1, skipped_effects = run_outcome(function(plan)
      plan.cases[1].skip_reason = "fixture does not expose the optional command"
      plan.cases[1].skip_classification = "not-executed-risk"
    end)
    t.eq(skipped.status, "degraded")
    t.eq(#skipped_effects, 0)
    t.eq(skipped_set.cases[1].execution_status, "skipped")
    t.eq(skipped_set.cases[1].classification, "not_applicable")
    t.eq(skipped_set.cases[1].non_execution_reason, "not-executed-risk")
    t.eq(skipped_set.cases[1].assertions[1].status, "skipped")
    t.eq(skipped_set.cases[1].assertions[1].required, true)
    t.eq(#skipped_v1.cases[1].assertions, 0)

    local errored, error_set, error_v1, error_effects = run_outcome(nil, { exec_error = true })
    t.eq(errored.status, "blocked")
    t.eq(#error_effects, 1)
    t.eq(error_set.cases[1].execution_status, "error")
    t.eq(error_set.cases[1].classification, "execution_error")
    t.eq(error_set.cases[1].error.code, "environment-session-issue")
    t.is_true(error_set.cases[1].error.message:find("cli unavailable", 1, true) ~= nil)
    t.eq(error_set.cases[1].assertions[1].status, "skipped")
    t.eq(error_set.cases[1].assertions[1].required, true)
    t.eq(#error_v1.cases[1].assertions, 0)
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
          case_result_set_path = request.artifact_root .. "/case-result-set.json",
          case_result_set_artifact_sha256 = string.rep("a", 64),
          evidence_manifest_path = request.artifact_root .. "/evidence-manifest.json",
          evidence_manifest_artifact_sha256 = string.rep("b", 64),
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
    t.eq(result.case_result_set_path, request.artifact_root .. "/case-result-set.json")
    t.eq(result.case_result_set_artifact_sha256, string.rep("a", 64))
    t.eq(result.evidence_manifest_path, request.artifact_root .. "/evidence-manifest.json")
    t.eq(result.evidence_manifest_artifact_sha256, string.rep("b", 64))
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
