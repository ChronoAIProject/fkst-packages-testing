local strings = require("contract.strings")
local structured = require("contract.structured_execution")
local time = require("contract.time")

local M = {}

M.schemas = {
  grant = "testing-runner.ai-browser-control.grant.v1",
  request = "testing-runner.ai-browser-control.request.v1",
  observation = "testing-runner.ai-browser-control.observation.v1",
  action = "testing-runner.ai-browser-control.action.v1",
  step_receipt = "testing-runner.ai-browser-control.step-receipt.v1",
  receipt = "testing-runner.ai-browser-control.receipt.v1",
}

M.action_kinds = {
  click = true,
  type = true,
  submit = true,
  press_tab = true,
  finish = true,
}

local function fail(classification, message)
  error("contract.browser-control: " .. classification .. ": " .. message)
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
  if not bounded(value.kind, 80) or not bounded(value.ref, 512) then
    fail("malformed-reference", label .. " must be bounded")
  end
  return value
end

local function validate_repository(value)
  return structured.validate_repository(value, "browser-control-repository")
end

local function exact_https_origin(value, label)
  if not bounded(value, 512) or value:match("^https://[^/@?#]+$") == nil
    or value:find("@", 1, true) ~= nil then
    fail("malformed-origin", label .. " must be an exact credential-free HTTPS origin")
  end
  return value
end

local function exact_loopback_origin(value)
  if not bounded(value, 512) then fail("malformed-callback", "callback origin is required") end
  local host, port = value:match("^http://([^/:]+):(%d+)$")
  if host == nil then host, port = value:match("^http://(%[[^%]]+%]):(%d+)$") end
  if (host ~= "127.0.0.1" and host ~= "localhost" and host ~= "[::1]")
    or tonumber(port) == nil or tonumber(port) < 1 or tonumber(port) > 65535 then
    fail("malformed-callback", "callback origin must be exact loopback HTTP with a nonzero port")
  end
  return value
end

local function exact_path(value, label)
  if not bounded(value, 512) or value:sub(1, 1) ~= "/"
    or value:find("?", 1, true) or value:find("#", 1, true) then
    fail("malformed-path", label .. " must be an exact query-free path")
  end
  return value
end

local function validate_window(value, now)
  if not bounded(value.issued_at, 40) or not bounded(value.expires_at, 40) then
    fail("malformed-time", "grant timestamps are required")
  end
  local issued = time.iso_timestamp_epoch_seconds(value.issued_at)
  local expires = time.iso_timestamp_epoch_seconds(value.expires_at)
  if issued == nil or expires == nil or expires <= issued then
    fail("malformed-time", "grant validity window is invalid")
  end
  if now ~= nil then
    local current = time.iso_timestamp_epoch_seconds(now)
    if current == nil or current < issued or current >= expires then
      fail("stale-grant", "browser grant is outside its validity window")
    end
  end
end

local function validate_action_kinds(value)
  if not dense(value, 5, true) then fail("malformed-actions", "allowed actions must be bounded") end
  local seen = {}
  for _, kind in ipairs(value) do
    if M.action_kinds[kind] ~= true or seen[kind] then fail("malformed-actions", "unsupported or duplicate action") end
    seen[kind] = true
  end
  if not seen.finish then fail("malformed-actions", "finish must remain available") end
  return seen
end

local function validate_secret_refs(value)
  if not dense(value, 8, false) then fail("malformed-secret-refs", "secret refs must be bounded") end
  local seen = {}
  for _, ref in ipairs(value) do
    if not bounded(ref, 180) or ref:match("^[%w%._%-]+$") == nil or seen[ref] then
      fail("malformed-secret-refs", "secret ref names must be unique and opaque")
    end
    seen[ref] = true
  end
  return seen
end

