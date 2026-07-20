local structured_execution = require("structured_execution")
local t = fkst.test

local digest_a = string.rep("a", 64)
local digest_b = string.rep("b", 64)
local digest_c = string.rep("c", 64)
local repository = { url = "https://example.invalid/repository.git", commit_sha = string.rep("1", 40) }

local function request()
  return {
    schema = "testing-runner.structured-execution.request.v1", repository = { url = repository.url, commit_sha = repository.commit_sha },
    environment_receipt_ref = ".testing/runs/edges/environment-receipt.json", environment_receipt_sha256 = digest_a,
    test_plan_ref = ".testing/runs/edges/source-plan.json", test_plan_sha256 = digest_b,
    execution_approval_ref = ".testing/runs/edges/execution-approval.json", execution_approval_sha256 = digest_c,
    artifact_root = ".testing/runs/edges/execution", trace_id = "trace-edges", dedup_key = "dedup-edges",
    source_ref = { kind = "workflow-qa", ref = "run-edges" },
  }
end

local function artifacts(value)
  return {
    [value.environment_receipt_ref] = { raw = "environment", digest = digest_a, value = {
      schema = "environment-factory.environment-result.v1", status = "ready", repository = repository,
      trace_id = value.trace_id, dedup_key = value.dedup_key,
    } },
    [value.test_plan_ref] = { raw = "plan", digest = digest_b, value = {
      schema = "testing-structured-plan.v1", repository = repository, environment_receipt_sha256 = digest_a,
      cases = { { case_id = "edge-case", kind = "cli", argv = { "fixture-cli" }, timeout_seconds = 10,
        assertions = { { type = "exit-code", expected = 0 } } } },
    } },
    [value.execution_approval_ref] = { raw = "approval", digest = digest_c, value = {
      schema = "testing-structured-execution-approval.v1", approval_id = "approval-edges",
      plan_sha256 = digest_b, environment_receipt_sha256 = digest_a, repository = repository,
      cli_capabilities = { { argv_prefix = { "fixture-cli" } } }, http_capabilities = {},
      authority = { kind = "policy", ref = "testing-authority" }, policy_revision = "policy-v1",
      evidence_ref = { kind = "attestation", ref = "approval-edges" },
      issued_at = "2026-07-20T00:00:00Z", expires_at = "2026-07-20T01:00:00Z", max_uses = 1,
      trace_id = value.trace_id, dedup_key = value.dedup_key,
    } },
  }
end

