local strings = require("contract.strings")
local time = require("contract.time")

local M = {}

M.schemas = {
  preauthorization = "testing-structured-execution-authorization.v1",
  case_catalog = "testing-structured-case-catalog.v1",
  plan = "testing-structured-plan.v2",
  grant = "testing-structured-execution-grant.v1",
  plan_request = "testing-runner.structured-plan.request.v1",
  plan_result = "testing-runner.structured-plan.result.v1",
  grant_request = "workflow-qa.execution-grant.request.v1",
  grant_result = "workflow-qa.execution-grant.result.v1",
  cli_action_envelope = "testing-cli-action-envelope.v1",
  effect_authorization_receipt = "testing-effect-authorization-receipt.v1",
}

local max_cases = 64
local max_argv = 32
local max_assertions = 16
local max_capabilities = 64

local function fail(classification, message)
  error("contract.structured-execution: " .. classification .. ": " .. message)
end

local function bounded(value, limit)
  return strings.is_bounded_string(value, limit or 512)
    and value:find("[%z\1-\31\127]") == nil
end

local function dense(value, limit, non_empty)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    highest = math.max(highest, key)
  end
  return count == highest and count <= limit and (not non_empty or count > 0)
end

local function only_fields(value, allowed, label)
  if type(value) ~= "table" then fail("malformed-" .. label, label .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then fail("malformed-" .. label, "unsupported field " .. tostring(key)) end
  end
end

local function contains(value, expected)
  for _, item in ipairs(value or {}) do if item == expected then return true end end
  return false
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function digest(value, label)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    fail("malformed-digest", label .. " must be a lowercase SHA-256 digest")
  end
  return value
end

local function pointer(value, label)
  if not strings.is_artifact_root(value, 4096) then
    fail("malformed-pointer", label .. " must be a safe .testing/runs/... pointer")
  end
  return value
end

local function validate_ref(value, label)
  only_fields(value, { kind = true, ref = true }, label)
  if not bounded(value.kind, 80) or not bounded(value.ref, 2048) then
    fail("malformed-reference", label .. " must be bounded")
  end
  return value
end

local function validate_repository(value, label)
  only_fields(value, { url = true, commit_sha = true }, label or "repository")
  if not bounded(value.url, 2048) or value.url:match("^https://[^/@]+/[^?#]+$") == nil
    or value.url:find("@", 1, true) ~= nil or type(value.commit_sha) ~= "string"
    or #value.commit_sha ~= 40 or value.commit_sha:match("^[0-9a-f]+$") == nil then
    fail("mutable-repository", (label or "repository") .. " must bind a credential-free URL and full commit")
  end
  return value
end
M.validate_repository = validate_repository

local function same_repository(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.url == right.url and left.commit_sha == right.commit_sha
end
M.same_repository = same_repository

local methods = { GET = true, HEAD = true, POST = true, PUT = true, PATCH = true, DELETE = true }
local shells = { sh = true, bash = true, zsh = true, cmd = true, powershell = true, pwsh = true }

local function executable(argv)
  local index = 1
  local name = tostring(argv[index] or ""):match("([^/\\]+)$"):lower()
  if name == "env" then
    index = index + 1
    while type(argv[index]) == "string" and argv[index]:match("^[%w_]+=") do index = index + 1 end
    name = tostring(argv[index] or ""):match("([^/\\]+)$"):lower()
  end
  return name
end

local function validate_assertion(value, kind)
  only_fields(value, { type = true, expected = true }, "assertion")
  if kind == "cli" then
    if value.type ~= "exit-code" or type(value.expected) ~= "number"
      or value.expected ~= math.floor(value.expected) or value.expected < 0 or value.expected > 255 then
      fail("unsupported-assertion", "CLI cases support only exit-code assertions")
    end
  elseif value.type == "status-code" then
    if type(value.expected) ~= "number" or value.expected ~= math.floor(value.expected)
      or value.expected < 100 or value.expected > 599 then
      fail("unsupported-assertion", "HTTP status-code assertion is invalid")
    end
  elseif value.type ~= "body-contains" or not bounded(value.expected, 512) then
    fail("unsupported-assertion", "HTTP assertion is invalid")
  end
end

local function split_http_url(url)
  if not bounded(url, 2048) or url:find("?", 1, true) or url:find("#", 1, true) then return nil, nil end
  local origin, path = url:match("^(https?://[^/]+)(/.*)$")
  if origin == nil then origin = url:match("^(https?://[^/]+)$") path = "/" end
  if origin == nil or origin:find("@", 1, true) then return nil, nil end
  return origin, path
end
M.split_http_url = split_http_url

function M.local_http_origin(url)
  local origin, path = split_http_url(url)
  if origin == nil then return nil, nil end
  local authority = origin:match("^http://(.+)$")
  if authority == nil then return nil, nil end
  local host = authority:match("^([^:]+):%d+$") or authority
  local bracketed = authority:match("^(%[::1%]):%d+$") or authority:match("^(%[::1%])$")
  if host ~= "127.0.0.1" and host:lower() ~= "localhost" and bracketed ~= "[::1]" then
    return nil, nil
  end
  return origin:lower(), path
end

local function validate_case(value, seen, allow_skip)
  only_fields(value, {
    case_id = true, kind = true, argv = true, request = true, timeout_seconds = true,
    assertions = true, goal = true, success_conditions = true,
    skip_reason = true, skip_classification = true,
  }, "case")
  if not bounded(value.case_id, 180) or value.case_id:match("^[%w%._%-]+$") == nil or seen[value.case_id] then
    fail("malformed-case", "case_id must be unique and path-safe")
  end
  seen[value.case_id] = true
  if value.kind == "browser" then
    if not bounded(value.goal, 1000) or not dense(value.success_conditions, 8, true) then
      fail("malformed-browser-case", "browser goal and success conditions must be bounded")
    end
    for _, condition in ipairs(value.success_conditions) do
      if not bounded(condition, 512) then fail("malformed-browser-case", "browser success condition is invalid") end
    end
    if value.argv ~= nil or value.request ~= nil or value.timeout_seconds ~= nil or value.assertions ~= nil
      or value.skip_reason ~= nil or value.skip_classification ~= nil then
      fail("malformed-browser-case", "browser cases cannot contain fixed-executor fields")
    end
    return value
  end
  if value.kind ~= "cli" and value.kind ~= "http" then fail("unsupported-case", tostring(value.kind)) end
  if value.goal ~= nil or value.success_conditions ~= nil then
    fail("malformed-case", "fixed cases cannot contain browser-control fields")
  end
  if type(value.timeout_seconds) ~= "number" or value.timeout_seconds ~= math.floor(value.timeout_seconds)
    or value.timeout_seconds < 1 or value.timeout_seconds > 300 then
    fail("malformed-case", "timeout_seconds must be from 1 to 300")
  end
  if not dense(value.assertions, max_assertions, true) then fail("malformed-case", "assertions must be bounded") end
  for _, assertion in ipairs(value.assertions) do validate_assertion(assertion, value.kind) end
  if value.skip_reason ~= nil then
    if not allow_skip or not bounded(value.skip_reason, 512)
      or (value.skip_classification ~= "data-fixture-gap" and value.skip_classification ~= "not-executed-risk") then
      fail("malformed-skip", "skip reason and classification are invalid")
    end
  elseif value.skip_classification ~= nil then
    fail("malformed-skip", "skip_classification requires skip_reason")
  end
  if value.kind == "cli" then
    if not dense(value.argv, max_argv, true) then fail("malformed-case", "CLI argv must be bounded") end
    for _, item in ipairs(value.argv) do if not bounded(item, 512) then fail("malformed-case", "CLI argv item is invalid") end end
    if shells[executable(value.argv)] then fail("shell-executable", "shell executables and env-wrapped shells are unsupported") end
    if value.request ~= nil then fail("malformed-case", "CLI case must not contain request") end
  else
    only_fields(value.request, { method = true, url = true, headers = true }, "http-request")
    if methods[value.request.method] ~= true or split_http_url(value.request.url) == nil
      or not dense(value.request.headers or {}, 16, false) or #(value.request.headers or {}) ~= 0 then
      fail("malformed-case", "HTTP request must be credential-free and contain no inline headers")
    end
    if value.argv ~= nil then fail("malformed-case", "HTTP case must not contain argv") end
  end
  return value
end
M.validate_case = validate_case

local function validate_cli_capabilities(value)
  if not dense(value, max_capabilities, false) then fail("malformed-capabilities", "CLI capabilities must be bounded") end
  for _, capability in ipairs(value) do
    only_fields(capability, { argv_prefix = true }, "cli-capability")
    if not dense(capability.argv_prefix, max_argv, true) then fail("malformed-capabilities", "CLI prefix is invalid") end
    for _, item in ipairs(capability.argv_prefix) do if not bounded(item, 512) then fail("malformed-capabilities", "CLI prefix item is invalid") end end
    if shells[executable(capability.argv_prefix)] then fail("shell-executable", "shell capabilities are unsupported") end
  end
end

local function validate_http_capabilities(value)
  if not dense(value, max_capabilities, false) then fail("malformed-capabilities", "HTTP capabilities must be bounded") end
  for _, capability in ipairs(value) do
    only_fields(capability, { origin = true, methods = true, path_prefixes = true }, "http-capability")
    if not bounded(capability.origin, 512) or capability.origin:match("^https?://[^/@]+$") == nil
      or capability.origin:find("@", 1, true) or not dense(capability.methods, 8, true)
      or not dense(capability.path_prefixes, 16, true) then
      fail("malformed-capabilities", "HTTP capability is invalid")
    end
    for _, method in ipairs(capability.methods) do if methods[method] ~= true then fail("malformed-capabilities", "HTTP method is invalid") end end
    for _, prefix in ipairs(capability.path_prefixes) do
      if not bounded(prefix, 512) or prefix:sub(1, 1) ~= "/" or prefix:find("?", 1, true) or prefix:find("#", 1, true) then
        fail("malformed-capabilities", "HTTP path prefix is invalid")
      end
    end
  end
end

function M.validate_capabilities(value)
  only_fields(value, { cli = true, http = true }, "capabilities")
  validate_cli_capabilities(value.cli or {})
  validate_http_capabilities(value.http or {})
  return value
end

local function validate_window(value, now, label)
  if not bounded(value.issued_at, 40) or not bounded(value.expires_at, 40) then fail("malformed-time", label .. " timestamps are required") end
  local issued = time.iso_timestamp_epoch_seconds(value.issued_at)
  local expires = time.iso_timestamp_epoch_seconds(value.expires_at)
  if issued == nil or expires == nil or expires <= issued then fail("malformed-time", label .. " validity window is invalid") end
  if now ~= nil then
    local current = time.iso_timestamp_epoch_seconds(now)
    if current == nil or current < issued or current >= expires then fail("stale-authorization", label .. " is outside its validity window") end
  end
end

function M.validate_preauthorization(value, now)
  only_fields(value, {
    schema = true, authorization_id = true, repository = true, profile_sha256 = true,
    case_catalog_sha256 = true, capabilities = true, authority = true, policy_revision = true,
    evidence_ref = true, issued_at = true, expires_at = true, max_uses = true,
    trace_id = true, dedup_key = true,
  }, "preauthorization")
  if value.schema ~= M.schemas.preauthorization then fail("unknown-schema", "preauthorization schema") end
  if not bounded(value.authorization_id, 180) or not bounded(value.policy_revision, 180)
    or not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) or value.max_uses ~= 1 then
    fail("malformed-preauthorization", "identity and single-use policy are invalid")
  end
  validate_repository(value.repository, "preauthorization-repository")
  digest(value.profile_sha256, "profile_sha256")
  digest(value.case_catalog_sha256, "case_catalog_sha256")
  M.validate_capabilities(value.capabilities)
  validate_ref(value.authority, "authority")
  validate_ref(value.evidence_ref, "evidence-ref")
  validate_window(value, now, "preauthorization")
  return value
end

function M.validate_catalog(value)
  only_fields(value, { schema = true, repository = true, cases = true, trace_id = true, dedup_key = true }, "case-catalog")
  if value.schema ~= M.schemas.case_catalog then fail("unknown-schema", "case catalog schema") end
  validate_repository(value.repository, "catalog-repository")
  if not dense(value.cases, max_cases, true) then fail("malformed-catalog", "catalog cases must be bounded") end
  local seen, design_seen = {}, {}
  for _, case in ipairs(value.cases) do
    only_fields(case, {
      design_case_id = true, case_id = true, kind = true, argv = true, request = true,
      timeout_seconds = true, assertions = true, goal = true, success_conditions = true,
      skip_reason = true, skip_classification = true,
    }, "catalog-case")
    if not bounded(case.design_case_id, 180) or design_seen[case.design_case_id] then
      fail("malformed-catalog", "design_case_id must be unique and bounded")
    end
    design_seen[case.design_case_id] = true
    local executable_case = copy(case)
    executable_case.design_case_id = nil
    validate_case(executable_case, seen, false)
  end
  if not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then fail("malformed-catalog", "catalog identity is invalid") end
  return value
end

function M.validate_plan(value)
  only_fields(value, {
    schema = true, execution_mode = true, repository = true, environment_receipt_sha256 = true,
    browser_readiness_sha256 = true, case_catalog_sha256 = true, module_plan_sha256 = true, cases = true,
    residual_risk_case_ids = true, trace_id = true, dedup_key = true,
  }, "plan")
  if value.schema ~= M.schemas.plan then fail("unknown-schema", "structured plan schema") end
  if value.execution_mode ~= "structured-api-cli" and value.execution_mode ~= "agentic-browser" then
    fail("unsupported-execution-mode", tostring(value.execution_mode))
  end
  validate_repository(value.repository, "plan-repository")
  digest(value.environment_receipt_sha256, "environment_receipt_sha256")
  digest(value.browser_readiness_sha256, "browser_readiness_sha256")
  digest(value.case_catalog_sha256, "case_catalog_sha256")
  digest(value.module_plan_sha256, "module_plan_sha256")
  if not dense(value.cases, max_cases, true) then fail("malformed-plan", "plan cases must be bounded and non-empty") end
  local seen, browser_count = {}, 0
  for _, case in ipairs(value.cases) do
    validate_case(case, seen, true)
    if case.kind == "browser" then browser_count = browser_count + 1 end
  end
  if value.execution_mode == "agentic-browser" then
    if #value.cases ~= 1 or browser_count ~= 1 then
      fail("mixed-execution-mode", "agentic-browser plans require exactly one browser case")
    end
  elseif browser_count ~= 0 then
    fail("mixed-execution-mode", "structured-api-cli plans cannot contain browser cases")
  end
  if not dense(value.residual_risk_case_ids or {}, max_cases, false) then fail("malformed-plan", "residual risks must be bounded") end
  for _, case_id in ipairs(value.residual_risk_case_ids or {}) do if not bounded(case_id, 180) then fail("malformed-plan", "residual risk case ID is invalid") end end
  if not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then fail("malformed-plan", "plan identity is invalid") end
  return value
end

function M.validate_grant(value, now)
  only_fields(value, {
    schema = true, grant_id = true, parent_authorization_sha256 = true, plan_sha256 = true,
    environment_receipt_sha256 = true, repository = true, cli_capabilities = true,
    http_capabilities = true, authority = true,
    policy_revision = true, evidence_ref = true, issued_at = true, expires_at = true,
    max_uses = true, trace_id = true, dedup_key = true,
  }, "grant")
  if value.schema ~= M.schemas.grant then fail("unknown-schema", "execution grant schema") end
  if not bounded(value.grant_id, 180) or not bounded(value.policy_revision, 180)
    or not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) or value.max_uses ~= 1 then
    fail("malformed-grant", "grant identity and single-use policy are invalid")
  end
  digest(value.parent_authorization_sha256, "parent_authorization_sha256")
  digest(value.plan_sha256, "plan_sha256")
  digest(value.environment_receipt_sha256, "environment_receipt_sha256")
  validate_repository(value.repository, "grant-repository")
  validate_cli_capabilities(value.cli_capabilities or {})
  validate_http_capabilities(value.http_capabilities or {})
  validate_ref(value.authority, "authority")
  validate_ref(value.evidence_ref, "evidence-ref")
  validate_window(value, now, "grant")
  return value
