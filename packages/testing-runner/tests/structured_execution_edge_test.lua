local contract = require("contract.structured_execution")
local fixtures = require("tests.structured_execution_helpers")
local sha256_bytes = require("tests.fixtures.sha256_helpers")
local structured_execution = require("structured_execution")
local t = fkst.test

local function request()
  local value = fixtures.request(".testing/runs/run-edges", "run-edges")
  value.trace_id = "trace-edges"
  value.dedup_key = "dedup-edges"
  return value
end

local http_case

local function run_edge(mutate, options)
  options = options or {}
  local value = request()
  local plan = fixtures.plan(value)
  plan.cases[1].case_id = "edge-case"
  plan.cases[1].argv = { "fixture-cli" }
  local grant = fixtures.grant(value)
  grant.grant_id = "grant-edges"
  grant.evidence_ref.ref = "grant-edges"
  if options.http_unauthorized then
    http_case(plan, grant)
    grant.http_capabilities[1].methods = { "POST" }
  end
  local bundle = fixtures.artifacts(value, plan, grant)
  if mutate then mutate(value, bundle, plan, grant) end
  if options.http_error then bundle = fixtures.artifacts(value, plan, grant) end
  local writes, now_index = 0, 0
  return structured_execution.run(value, {
    sha256_bytes = sha256_bytes,
    load_artifact = function(path) return bundle[path] end,
    now = function()
      now_index = now_index + 1
      if options.now_hook then options.now_hook(now_index, plan) end
      if type(options.now) == "table" then return options.now[now_index] or options.now[#options.now] end
      return options.now or "2026-07-20T00:30:00Z"
    end,
    verify_grant = function()
      local attestation = fixtures.attestation()
      attestation.evidence_ref.ref = "grant-edges"
      return attestation
    end,
    replay_guard = function()
      return options.claim or { status = "claimed", claim_id = "claim-edges" }
    end,
    authorize_cli_effect = function(input)
      return fixtures.authorization_receipt(input.action_envelope)
    end,
    exec_argv = function()
      if options.exec_error then error("cli unavailable") end
      if options.exec_result == false then return nil end
      return { exit_code = 0, stdout = "ok", stderr = "" }
    end,
    http_request = function()
      if options.http_error then error("http unavailable") end
      return { status = 200, body = "ok" }
    end,
    write_artifact = function(path, artifact)
      writes = writes + 1
      if options.fail_evidence and path:find("/evidence/", 1, true) then return false end
      fixtures.persist_write(bundle, nil, path, artifact)
      return true
    end,
    load_result = function() return nil end,
    complete_replay = function() return options.complete ~= false end,
  }), writes
end

http_case = function(plan, grant)
  plan.cases[1] = {
    case_id = "http-edge",
    kind = "http",
    request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} },
    timeout_seconds = 10,
    assertions = { { type = "status-code", expected = 200 } },
  }
  grant.cli_capabilities = {}
  grant.http_capabilities = { {
    origin = "http://127.0.0.1:4173",
    methods = { "GET" },
    path_prefixes = { "/health" },
  } }
end