function M.validate_grant(value, now)
  only_fields(value, {
    schema = true, grant_id = true, parent_authorization_sha256 = true, repository = true,
    environment_receipt_sha256 = true, readiness_attempt_id = true,
    readiness_attempt_sha256 = true, target_id = true, target_sha256 = true,
    reviewed_plan_sha256 = true, allowed_auth_origins = true, callback = true,
    allowed_actions = true, approved_secret_refs = true,
    step_budget = true, time_budget_seconds = true,
    authority = true, policy_revision = true, evidence_ref = true,
    issued_at = true, expires_at = true, max_uses = true,
    trace_id = true, dedup_key = true,
  }, "grant")
  if value.schema ~= M.schemas.grant then fail("unknown-schema", "browser grant schema") end
  if not bounded(value.grant_id, 180) or not bounded(value.readiness_attempt_id, 180)
    or not bounded(value.target_id, 256) or not bounded(value.policy_revision, 180)
    or not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180)
    or value.max_uses ~= 1 then
    fail("malformed-grant", "browser grant identity and single-use policy are invalid")
  end
  validate_repository(value.repository)
  digest(value.parent_authorization_sha256, "parent_authorization_sha256")
  digest(value.environment_receipt_sha256, "environment_receipt_sha256")
  digest(value.readiness_attempt_sha256, "readiness_attempt_sha256")
  digest(value.target_sha256, "target_sha256")
  digest(value.reviewed_plan_sha256, "reviewed_plan_sha256")
  if not dense(value.allowed_auth_origins, 4, true) then fail("malformed-origin", "auth origins must be bounded") end
  local origins = {}
  for _, origin in ipairs(value.allowed_auth_origins) do
    exact_https_origin(origin, "auth origin")
    if origins[origin] then fail("malformed-origin", "auth origins must be unique") end
    origins[origin] = true
  end
  only_fields(value.callback, { origin = true, path = true }, "callback")
  exact_loopback_origin(value.callback.origin)
  exact_path(value.callback.path, "callback path")
  if origins[value.callback.origin] then fail("malformed-callback", "callback cannot be an auth origin") end
  validate_action_kinds(value.allowed_actions)
  validate_secret_refs(value.approved_secret_refs or {})
  if type(value.step_budget) ~= "number" or value.step_budget < 1 or value.step_budget > 8
    or value.step_budget ~= math.floor(value.step_budget)
    or type(value.time_budget_seconds) ~= "number" or value.time_budget_seconds < 1
    or value.time_budget_seconds > 600 or value.time_budget_seconds ~= math.floor(value.time_budget_seconds) then
    fail("malformed-budget", "browser budgets are invalid")
  end
  validate_ref(value.authority, "authority")
  validate_ref(value.evidence_ref, "evidence-ref")
  validate_window(value, now)
  return value
end

function M.derive_grant(preauthorization, preauthorization_sha256, plan, plan_sha256,
  environment_receipt_sha256, request, values)
  structured.validate_preauthorization(preauthorization, values and values.now)
  structured.validate_plan(plan)
  structured.validate_grant_request(request)
  digest(preauthorization_sha256, "preauthorization_sha256")
  digest(plan_sha256, "plan_sha256")
  digest(environment_receipt_sha256, "environment_receipt_sha256")
  values = values or {}
  if request.execution_mode ~= "agentic-browser" or plan.execution_mode ~= "agentic-browser"
    or request.preauthorization_sha256 ~= preauthorization_sha256
    or request.plan_sha256 ~= plan_sha256
    or request.environment_receipt_sha256 ~= environment_receipt_sha256
    or preauthorization.case_catalog_sha256 ~= plan.case_catalog_sha256
    or plan.environment_receipt_sha256 ~= environment_receipt_sha256
    or not structured.same_repository(preauthorization.repository, plan.repository)
    or not structured.same_repository(plan.repository, request.repository)
    or preauthorization.trace_id ~= request.trace_id or preauthorization.dedup_key ~= request.dedup_key
    or plan.trace_id ~= request.trace_id or plan.dedup_key ~= request.dedup_key then
    fail("foreign-derivation", "preauthorization, browser plan, environment, and request bindings differ")
  end
  local grant = {
    schema = M.schemas.grant,
    grant_id = values.grant_id,
    parent_authorization_sha256 = preauthorization_sha256,
    repository = structured.copy(plan.repository),
    environment_receipt_sha256 = environment_receipt_sha256,
    readiness_attempt_id = values.readiness_attempt_id,
    readiness_attempt_sha256 = values.readiness_attempt_sha256,
    target_id = values.target_id,
    target_sha256 = values.target_sha256,
    reviewed_plan_sha256 = plan_sha256,
    allowed_auth_origins = structured.copy(values.allowed_auth_origins or {}),
    callback = structured.copy(values.callback),
    allowed_actions = structured.copy(values.allowed_actions or {}),
    approved_secret_refs = structured.copy(values.approved_secret_refs or {}),
    step_budget = values.step_budget,
    time_budget_seconds = values.time_budget_seconds,
    authority = structured.copy(preauthorization.authority),
    policy_revision = preauthorization.policy_revision,
    evidence_ref = structured.copy(values.evidence_ref),
    issued_at = values.issued_at,
    expires_at = values.expires_at,
    max_uses = 1,
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
  }
  return M.validate_grant(grant, values.now)