end

function M.validate_cli_action_envelope(value)
  only_fields(value, {
    schema = true, effect_kind = true, capability = true, profile_ref = true,
    profile_artifact_sha256 = true, profile_sha256 = true, validation_receipt_ref = true, validation_receipt_sha256 = true,
    preauthorization_ref = true, preauthorization_sha256 = true, repository = true,
    run_id = true, operation_id = true, environment_receipt_ref = true,
    environment_receipt_sha256 = true, workspace_ref = true, plan_ref = true,
    plan_sha256 = true, grant_ref = true, grant_sha256 = true, case = true,
    resource_bounds = true, attempt = true, trace_id = true, dedup_key = true,
    expires_at = true, fence_id = true,
  }, "cli-action-envelope")
  if value.schema ~= M.schemas.cli_action_envelope then fail("unknown-schema", "CLI action envelope schema") end
  if value.effect_kind ~= "cli" or value.capability ~= "direct-argv" then
    fail("unsupported-effect", "only the direct-argv CLI effect is supported")
  end
  for _, field in ipairs({ "profile_ref", "validation_receipt_ref", "preauthorization_ref", "environment_receipt_ref", "plan_ref", "grant_ref" }) do
    pointer(value[field], field)
  end
  for _, field in ipairs({ "profile_artifact_sha256", "profile_sha256", "validation_receipt_sha256", "preauthorization_sha256", "environment_receipt_sha256", "plan_sha256", "grant_sha256" }) do
    digest(value[field], field)
  end
  validate_repository(value.repository, "action-repository")
  validate_ref(value.workspace_ref, "workspace-ref")
  if value.workspace_ref.kind ~= "workspace" or not bounded(value.run_id, 180)
    or not bounded(value.operation_id, 180) or value.run_id ~= value.operation_id
    or value.attempt ~= 1 or not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180)
    or not bounded(value.fence_id, 180) or time.iso_timestamp_epoch_seconds(value.expires_at) == nil then
    fail("malformed-envelope", "CLI action identity, expiry, attempt, or fence is invalid")
  end
  validate_case(value.case, {}, false)
  if value.case.kind ~= "cli" or value.case.skip_reason ~= nil then
    fail("unsupported-effect", "the action envelope must contain one executable CLI case")
  end
  only_fields(value.resource_bounds, { output_bytes = true }, "resource-bounds")
  if type(value.resource_bounds.output_bytes) ~= "number"
    or value.resource_bounds.output_bytes ~= math.floor(value.resource_bounds.output_bytes)
    or value.resource_bounds.output_bytes < 1024 or value.resource_bounds.output_bytes > 1048576 then
    fail("unbounded-value", "output_bytes must be from 1024 to 1048576")
  end
  return value
