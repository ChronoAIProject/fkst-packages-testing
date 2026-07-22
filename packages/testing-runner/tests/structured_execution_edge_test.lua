local fixtures = require("tests.structured_execution_helpers")
local structured_execution = require("structured_execution")
local t = fkst.test

local function request()
  local value = fixtures.request(".testing/runs/edges", "run-edges")
  value.trace_id = "trace-edges"
  value.dedup_key = "dedup-edges"
  return value
end

local function run_edge(mutate, options)
  options = options or {}
  local value = request()
  local plan = fixtures.plan(value)
  plan.cases[1].case_id = "edge-case"
  plan.cases[1].argv = { "fixture-cli" }
  local grant = fixtures.grant(value)
  grant.grant_id = "grant-edges"
  grant.evidence_ref.ref = "grant-edges"
  local bundle = fixtures.artifacts(value, plan, grant)
  if mutate then mutate(value, bundle, plan, grant) end
  local writes = 0
  return structured_execution.run(value, {
    load_artifact = function(path) return bundle[path] end,
    now = function() return "2026-07-20T00:30:00Z" end,
    verify_grant = function()
      local attestation = fixtures.attestation()
      attestation.evidence_ref.ref = "grant-edges"
      return attestation
    end,
    replay_guard = function()
      return options.claim or { status = "claimed", claim_id = "claim-edges" }
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
    write_artifact = function(path)
      writes = writes + 1
      if options.fail_evidence and path:find("/evidence/", 1, true) then return false end
      return true
    end,
    load_result = function() return nil end,
    complete_replay = function() return options.complete ~= false end,
  }), writes
end

local function http_case(plan, grant)
  plan.cases[1] = {
    case_id = "http-edge",
    kind = "http",
    request = { method = "GET", url = "http://127.0.0.1:43110/health", headers = {} },
    timeout_seconds = 10,
    assertions = { { type = "status-code", expected = 200 } },
  }
  grant.cli_capabilities = {}
  grant.http_capabilities = { {
    origin = "http://127.0.0.1:43110",
    methods = { "GET" },
    path_prefixes = { "/health" },
  } }
end

return {
  test_request_and_runtime_port_fail_closed_edges = function()
    for _, mutate in ipairs({
      function(value) value.schema = "unknown" end,
      function(value) value.repository.commit_sha = "main" end,
      function(value) value.trace_id = "" end,
      function(value) value.source_ref = nil end,
    }) do
      t.eq(run_edge(function(value) mutate(value) end).status, "blocked")
    end

    _G.structured_execution_runtime = nil
    t.raises(function() structured_execution.production_ports() end)
    _G.structured_execution_runtime = {}
    t.raises(function() structured_execution.production_ports() end)
    local ports = {}
    for _, name in ipairs({
      "load_artifact", "now", "verify_grant", "replay_guard", "exec_argv",
      "http_request", "write_artifact", "load_result", "complete_replay",
    }) do ports[name] = function() return true end end
    _G.structured_execution_runtime = ports
    t.eq(structured_execution.production_ports(), ports)
    local invalid = request()
    invalid.schema = "unknown"
    t.eq(structured_execution.result_payload(invalid).status, "blocked")
    _G.structured_execution_runtime = nil
  end,

  test_plan_and_grant_validation_edges = function()
    local mutations = {
      function(_, _, plan) plan.cases[1].case_id = "" end,
      function(_, _, plan) plan.cases[1].skip_reason = "x" plan.cases[1].skip_classification = "bad" end,
      function(_, _, plan) plan.cases[1].skip_classification = "not-executed-risk" end,
      function(_, _, plan) plan.cases[1].kind = "browser" end,
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
    }
    for _, mutate in ipairs(mutations) do t.eq(run_edge(mutate).status, "blocked") end
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
