local browser = require("contract.browser_control")
local structured = require("contract.structured_execution")
local t = fkst.test

local function digest(char) return string.rep(char, 64) end
local function repository()
  return { url = "https://github.com/owner/repo.git", commit_sha = string.rep("a", 40) }
end

local function grant()
  return {
    schema = browser.schemas.grant,
    grant_id = "browser-grant-1",
    parent_authorization_sha256 = digest("0"),
    repository = repository(),
    environment_receipt_sha256 = digest("1"),
    readiness_attempt_id = "attempt-1",
    readiness_attempt_sha256 = digest("2"),
    target_id = "target-1",
    target_sha256 = digest("3"),
    reviewed_plan_sha256 = digest("4"),
    allowed_auth_origins = { "https://auth.example.test" },
    callback = { origin = "http://127.0.0.1:43119", path = "/callback" },
    allowed_actions = { "click", "type", "submit", "press_tab", "finish" },
    approved_secret_refs = { "primary-identity", "primary-secret" },
    step_budget = 6,
    time_budget_seconds = 120,
    authority = { kind = "policy", ref = "browser-policy" },
    policy_revision = "policy-v1",
    evidence_ref = { kind = "attestation", ref = "browser-grant-1" },
    issued_at = "2026-07-20T00:00:00Z",
    expires_at = "2026-07-20T01:00:00Z",
    max_uses = 1,
    trace_id = "trace-browser",
    dedup_key = "dedup-browser",
  }
end

local function observation()
  return {
    schema = browser.schemas.observation,
    turn = 1,
    document_token = digest("5"),
    target_id = "target-1",
    origin = "https://auth.example.test",
    path = "/login",
    ready_state = "complete",
    controls = {
      { handle = "abcdef12", role = "textbox", kind = "textbox", label = "Email", focused = true },
      { handle = "abcdef34", role = "button", kind = "button", label = "Continue", focused = false },
    },
    signals = {
      callback_detected = false, mfa_detected = false, captcha_detected = false,
      target_changed = false, popup_detected = false,
    },
    console_count = 0,
    network_count = 2,
  }
end