local function run_edge(mutate, options)
  options = options or {}
  local value = request()
  local bundle = artifacts(value)
  if mutate then mutate(value, bundle, bundle[value.test_plan_ref].value, bundle[value.execution_approval_ref].value) end
  local writes = 0
  return structured_execution.run(value, {
    load_artifact = function(path)
      local artifact = bundle[path]
      if artifact == nil then return nil end
      return artifact
    end,
    now = function() return "2026-07-20T00:30:00Z" end,
    verify_approval = function()
      return { approval_sha256 = digest_c, authority = { kind = "policy", ref = "testing-authority" },
        policy_revision = "policy-v1", evidence_ref = { kind = "attestation", ref = "approval-edges" } }
    end,
    replay_guard = function() return options.claim or { status = "claimed", claim_id = "claim-edges" } end,
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

local function http_case(plan, approval)
  plan.cases[1] = {
    case_id = "http-edge", kind = "http", request = { method = "GET", url = "http://127.0.0.1:43110/health", headers = {} },
    timeout_seconds = 10, assertions = { { type = "status-code", expected = 200 } },
  }
  approval.cli_capabilities = {}
  approval.http_capabilities = { { origin = "http://127.0.0.1:43110", methods = { "GET" }, path_prefixes = { "/health" } } }
end

return {
  test_request_and_runtime_port_fail_closed_edges = function()
    local invalid_requests = {
      function(value) value.schema = "unknown" end,
      function(value) value.repository.commit_sha = "main" end,
      function(value) value.trace_id = "" end,
      function(value) value.source_ref = nil end,
    }
    for _, mutate in ipairs(invalid_requests) do
      local result = run_edge(function(value) mutate(value) end)
      t.eq(result.status, "blocked")
    end

    _G.structured_execution_runtime = nil
    t.raises(function() structured_execution.production_ports() end)
    _G.structured_execution_runtime = {}
    t.raises(function() structured_execution.production_ports() end)
    local ports = {}
    for _, name in ipairs({ "load_artifact", "now", "verify_approval", "replay_guard", "exec_argv", "http_request", "write_artifact", "load_result", "complete_replay" }) do
      ports[name] = function() return true end
    end
    _G.structured_execution_runtime = ports
    t.eq(structured_execution.production_ports(), ports)
    local invalid = request()
    invalid.schema = "unknown"
    t.eq(structured_execution.result_payload(invalid).status, "blocked")
    _G.structured_execution_runtime = nil
  end,

  test_plan_and_approval_validation_edges = function()
    local mutations = {
      function(_, _, plan) plan.cases[1].case_id = "" end,
      function(_, _, plan) plan.cases[1].skip_reason = "x" plan.cases[1].skip_classification = "bad" end,
      function(_, _, plan) plan.cases[1].skip_classification = "not-executed-risk" end,
      function(_, _, plan) plan.cases[1].kind = "browser" end,
      function(_, _, plan) plan.cases[1].timeout_seconds = 0 end,
      function(_, _, plan) plan.cases[1].assertions = {} end,
      function(_, _, plan) plan.cases[1].argv = {} end,
      function(_, _, plan) plan.cases[1].argv = { "sh", "-c", "echo unsafe" } end,
      function(_, _, plan) plan.cases[1] = { case_id = "http", kind = "http", request = { method = "TRACE", url = "bad", headers = {} }, timeout_seconds = 10, assertions = { { type = "status-code", expected = 200 } } } end,
      function(_, _, plan) plan.cases = {} end,
      function(_, _, _, approval) approval.authority.ref = "" end,
      function(_, _, _, approval) approval.cli_capabilities = nil end,
      function(_, _, _, approval) approval.cli_capabilities[1].argv_prefix = {} end,
      function(_, _, _, approval) approval.http_capabilities = { { origin = "bad", methods = { "GET" }, path_prefixes = { "/" } } } end,
      function(_, _, _, approval) approval.http_capabilities = { { origin = "http://localhost", methods = { "TRACE" }, path_prefixes = { "/" } } } end,
      function(_, _, _, approval) approval.http_capabilities = { { origin = "http://localhost", methods = { "GET" }, path_prefixes = { "bad" } } } end,
      function(_, _, plan) plan.cases[1].assertions[1].type = "stdout" end,
      function(_, _, plan, approval) http_case(plan, approval) plan.cases[1].assertions[1].type = "header" end,
    }
    for _, mutate in ipairs(mutations) do
      local result = run_edge(mutate)
      t.eq(result.status, "blocked")
    end
  end,

  test_identity_capability_and_effect_failure_edges = function()
    local mutations = {
      function(_, bundle) bundle[request().test_plan_ref].digest = digest_a end,
      function(_, bundle) bundle[request().environment_receipt_ref].value.schema = "unknown" end,
      function(_, bundle) bundle[request().environment_receipt_ref].value.status = "blocked" end,
      function(_, _, plan) plan.environment_receipt_sha256 = digest_c end,
      function(_, _, _, approval) approval.plan_sha256 = digest_a end,
      function(_, _, _, approval) approval.cli_capabilities[1].argv_prefix = { "other-cli" } end,
      function(_, _, plan, approval) http_case(plan, approval) approval.http_capabilities[1].path_prefixes = { "/other" } end,
    }
    for _, mutate in ipairs(mutations) do
      local result = run_edge(mutate)
      t.eq(result.status, "blocked")
    end
    local cli_error = run_edge(nil, { exec_error = true })
    t.eq(cli_error.status, "blocked")
    t.eq(cli_error.error_count, 1)
    local http_error = run_edge(function(_, _, plan, approval) http_case(plan, approval) end, { http_error = true })
    t.eq(http_error.status, "blocked")
    t.eq(http_error.error_count, 1)
    t.eq(run_edge(nil, { exec_result = false }).status, "blocked")
    t.eq(run_edge(nil, { claim = { status = "busy" } }).status, "blocked")
    t.eq(run_edge(nil, { fail_evidence = true }).status, "blocked")
    t.eq(run_edge(nil, { complete = false }).status, "blocked")
  end,
}