end

function M.validate_effect_authorization_receipt(value, envelope, now)
  only_fields(value, {
    schema = true, decision = true, reason_code = true, receipt_id = true,
    envelope_sha256 = true, evaluated_input_digests = true, issued_at = true,
    expires_at = true, fence_id = true, trace_id = true, dedup_key = true, auth_tag = true,
  }, "effect-authorization-receipt")
  if value.schema ~= M.schemas.effect_authorization_receipt
    or (value.decision ~= "allow" and value.decision ~= "deny")
    or not bounded(value.reason_code, 80) or not bounded(value.receipt_id, 180)
    or not bounded(value.fence_id, 180) or not bounded(value.trace_id, 180)
    or not bounded(value.dedup_key, 180) then
    fail("malformed-receipt", "authorization receipt identity or decision is invalid")
  end
  digest(value.envelope_sha256, "envelope_sha256")
  digest(value.auth_tag, "auth_tag")
  only_fields(value.evaluated_input_digests, {
    profile = true, validation_receipt = true, preauthorization = true,
    environment_receipt = true, plan = true, grant = true,
  }, "evaluated-input-digests")
  for field, item in pairs(value.evaluated_input_digests) do digest(item, field) end
  local issued = time.iso_timestamp_epoch_seconds(value.issued_at)
  local expires = time.iso_timestamp_epoch_seconds(value.expires_at)
  if issued == nil or expires == nil or expires <= issued then fail("malformed-receipt", "receipt validity window is invalid") end
  if now ~= nil then
    local current = time.iso_timestamp_epoch_seconds(now)
    if current == nil or current < issued or current >= expires then fail("stale-receipt", "authorization receipt is expired") end
  end
  if envelope ~= nil then
    M.validate_cli_action_envelope(envelope)
    if value.fence_id ~= envelope.fence_id or value.trace_id ~= envelope.trace_id
      or value.dedup_key ~= envelope.dedup_key or value.expires_at ~= envelope.expires_at then
      fail("foreign-receipt", "authorization receipt differs from the action envelope")
    end
  end
  return value