return {
  test_browser_grant_binds_exact_origins_target_secrets_and_single_use = function()
    browser.validate_grant(grant(), "2026-07-20T00:30:00Z")
    for _, mutate in ipairs({
      function(value) value.allowed_auth_origins[1] = "https://auth.example.test/path" end,
      function(value) value.callback.origin = "http://example.test:43119" end,
      function(value) value.callback.path = "/callback?code=secret" end,
      function(value) value.allowed_actions[1] = "navigate" end,
      function(value) value.approved_secret_refs[1] = "secret=value" end,
      function(value) value.max_uses = 2 end,
      function(value) value.target_sha256 = "bad" end,
      function(value) value.extra = true end,
    }) do
      local value = structured.copy(grant())
      mutate(value)
      t.raises(function() browser.validate_grant(value, "2026-07-20T00:30:00Z") end)
    end
  end,

  test_browser_grant_expiry_is_fail_closed = function()
    t.raises(function() browser.validate_grant(grant(), "2026-07-20T01:00:00Z") end)
  end,

  test_browser_grant_derivation_binds_parent_authorization = function()
    local preauthorization = {
      schema = structured.schemas.preauthorization,
      authorization_id = "browser-authorization", repository = repository(),
      profile_sha256 = digest("9"), case_catalog_sha256 = digest("8"),
      capabilities = { cli = {}, http = {} },
      authority = { kind = "policy", ref = "browser-policy" }, policy_revision = "policy-v1",
      evidence_ref = { kind = "attestation", ref = "browser-authorization" },
      issued_at = "2026-07-20T00:00:00Z", expires_at = "2026-07-20T01:00:00Z", max_uses = 1,
      trace_id = "trace-browser", dedup_key = "dedup-browser",
    }
    local plan = {
      schema = structured.schemas.plan, execution_mode = "agentic-browser", repository = repository(),
      environment_receipt_sha256 = digest("1"), browser_readiness_sha256 = digest("6"),
      case_catalog_sha256 = digest("8"), module_plan_sha256 = digest("7"), cases = { {
        case_id = "login", kind = "browser", goal = "Authenticate the existing user.",
        success_conditions = { "Exact callback", "Authenticated status" },
        completion_assertions = {
          { assertion_id = "callback-observed", type = "browser-callback-observed", required = true, completion_field = "callback_observed" },
          { assertion_id = "process-exit-zero", type = "browser-process-exit-zero", required = true, completion_field = "process_exit_zero" },
          { assertion_id = "whoami-succeeded", type = "browser-whoami-succeeded", required = true, completion_field = "whoami_succeeded" },
          { assertion_id = "status-authenticated", type = "browser-status-authenticated", required = true, completion_field = "status_authenticated" },
        },
      } }, residual_risk_case_ids = {}, trace_id = "trace-browser", dedup_key = "dedup-browser",
    }
    local request = {
      schema = structured.schemas.grant_request, execution_mode = "agentic-browser", repository = repository(),
      preauthorization_ref = ".testing/runs/browser/preauthorization.json",
      preauthorization_sha256 = digest("0"), plan_ref = ".testing/runs/browser/plan.json",
      plan_sha256 = digest("4"), environment_receipt_ref = ".testing/runs/browser/environment.json",
      environment_receipt_sha256 = digest("1"), grant_ref = ".testing/runs/browser/grant.json",
      source_ref = { kind = "workflow-qa", ref = "browser-run" },
      trace_id = "trace-browser", dedup_key = "dedup-browser",
    }
    local value = grant()
    local derived = browser.derive_grant(preauthorization, request.preauthorization_sha256,
      plan, request.plan_sha256, request.environment_receipt_sha256, request, {
        grant_id = value.grant_id, readiness_attempt_id = value.readiness_attempt_id,
        readiness_attempt_sha256 = value.readiness_attempt_sha256,
        target_id = value.target_id, target_sha256 = value.target_sha256,
        allowed_auth_origins = value.allowed_auth_origins, callback = value.callback,
        allowed_actions = value.allowed_actions, approved_secret_refs = value.approved_secret_refs,
        step_budget = value.step_budget, time_budget_seconds = value.time_budget_seconds,
        evidence_ref = value.evidence_ref, issued_at = value.issued_at, expires_at = value.expires_at,
        now = "2026-07-20T00:30:00Z",
      })
    t.eq(derived.parent_authorization_sha256, request.preauthorization_sha256)
    request.plan_sha256 = digest("6")
    t.raises(function()
      browser.derive_grant(preauthorization, digest("0"), plan, digest("4"), digest("1"), request, {})
    end)
  end,

  test_observation_and_selector_free_action_contracts_are_closed = function()
    local observed = observation()
    browser.validate_observation(observed)
    t.eq(browser.document_digest(observed), digest("5"))
    local malformed = structured.copy(observed)
    malformed.turn = 0
    t.raises(function() browser.document_digest(malformed) end)
    browser.validate_action({
      schema = browser.schemas.action, turn = 1, kind = "type",
      handle = "abcdef12", secret_ref = "primary-secret",
    }, grant().allowed_actions, grant().approved_secret_refs)
    for _, action in ipairs({
      { schema = browser.schemas.action, turn = 1, kind = "navigate", url = "https://example.test" },
      { schema = browser.schemas.action, turn = 1, kind = "click", selector = "#submit" },
      { schema = browser.schemas.action, turn = 1, kind = "type", handle = "abcdef12", secret_ref = "literal-secret" },
      { schema = browser.schemas.action, turn = 1, kind = "press_tab", key = "Enter" },
      { schema = browser.schemas.action, turn = 1, kind = "finish", advisory_status = "success", transcript = "raw" },
    }) do
      t.raises(function() browser.validate_action(action, grant().allowed_actions, grant().approved_secret_refs) end)
    end
  end,

  test_structured_plan_rejects_mixed_browser_and_fixed_execution = function()
    local plan = {
      schema = structured.schemas.plan,
      execution_mode = "agentic-browser",
      repository = repository(),
      environment_receipt_sha256 = digest("1"),
      browser_readiness_sha256 = digest("4"),
      case_catalog_sha256 = digest("2"),
      module_plan_sha256 = digest("3"),
      cases = { {
        case_id = "login", kind = "browser", goal = "Authenticate the existing user.",
        success_conditions = { "Exact loopback callback", "Authenticated CLI status" },
        completion_assertions = {
          { assertion_id = "callback-observed", type = "browser-callback-observed", required = true, completion_field = "callback_observed" },
          { assertion_id = "process-exit-zero", type = "browser-process-exit-zero", required = true, completion_field = "process_exit_zero" },
          { assertion_id = "whoami-succeeded", type = "browser-whoami-succeeded", required = true, completion_field = "whoami_succeeded" },
          { assertion_id = "status-authenticated", type = "browser-status-authenticated", required = true, completion_field = "status_authenticated" },
        },
      } },
      residual_risk_case_ids = {},
      trace_id = "trace-browser", dedup_key = "dedup-browser",
    }
    structured.validate_plan(plan)
    local wrong_mode = structured.copy(plan)
    wrong_mode.execution_mode = "structured-api-cli"
    t.raises(function() structured.validate_plan(wrong_mode) end)
    local no_required = structured.copy(plan)
    for _, assertion in ipairs(no_required.cases[1].completion_assertions) do assertion.required = false end
    t.raises(function() structured.validate_plan(no_required) end)
    local duplicate_field = structured.copy(plan)
    duplicate_field.cases[1].completion_assertions[2].completion_field = "callback_observed"
    t.raises(function() structured.validate_plan(duplicate_field) end)
    table.insert(plan.cases, {
      case_id = "health", kind = "http", timeout_seconds = 10,
      request = { method = "GET", url = "http://127.0.0.1:4173/health", headers = {} },
      assertions = { { type = "status-code", expected = 200 } },
    })
    t.raises(function() structured.validate_plan(plan) end)
  end,

  test_browser_contract_rejects_closed_boundary_mutations = function()
    for _, mutate in ipairs({
      function(value) value.issued_at = nil end,
      function(value) value.expires_at = value.issued_at end,
      function(value) value.step_budget = 0 end,
      function(value) value.authority.ref = "" end,
    }) do
      local value = structured.copy(grant())
      mutate(value)
      t.raises(function() browser.validate_grant(value, "2026-07-20T00:30:00Z") end)
    end

    local root = ".testing/runs/browser"
    local request = {
      schema = browser.schemas.request, repository = repository(),
      environment_receipt_ref = root .. "/environment.json", environment_receipt_sha256 = digest("1"),
      reviewed_plan_ref = root .. "/plan.json", reviewed_plan_sha256 = digest("2"),
      browser_grant_ref = root .. "/grant.json", browser_grant_sha256 = digest("3"),
      artifact_root = root, trace_id = "trace-browser", dedup_key = "dedup-browser",
      source_ref = { kind = "workflow-qa", ref = "browser-run" },
    }
    browser.validate_request(request)
    for _, mutate in ipairs({
      function(value) value.environment_receipt_ref = "foreign" end,
      function(value) value.reviewed_plan_ref = ".testing/runs/foreign/plan.json" end,
      function(value) value.trace_id = "" end,
      function(value) value.source_ref.ref = "" end,
    }) do
      local value = structured.copy(request)
      mutate(value)
      t.raises(function() browser.validate_request(value) end)
    end

    local invalid_observation = observation()
    invalid_observation.turn = 0
    t.raises(function() browser.validate_observation(invalid_observation) end)

    for _, action in ipairs({
      { schema = browser.schemas.action, turn = 1, kind = "click" },
      { schema = browser.schemas.action, turn = 1, kind = "press_tab", handle = "abcdef12" },
      { schema = browser.schemas.action, turn = 1, kind = "finish", advisory_status = "maybe" },
    }) do
      t.raises(function() browser.validate_action(action, grant().allowed_actions, grant().approved_secret_refs) end)
    end

    local click = { schema = browser.schemas.action, turn = 1, kind = "click", handle = "abcdef12" }
    local step = {
      schema = browser.schemas.step_receipt, turn = 1, action = click,
      before = observation(), after = observation(), status = "executed", classification = "effect-applied",
    }
    browser.validate_step_receipt(step, grant())
    local invalid_step = structured.copy(step)
    invalid_step.status = "unknown"
    t.raises(function() browser.validate_step_receipt(invalid_step, grant()) end)
    invalid_step = structured.copy(step)
    invalid_step.turn = 2
    t.raises(function() browser.validate_step_receipt(invalid_step, grant()) end)

    local receipt = {
      schema = browser.schemas.receipt, status = "passed", classification = "passed",
      repository = repository(), environment_receipt_sha256 = digest("1"),
      reviewed_plan_sha256 = digest("2"), browser_grant_sha256 = digest("3"),
      readiness_attempt_sha256 = digest("4"), target_sha256 = digest("5"),
      case_id = "login", steps = { step },
      completion = { callback_observed = true, process_exit_zero = true, whoami_succeeded = true, status_authenticated = true },
      artifact_root = root, trace_id = "trace-browser", dedup_key = "dedup-browser",
    }
    browser.validate_receipt(receipt, grant())
    local invalid_receipt = structured.copy(receipt)
    invalid_receipt.status = "unknown"
    t.raises(function() browser.validate_receipt(invalid_receipt, grant()) end)
    invalid_receipt = structured.copy(receipt)
    invalid_receipt.trace_id = ""
    t.raises(function() browser.validate_receipt(invalid_receipt, grant()) end)
  end,
}