end

function M.validate_request(value)
  only_fields(value, {
    schema = true, repository = true, environment_receipt_ref = true,
    environment_receipt_sha256 = true, reviewed_plan_ref = true,
    reviewed_plan_sha256 = true, browser_grant_ref = true,
    browser_grant_sha256 = true, artifact_root = true,
    trace_id = true, dedup_key = true, source_ref = true,
  }, "request")
  if value.schema ~= M.schemas.request then fail("unknown-schema", "browser request schema") end
  validate_repository(value.repository)
  for _, field in ipairs({
    "environment_receipt_ref", "reviewed_plan_ref", "browser_grant_ref", "artifact_root",
  }) do pointer(value[field], field) end
  for _, field in ipairs({
    "environment_receipt_sha256", "reviewed_plan_sha256", "browser_grant_sha256",
  }) do digest(value[field], field) end
  if value.reviewed_plan_ref:sub(1, #value.artifact_root + 1) ~= value.artifact_root .. "/"
    or value.browser_grant_ref:sub(1, #value.artifact_root + 1) ~= value.artifact_root .. "/" then
    fail("foreign-artifact", "plan and grant must be under the browser artifact root")
  end
  if not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then
    fail("malformed-request", "trace and dedup identity are required")
  end
  validate_ref(value.source_ref, "source-ref")
  return value
end

local function safe_label(value)
  if not bounded(value, 160) or value:find("@", 1, true)
    or value:lower():find("token=", 1, true)
    or value:lower():find("secret=", 1, true)
    or value:lower():find("password=", 1, true) then return false end
  for token in value:gmatch("[A-Za-z0-9_+/=%-]+") do
    if #token >= 32 then return false end
  end
  return true
end

local function validate_signals(value)
  only_fields(value, {
    callback_detected = true, mfa_detected = true, captcha_detected = true,
    target_changed = true, popup_detected = true,
  }, "signals")
  for _, field in ipairs({
    "callback_detected", "mfa_detected", "captcha_detected", "target_changed", "popup_detected",
  }) do if type(value[field]) ~= "boolean" then fail("malformed-signals", field .. " must be boolean") end end
end

function M.validate_observation(value)
  only_fields(value, {
    schema = true, turn = true, document_token = true, target_id = true,
    origin = true, path = true, ready_state = true, controls = true,
    signals = true, console_count = true, network_count = true,
  }, "observation")
  if value.schema ~= M.schemas.observation or type(value.turn) ~= "number" or value.turn < 1
    or value.turn > 8 or value.turn ~= math.floor(value.turn)
    or not digest(value.document_token, "document_token") or not bounded(value.target_id, 256)
    or not bounded(value.origin, 512) or not exact_path(value.path, "observation path")
    or (value.ready_state ~= "interactive" and value.ready_state ~= "complete")
    or not dense(value.controls, 32, false) then
    fail("malformed-observation", "observation identity or bounds are invalid")
  end
  for _, control in ipairs(value.controls) do
    only_fields(control, { handle = true, role = true, kind = true, label = true, focused = true }, "control")
    if not bounded(control.handle, 80) or control.handle:match("^[0-9a-f]+$") == nil
      or not bounded(control.role, 80) or not bounded(control.kind, 80)
      or not safe_label(control.label) or type(control.focused) ~= "boolean" then
      fail("malformed-control", "control projection is invalid")
    end
  end
  validate_signals(value.signals)
  for _, field in ipairs({ "console_count", "network_count" }) do
    if type(value[field]) ~= "number" or value[field] < 0 or value[field] > 10000
      or value[field] ~= math.floor(value[field]) then fail("malformed-observation", field .. " is invalid") end
  end
  return value
end

function M.document_digest(observation)
  M.validate_observation(observation)
  return observation.document_token
end

function M.validate_action(value, allowed_actions, approved_secret_refs)
  only_fields(value, {
    schema = true, turn = true, kind = true, handle = true,
    secret_ref = true, advisory_status = true,
  }, "action")
  if value.schema ~= M.schemas.action or type(value.turn) ~= "number" or value.turn < 1
    or value.turn > 8 or value.turn ~= math.floor(value.turn) or M.action_kinds[value.kind] ~= true then
    fail("malformed-action", "action identity is invalid")
  end
  local allowed = validate_action_kinds(allowed_actions)
  if not allowed[value.kind] then fail("unauthorized-action", value.kind) end
  local secrets = validate_secret_refs(approved_secret_refs or {})
  if value.kind == "click" or value.kind == "submit" then
    if not bounded(value.handle, 80) or value.secret_ref ~= nil or value.advisory_status ~= nil then
      fail("malformed-action", value.kind .. " requires only a handle")
    end
  elseif value.kind == "type" then
    if not bounded(value.handle, 80) or secrets[value.secret_ref] ~= true or value.advisory_status ~= nil then
      fail("unauthorized-secret-ref", "type requires an approved opaque secret ref")
    end
  elseif value.kind == "press_tab" then
    if value.handle ~= nil or value.secret_ref ~= nil or value.advisory_status ~= nil then
      fail("malformed-action", "press_tab takes no arguments")
    end
  elseif value.kind == "finish" then
    if value.handle ~= nil or value.secret_ref ~= nil
      or (value.advisory_status ~= "success" and value.advisory_status ~= "blocked") then
      fail("malformed-action", "finish requires one advisory status")
    end
  end
  return value
end

function M.validate_step_receipt(value, grant)
  only_fields(value, {
    schema = true, turn = true, action = true, before = true, after = true,
    status = true, classification = true,
  }, "step-receipt")
  if value.schema ~= M.schemas.step_receipt
    or (value.status ~= "executed" and value.status ~= "advisory" and value.status ~= "blocked")
    or not bounded(value.classification, 80) then
    fail("malformed-step-receipt", "step receipt status is invalid")
  end
  M.validate_action(value.action, grant.allowed_actions, grant.approved_secret_refs)
  M.validate_observation(value.before)
  M.validate_observation(value.after)
  if value.turn ~= value.action.turn or value.turn ~= value.before.turn or value.turn ~= value.after.turn then
    fail("step-binding-mismatch", "step turn identity differs")
  end
  return value
end

function M.validate_completion(value)
  only_fields(value, {
    callback_observed = true, process_exit_zero = true,
    whoami_succeeded = true, status_authenticated = true,
  }, "completion")
  for _, field in ipairs({
    "callback_observed", "process_exit_zero", "whoami_succeeded", "status_authenticated",
  }) do if type(value[field]) ~= "boolean" then fail("malformed-completion", field .. " must be boolean") end end
  return value
end

function M.validate_receipt(value, grant)
  only_fields(value, {
    schema = true, status = true, classification = true, repository = true,
    environment_receipt_sha256 = true, reviewed_plan_sha256 = true,
    browser_grant_sha256 = true, readiness_attempt_sha256 = true,
    target_sha256 = true, case_id = true, steps = true, completion = true,
    artifact_root = true, trace_id = true, dedup_key = true,
  }, "receipt")
  if value.schema ~= M.schemas.receipt
    or (value.status ~= "passed" and value.status ~= "blocked" and value.status ~= "failed")
    or not bounded(value.classification, 80) or not bounded(value.case_id, 180)
    or not dense(value.steps, grant.step_budget, false) then
    fail("malformed-receipt", "browser receipt status or bounds are invalid")
  end
  validate_repository(value.repository)
  for _, field in ipairs({
    "environment_receipt_sha256", "reviewed_plan_sha256", "browser_grant_sha256",
    "readiness_attempt_sha256", "target_sha256",
  }) do digest(value[field], field) end
  for _, step in ipairs(value.steps) do M.validate_step_receipt(step, grant) end
  M.validate_completion(value.completion)
  pointer(value.artifact_root, "artifact_root")
  if not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then
    fail("malformed-receipt", "receipt identity is invalid")
  end
  return value
end

return M