return {
  test_request_and_runtime_port_fail_closed_edges = function()
    t.eq(contract.local_http_origin("https://127.0.0.1:4173/health"), nil)
    for _, mutate in ipairs({
      function(value) value.schema = "unknown" end,
      function(value) value.repository.commit_sha = "main" end,
      function(value) value.trace_id = "" end,
      function(value) value.source_ref = nil end,
    }) do
      t.eq(run_edge(function(value) mutate(value) end).status, "blocked")
    end

    _G.structured_execution_runtime = nil
    local defaults = structured_execution.production_ports()
    t.is_true(type(defaults.exec_argv) == "function")
    t.is_true(type(defaults.http_request) == "function")
    _G.structured_execution_runtime = {}
    t.raises(function() structured_execution.production_ports() end)
    local ports = {}
    for _, name in ipairs({
      "sha256_bytes", "load_artifact", "now", "verify_grant", "replay_guard",
      "authorize_cli_effect", "exec_argv", "http_request", "write_artifact", "load_result",
      "complete_replay",
    }) do ports[name] = function() return true end end
    _G.structured_execution_runtime = ports
    t.eq(structured_execution.production_ports(), ports)
    local invalid = request()
    invalid.schema = "unknown"
    t.eq(structured_execution.result_payload(invalid).status, "blocked")
    local missing_root = request()
    missing_root.artifact_root = nil
    local missing_root_result = structured_execution.result_payload(missing_root)
    t.eq(missing_root_result.status, "blocked")
    t.eq(missing_root_result.artifact_root, ".testing/runs/invalid-structured-execution")
    _G.structured_execution_runtime = nil
  end,

  test_plan_and_grant_validation_edges = function()
    local mutations = {
      function(_, _, plan) plan.cases[1].case_id = "" end,
      function(_, _, plan) plan.cases[1].skip_reason = "x" plan.cases[1].skip_classification = "bad" end,
      function(_, _, plan) plan.cases[1].skip_classification = "not-executed-risk" end,
      function(_, _, plan) plan.cases[1].kind = "browser" end,
      function(_, _, plan) plan.cases[1].goal = "foreign browser field" end,
      function(_, _, plan) plan.cases[1].timeout_seconds = 0 end,
      function(_, _, plan) plan.cases[1].assertions = {} end,
      function(_, _, plan) plan.cases[1].argv = {} end,
      function(_, _, plan) plan.cases[1].argv = { "sh", "-c", "echo unsafe" } end,
      function(_, _, plan)
        plan.cases[1] = {
          case_id = "http", kind = "http",
          request = { method = "TRACE", url = "bad", headers = {} },
          timeout_seconds = 10, assertions = { { type = "status-code", expected = 200 } },
        }
      end,
      function(_, _, plan) plan.cases = {} end,
      function(_, _, _, grant) grant.authority.ref = "" end,
      function(_, _, _, grant) grant.cli_capabilities = nil end,
      function(_, _, _, grant) grant.cli_capabilities[1].argv_prefix = {} end,
      function(_, _, _, grant)
        grant.http_capabilities = { { origin = "bad", methods = { "GET" }, path_prefixes = { "/" } } }
      end,
      function(_, _, _, grant)
        grant.http_capabilities = { { origin = "http://localhost", methods = { "TRACE" }, path_prefixes = { "/" } } }
      end,
      function(_, _, _, grant)
        grant.http_capabilities = { { origin = "http://localhost", methods = { "GET" }, path_prefixes = { "bad" } } }
      end,
      function(_, _, plan) plan.cases[1].assertions[1].type = "stdout" end,
      function(_, _, plan, grant) http_case(plan, grant) plan.cases[1].assertions[1].type = "header" end,
    }
    for _, mutate in ipairs(mutations) do t.eq(run_edge(mutate).status, "blocked") end
  end,

  test_identity_capability_and_effect_failure_edges = function()
    local mutations = {
      function(value, bundle) bundle[value.test_plan_ref].digest = fixtures.digest_environment end,
      function(value, bundle) bundle[value.environment_receipt_ref].value.schema = "unknown" end,
      function(value, bundle) bundle[value.environment_receipt_ref].value.status = "blocked" end,
      function(value, bundle) bundle[value.environment_receipt_ref].value.workspace_ref = nil end,
      function(value, bundle) bundle[value.environment_receipt_ref].value.base_url = "https://example.invalid/health" end,
      function(value, bundle)
        bundle[value.environment_receipt_ref].value.repository.url = "https://github.com/other/repo.git"
        bundle[value.environment_receipt_ref].value.repository.commit_sha = string.rep("9", 40)
      end,
      function(value, bundle) bundle[value.browser_readiness_ref].value.source_ref.ref = "foreign" end,
      function(_, _, plan) plan.environment_receipt_sha256 = fixtures.digest_grant end,
      function(_, _, _, grant) grant.plan_sha256 = fixtures.digest_environment end,
      function(_, _, _, grant) grant.max_uses = 2 end,
      function(_, _, _, grant) grant.cli_capabilities[1].argv_prefix = { "other-cli" } end,
      function(_, _, plan, grant) http_case(plan, grant) grant.http_capabilities[1].path_prefixes = { "/other" } end,
      function(_, _, plan, grant)
        http_case(plan, grant)
        grant.http_capabilities[1].origin = "http://127.0.0.1:43110"
      end,
    }
    for _, mutate in ipairs(mutations) do t.eq(run_edge(mutate).status, "blocked") end
    local unauthorized_http = run_edge(nil, { http_unauthorized = true })
    t.eq(unauthorized_http.status, "blocked")
    local invalid_time = run_edge(nil, {
      now = { "2026-07-20T00:30:00Z", "not-a-time", "not-a-time" },
    })
    t.eq(invalid_time.status, "blocked")
    local changed_assertion = run_edge(nil, {
      now_hook = function(index, plan)
        if index == 3 then plan.cases[1].assertions[1].type = "body-contains" end
      end,
    })
    t.eq(changed_assertion.status, "blocked")
    local long_run = string.rep("r", 181)
    local invalid_run_id = run_edge(function(value, bundle)
      value.source_ref.ref = long_run
      bundle[value.browser_readiness_ref].value.source_ref.ref = long_run
    end)
    t.eq(invalid_run_id.status, "blocked")
    local cli_error = run_edge(nil, { exec_error = true })
    t.eq(cli_error.status, "blocked")
    t.eq(cli_error.error_count, 1)
    local http_error = run_edge(function(_, _, plan, grant) http_case(plan, grant) end, { http_error = true })
    t.eq(http_error.status, "blocked")
    t.eq(http_error.error_count, 1)
    t.eq(run_edge(nil, { exec_result = false }).status, "blocked")
    t.eq(run_edge(nil, { claim = { status = "busy" } }).status, "blocked")
    t.eq(run_edge(nil, { fail_evidence = true }).status, "blocked")
    t.eq(run_edge(nil, { complete = false }).status, "blocked")
  end,
}