end


local function cli_allowed(argv, capabilities)
  for _, capability in ipairs(capabilities or {}) do
    local prefix = capability.argv_prefix
    if #prefix <= #argv then
      local matches = true
      for index, item in ipairs(prefix) do if argv[index] ~= item then matches = false break end end
      if matches then return true end
    end
  end
  return false
end

local function http_allowed(request, capabilities)
  local origin, path = split_http_url(request.url)
  if origin == nil then return false end
  for _, capability in ipairs(capabilities or {}) do
    if capability.origin == origin and contains(capability.methods, request.method) then
      for _, prefix in ipairs(capability.path_prefixes or {}) do
        if path:sub(1, #prefix) == prefix then return true end
      end
    end
  end
  return false
end

function M.plan_within_capabilities(plan, capabilities)
  M.validate_plan(plan)
  M.validate_capabilities(capabilities)
  for _, case in ipairs(plan.cases) do
    if case.skip_reason == nil then
      local allowed = case.kind == "cli" and cli_allowed(case.argv, capabilities.cli)
        or (case.kind == "http" and http_allowed(case.request, capabilities.http))
      if not allowed then return false, case.case_id end
    end
  end
  return true
end

function M.derive_grant(preauthorization, preauthorization_sha256, plan, plan_sha256, environment_receipt_sha256, request, values)
  M.validate_preauthorization(preauthorization, values and values.now)
  M.validate_plan(plan)
  M.validate_grant_request(request)
  digest(preauthorization_sha256, "preauthorization_sha256")
  digest(plan_sha256, "plan_sha256")
  digest(environment_receipt_sha256, "environment_receipt_sha256")
  if request.execution_mode ~= plan.execution_mode
    or request.preauthorization_sha256 ~= preauthorization_sha256
    or request.plan_sha256 ~= plan_sha256
    or request.environment_receipt_sha256 ~= environment_receipt_sha256
    or preauthorization.case_catalog_sha256 ~= plan.case_catalog_sha256
    or plan.environment_receipt_sha256 ~= environment_receipt_sha256
    or not same_repository(preauthorization.repository, plan.repository)
    or not same_repository(plan.repository, request.repository)
    or preauthorization.trace_id ~= request.trace_id or preauthorization.dedup_key ~= request.dedup_key
    or plan.trace_id ~= request.trace_id or plan.dedup_key ~= request.dedup_key then
    fail("foreign-derivation", "preauthorization, plan, environment, and request bindings differ")
  end
  local allowed, case_id = M.plan_within_capabilities(plan, preauthorization.capabilities)
  if not allowed then fail("capability-escalation", "plan case " .. tostring(case_id) .. " exceeds preauthorization") end
  values = values or {}
  validate_ref(values.evidence_ref, "derived-evidence-ref")
  local grant = {
    schema = M.schemas.grant,
    grant_id = values.grant_id,
    parent_authorization_sha256 = preauthorization_sha256,
    plan_sha256 = plan_sha256,
    environment_receipt_sha256 = environment_receipt_sha256,
    repository = copy(plan.repository),
    cli_capabilities = copy(preauthorization.capabilities.cli),
    http_capabilities = copy(preauthorization.capabilities.http),
    authority = copy(preauthorization.authority),
    policy_revision = preauthorization.policy_revision,
    evidence_ref = copy(values.evidence_ref),
    issued_at = values.issued_at,
    expires_at = values.expires_at,
    max_uses = 1,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  return M.validate_grant(grant, values.now)
end

local plan_request_fields = {
  schema = true, repository = true, module_plan_ref = true, module_plan_sha256 = true,
  case_catalog_ref = true, case_catalog_sha256 = true, environment_receipt_ref = true,
  environment_receipt_sha256 = true, browser_readiness_ref = true,
  browser_readiness_sha256 = true, plan_ref = true, artifact_root = true,
  trace_id = true, dedup_key = true, source_ref = true,
}

function M.validate_plan_request(value)
  only_fields(value, plan_request_fields, "plan-request")
  if value.schema ~= M.schemas.plan_request then fail("unknown-schema", "plan request schema") end
  validate_repository(value.repository, "plan-request-repository")
  for _, field in ipairs({ "module_plan_ref", "case_catalog_ref", "environment_receipt_ref", "browser_readiness_ref", "plan_ref", "artifact_root" }) do pointer(value[field], field) end
  for _, field in ipairs({ "module_plan_sha256", "case_catalog_sha256", "environment_receipt_sha256", "browser_readiness_sha256" }) do digest(value[field], field) end
  if value.plan_ref:sub(1, #value.artifact_root + 1) ~= value.artifact_root .. "/" then fail("foreign-plan", "plan_ref must be under artifact_root") end
  validate_ref(value.source_ref, "source-ref")
  if not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then fail("malformed-plan-request", "identity is invalid") end
  return value
end

function M.validate_plan_result(value)
  only_fields(value, { schema = true, status = true, plan_ref = true, plan_sha256 = true, residual_risk_count = true, failure_class = true, source_ref = true, trace_id = true, dedup_key = true }, "plan-result")
  if value.schema ~= M.schemas.plan_result or (value.status ~= "compiled" and value.status ~= "blocked") then fail("malformed-plan-result", "status or schema is invalid") end
  if value.status == "compiled" then
    pointer(value.plan_ref, "plan_ref")
    digest(value.plan_sha256, "plan_sha256")
    if value.failure_class ~= nil then fail("malformed-plan-result", "compiled result must not carry failure_class") end
  elseif not bounded(value.failure_class, 180) then
    fail("malformed-plan-result", "blocked result requires failure_class")
  end
  if type(value.residual_risk_count) ~= "number" or value.residual_risk_count < 0 or value.residual_risk_count ~= math.floor(value.residual_risk_count) then fail("malformed-plan-result", "residual_risk_count is invalid") end
  validate_ref(value.source_ref, "source-ref")
  if not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then fail("malformed-plan-result", "identity is invalid") end
  return value
end

function M.validate_grant_request(value)
  only_fields(value, {
    schema = true, execution_mode = true, repository = true,
    preauthorization_ref = true, preauthorization_sha256 = true,
    plan_ref = true, plan_sha256 = true, environment_receipt_ref = true,
    environment_receipt_sha256 = true, grant_ref = true, trace_id = true,
    dedup_key = true, source_ref = true,
  }, "grant-request")
  if value.schema ~= M.schemas.grant_request then fail("unknown-schema", "grant request schema") end
  if value.execution_mode ~= "structured-api-cli" and value.execution_mode ~= "agentic-browser" then
    fail("unsupported-execution-mode", tostring(value.execution_mode))
  end
  validate_repository(value.repository, "grant-request-repository")
  for _, field in ipairs({ "preauthorization_ref", "plan_ref", "environment_receipt_ref", "grant_ref" }) do pointer(value[field], field) end
  for _, field in ipairs({ "preauthorization_sha256", "plan_sha256", "environment_receipt_sha256" }) do digest(value[field], field) end
  validate_ref(value.source_ref, "source-ref")
  if not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then fail("malformed-grant-request", "identity is invalid") end
  return value
end

function M.validate_grant_result(value)
  only_fields(value, { schema = true, status = true, grant_ref = true, grant_sha256 = true, failure_class = true, source_ref = true, trace_id = true, dedup_key = true }, "grant-result")
  if value.schema ~= M.schemas.grant_result or (value.status ~= "granted" and value.status ~= "blocked") then fail("malformed-grant-result", "status or schema is invalid") end
  if value.status == "granted" then pointer(value.grant_ref, "grant_ref") digest(value.grant_sha256, "grant_sha256")
  elseif not bounded(value.failure_class, 180) then fail("malformed-grant-result", "blocked result requires failure_class") end
  validate_ref(value.source_ref, "source-ref")
  if not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then fail("malformed-grant-result", "identity is invalid") end
  return value
end

function M.attestation_matches(attestation, grant, value_digest)
  return type(attestation) == "table"
    and attestation.grant_sha256 == value_digest
    and attestation.policy_revision == grant.policy_revision
    and type(attestation.authority) == "table"
    and attestation.authority.kind == grant.authority.kind
    and attestation.authority.ref == grant.authority.ref
    and type(attestation.evidence_ref) == "table"
    and attestation.evidence_ref.kind == grant.evidence_ref.kind
    and attestation.evidence_ref.ref == grant.evidence_ref.ref
end

function M.equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, value in pairs(left) do
    if not M.equal(value, right[key]) then return false end
  end
  for key, _ in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
end

M.copy = copy

return M
