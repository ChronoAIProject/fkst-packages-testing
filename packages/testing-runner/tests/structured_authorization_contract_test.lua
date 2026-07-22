local contract = require("contract.structured_execution")
local fixtures = require("tests.structured_execution_helpers")
local t = fkst.test

local function preauthorization(request)
  return {
    schema = contract.schemas.preauthorization,
    authorization_id = "authorization-110",
    repository = fixtures.copy(request.repository),
    profile_sha256 = string.rep("9", 64),
    case_catalog_sha256 = fixtures.digest_catalog,
    capabilities = {
      cli = { { argv_prefix = { "fixture-cli" } } },
      http = { {
        origin = "http://127.0.0.1:4173",
        methods = { "GET" },
        path_prefixes = { "/health" },
      } },
    },
    authority = { kind = "policy", ref = "testing-authority" },
    policy_revision = "policy-v1",
    evidence_ref = { kind = "attestation", ref = "authorization-110" },
    issued_at = "2026-07-20T00:00:00Z",
    expires_at = "2026-07-20T01:00:00Z",
    max_uses = 1,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
end

local function grant_request(request)
  return {
    schema = contract.schemas.grant_request,
    execution_mode = "structured-api-cli",
    repository = fixtures.copy(request.repository),
    preauthorization_ref = ".testing/runs/structured/preauthorization.json",
    preauthorization_sha256 = fixtures.digest_authorization,
    plan_ref = request.test_plan_ref,
    plan_sha256 = request.test_plan_sha256,
    environment_receipt_ref = request.environment_receipt_ref,
    environment_receipt_sha256 = request.environment_receipt_sha256,
    grant_ref = request.execution_grant_ref,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    source_ref = fixtures.copy(request.source_ref),
  }
end

local function values()
  return {
    grant_id = "grant-110",
    evidence_ref = { kind = "attestation", ref = "grant-110" },
    issued_at = "2026-07-20T00:10:00Z",
    expires_at = "2026-07-20T00:50:00Z",
    now = "2026-07-20T00:30:00Z",
  }
end

return {
  test_derives_exact_plan_and_environment_bound_single_use_grant = function()
    local request = fixtures.request()
    local plan = fixtures.plan(request)
    local grant = contract.derive_grant(preauthorization(request), fixtures.digest_authorization,
      plan, request.test_plan_sha256, request.environment_receipt_sha256,
      grant_request(request), values())
    t.eq(grant.schema, contract.schemas.grant)
    t.eq(grant.parent_authorization_sha256, fixtures.digest_authorization)
    t.eq(grant.plan_sha256, request.test_plan_sha256)
    t.eq(grant.environment_receipt_sha256, request.environment_receipt_sha256)
    t.eq(grant.max_uses, 1)
  end,

  test_rejects_plan_capability_escalation = function()
    local request = fixtures.request()
    local plan = fixtures.plan(request)
    plan.cases[1].argv = { "other-cli", "--version" }
    t.raises(function()
      contract.derive_grant(preauthorization(request), fixtures.digest_authorization,
        plan, request.test_plan_sha256, request.environment_receipt_sha256,
        grant_request(request), values())
    end)
  end,

  test_rejects_foreign_catalog_or_environment_binding = function()
    local request = fixtures.request()
    local plan = fixtures.plan(request)
    plan.case_catalog_sha256 = string.rep("0", 64)
    t.raises(function()
      contract.derive_grant(preauthorization(request), fixtures.digest_authorization,
        plan, request.test_plan_sha256, request.environment_receipt_sha256,
      grant_request(request), values())
    end)
  end,

  test_contract_rejects_malformed_authorization_and_result_boundaries = function()
    local request = fixtures.request()
    local plan = fixtures.plan(request)
    local authorization = preauthorization(request)
    for _, mutate in ipairs({
      function(value) value.profile_sha256 = "bad" end,
      function(value) value.repository.url = "https://user@example.invalid/repo.git" end,
      function(value) value.max_uses = 2 end,
    }) do
      local value = fixtures.copy(authorization)
      mutate(value)
      t.raises(function() contract.validate_preauthorization(value, "2026-07-20T00:30:00Z") end)
    end

    local browser_plan = fixtures.plan(request, { {
      case_id = "browser", kind = "browser", goal = "Authenticate",
      success_conditions = { "Authenticated" }, argv = { "forbidden" },
    } })
    browser_plan.execution_mode = "agentic-browser"
    t.raises(function() contract.validate_plan(browser_plan) end)
    plan.execution_mode = "unknown"
    t.raises(function() contract.validate_plan(plan) end)
    plan = fixtures.plan(request, { {
      case_id = "browser", kind = "browser", goal = "Authenticate",
      success_conditions = { "Authenticated" },
    } })
    t.raises(function() contract.validate_plan(plan) end)

    local http_plan = fixtures.plan(request, { {
      case_id = "health", kind = "http", timeout_seconds = 10,
      request = { method = "GET", url = "http://127.0.0.1:4173/private", headers = {} },
      assertions = { { type = "status-code", expected = 200 } },
    } })
    local allowed = contract.plan_within_capabilities(http_plan, authorization.capabilities)
    t.eq(allowed, false)

    local grant_value = grant_request(request)
    grant_value.execution_mode = "unknown"
    t.raises(function() contract.validate_grant_request(grant_value) end)
    grant_value = grant_request(request)
    grant_value.grant_ref = "foreign"
    t.raises(function() contract.validate_grant_request(grant_value) end)

    t.raises(function() contract.validate_plan_result({
      schema = contract.schemas.plan_result, status = "blocked", residual_risk_count = 0,
      source_ref = { kind = "workflow-qa", ref = "run" }, trace_id = "trace", dedup_key = "dedup",
    }) end)
    t.raises(function() contract.validate_grant_result({
      schema = contract.schemas.grant_result, status = "blocked",
      source_ref = { kind = "workflow-qa", ref = "run" }, trace_id = "trace", dedup_key = "dedup",
    }) end)
  end,
}
