-- contract.testing: shared testing payload helpers for small, bounded handoff contracts.
local strings = require("contract.strings")

local T = {}

T.schemas = {
  runner_result = "testing-runner.result.v1",
  native_metadata = "testing-runner.native-metadata.v1",
  artifact_summary = "test-artifacts.summary.v1",
  publication_request = "test-publication.publication-request.v1",
  module_no_browser_summary = "testing-runner.module-no-browser-summary.v1",
  online_heartbeat_summary = "testing-runner.online-heartbeat-summary.v1",
  browser_driver_summary = "testing-runner.browser-driver-summary.v1",
  mutation_policy = "testing-runner.mutation-policy.v1",
  mutation_policy_summary = "testing-runner.mutation-policy-summary.v1",
}

T.runner_statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
}

T.summary_statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  mixed = true,
}

local max_string = 512
local max_id = 180

local function has_no_control(text)
  return type(text) == "string" and text:find("[%z\1-\31]") == nil
end

function T.is_bounded_id(value)
  return strings.is_bounded_string(value, max_id) and has_no_control(value)
end

function T.safe_key(value, fallback)
  local text = tostring(value or fallback or "testing")
  text = text:gsub("[^%w%._%-]", "-")
  text = text:gsub("%.+", ".")
  text = text:gsub("^%.", "")
  if text == "" then text = fallback or "testing" end
  if #text > max_id then text = text:sub(1, max_id) end
  return text
end

local function bounded_or_sanitized(value, fallback, limit)
  if type(value) == "string" and value ~= "" and #value <= limit and has_no_control(value) then
    return value
  end
  local safe = strings.sanitize_key(value or fallback, limit)
  if safe == "" or safe == "empty" then return fallback end
  return safe
end

function T.copy_source_ref(value, fallback_kind, fallback_ref)
  if type(value) == "table" then
    return {
      kind = bounded_or_sanitized(value.kind, fallback_kind or "request", 80),
      ref = bounded_or_sanitized(value.ref, fallback_ref or "unknown", max_string),
    }
  end
  return {
    kind = bounded_or_sanitized(fallback_kind, "request", 80),
    ref = bounded_or_sanitized(fallback_ref, "unknown", max_string),
  }
end

function T.copy_scalar_map(value)
  if value == nil then return nil end
  if type(value) ~= "table" then return nil end
  local copy = {}
  local count = 0
  for key, item in pairs(value) do
    if type(key) ~= "string" or not strings.is_bounded_string(key, 80) then return nil end
    if type(item) == "string" then
      if not strings.is_bounded_string(item, max_string) or not has_no_control(item) then return nil end
      copy[key] = item
    elseif type(item) == "number" or type(item) == "boolean" then
      copy[key] = item
    else
      return nil
    end
    count = count + 1
    if count > 16 then return nil end
  end
  return copy
end

local function has_only(value, allowed)
  for key, _ in pairs(value) do
    if allowed[key] ~= true then return false end
  end
  return true
end

local function bounded_field(value, limit)
  return type(value) == "string" and value ~= "" and #value <= (limit or max_string) and has_no_control(value)
end

local function dense_list(value)
  if type(value) ~= "table" then return false end
  local count, max_index = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return false end
    count = count + 1
    if key > max_index then max_index = key end
  end
  return count == max_index
end

local function copy_readiness(value)
  if type(value) ~= "table" then return nil end
  if not has_only(value, { status = true, sessions = true }) then return nil end
  if not bounded_field(value.status, 80) then return nil end
  local copy = { status = value.status }
  if value.sessions ~= nil then
    if not dense_list(value.sessions) or #value.sessions > 16 then return nil end
    local sessions = {}
    for _, session in ipairs(value.sessions) do
      if type(session) ~= "table" then return nil end
      if not has_only(session, { role = true, status = true }) then return nil end
      if not bounded_field(session.role, 80) or not bounded_field(session.status, 80) then return nil end
      table.insert(sessions, { role = session.role, status = session.status })
    end
    if #sessions > 0 then copy.sessions = sessions end
  end
  return copy
end

local function copy_module_no_browser(value)
  if not has_only(value, { schema = true, module = true, status = true, mode = true }) then return nil end
  if not bounded_field(value.module, max_string) or not bounded_field(value.status, 80) or not bounded_field(value.mode, 80) then return nil end
  return {
    schema = T.schemas.module_no_browser_summary,
    module = value.module,
    status = value.status,
    mode = value.mode,
  }
end

local function copy_online_heartbeat(value)
  if not has_only(value, { schema = true, target = true, status = true, mode = true }) then return nil end
  if not bounded_field(value.target, max_string) or not bounded_field(value.status, 80) or not bounded_field(value.mode, 80) then return nil end
  return {
    schema = T.schemas.online_heartbeat_summary,
    target = value.target,
    status = value.status,
    mode = value.mode,
  }
end

local function copy_browser_driver(value)
  if not has_only(value, { schema = true, module = true, driver = true, status = true, mode = true, readiness = true }) then return nil end
  if not bounded_field(value.module, max_string) or not bounded_field(value.driver, max_string) then return nil end
  if not bounded_field(value.status, 80) or not bounded_field(value.mode, 80) then return nil end
  local copy = {
    schema = T.schemas.browser_driver_summary,
    module = value.module,
    driver = value.driver,
    status = value.status,
    mode = value.mode,
  }
  if value.readiness ~= nil then
    local readiness = copy_readiness(value.readiness)
    if readiness == nil then return nil end
    copy.readiness = readiness
  end
  return copy
end

local mutation_action_fields = {
  action = true,
  target = true,
  evidence_path = true,
  fixture_path = true,
  cleanup_path = true,
  rollback_path = true,
}

local function bounded_artifact_pointer(value)
  return value == nil or strings.is_artifact_root(value)
end

local function copy_mutation_action(value)
  if type(value) ~= "table" or not has_only(value, mutation_action_fields) then return nil end
  if not bounded_field(value.action, 80) or not bounded_field(value.target, 80) then return nil end
  local copy = {
    action = value.action,
    target = value.target,
  }
  for _, field in ipairs({ "evidence_path", "fixture_path", "cleanup_path", "rollback_path" }) do
    if value[field] ~= nil then
      if not bounded_artifact_pointer(value[field]) then return nil end
      copy[field] = value[field]
    end
  end
  return copy
end

local function copy_mutation_actions(value, allow_empty)
  if not dense_list(value) or #value > 8 then return nil end
  if #value == 0 and not allow_empty then return nil end
  local actions = {}
  for _, action in ipairs(value) do
    local copied = copy_mutation_action(action)
    if copied == nil then return nil end
    table.insert(actions, copied)
  end
  return actions
end

function T.copy_mutation_policy(value)
  if value == nil then return nil end
  if type(value) ~= "table" then return nil end
  if not has_only(value, { schema = true, priority = true, actions = true }) then return nil end
  if value.schema ~= T.schemas.mutation_policy then return nil end
  if value.priority ~= nil and not bounded_field(value.priority, 80) then return nil end
  local actions = copy_mutation_actions(value.actions)
  if actions == nil then return nil end
  return {
    schema = T.schemas.mutation_policy,
    priority = value.priority or "P2",
    actions = actions,
  }
end

local function action_has_safety_pointer(action)
  return action.evidence_path ~= nil
    and (action.fixture_path ~= nil or action.cleanup_path ~= nil or action.rollback_path ~= nil)
end

local function mutation_block(summary, classification, reason)
  summary.decision = "blocked"
  summary.classification = classification
  summary.reason = reason
  return summary
end

function T.mutation_policy_summary(policy)
  local copy = T.copy_mutation_policy(policy)
  if copy == nil then return nil end
  local summary = {
    schema = T.schemas.mutation_policy_summary,
    priority = copy.priority,
    decision = "allowed",
    classification = "SAFE_MUTATION_ALLOWED",
    action_count = #copy.actions,
    actions = copy.actions,
  }
  for _, action in ipairs(copy.actions) do
    if action.action ~= "create_test_data" and action.action ~= "edit_test_data" then
      return mutation_block(summary, "NOT_EXECUTED_RISK", "mutation action is not allow-listed")
    end
    if action.target ~= "local_test_data" then
      return mutation_block(summary, "NOT_EXECUTED_RISK", "mutation target is not local test data")
    end
    if not action_has_safety_pointer(action) then
      return mutation_block(summary, "FIXTURE_GAP", "safe mutation requires evidence plus fixture, cleanup, or rollback pointer")
    end
  end
  return summary
end

function T.missing_mutation_policy_summary(priority)
  return {
    schema = T.schemas.mutation_policy_summary,
    priority = priority or "P2",
    decision = "blocked",
    classification = "NOT_EXECUTED_RISK",
    reason = "P2 native execution requires explicit mutation policy",
    action_count = 0,
    actions = {},
  }
end

function T.copy_mutation_policy_summary(value)
  if value == nil then return nil end
  if type(value) ~= "table" then return nil end
  local allowed = {
    schema = true,
    priority = true,
    decision = true,
    classification = true,
    reason = true,
    action_count = true,
    actions = true,
  }
  if not has_only(value, allowed) then return nil end
  if value.schema ~= T.schemas.mutation_policy_summary then return nil end
  if not bounded_field(value.priority, 80) or not bounded_field(value.decision, 80) then return nil end
  if not bounded_field(value.classification, 80) then return nil end
  if value.decision ~= "allowed" and value.decision ~= "blocked" then return nil end
  if value.classification ~= "SAFE_MUTATION_ALLOWED"
    and value.classification ~= "NOT_EXECUTED_RISK"
    and value.classification ~= "FIXTURE_GAP"
  then
    return nil
  end
  if value.reason ~= nil and not bounded_field(value.reason, max_string) then return nil end
  if type(value.action_count) ~= "number" then return nil end
  local actions = copy_mutation_actions(value.actions, true)
  if actions == nil then return nil end
  if value.action_count ~= #actions then return nil end
  local copy = {
    schema = T.schemas.mutation_policy_summary,
    priority = value.priority,
    decision = value.decision,
    classification = value.classification,
    action_count = value.action_count,
    actions = actions,
  }
  if value.reason ~= nil then copy.reason = value.reason end
  return copy
end

function T.copy_native_summary(value)
  if value == nil then return nil end
  if type(value) ~= "table" then return nil end
  if value.schema == T.schemas.module_no_browser_summary then
    return copy_module_no_browser(value)
  end
  if value.schema == T.schemas.online_heartbeat_summary then
    return copy_online_heartbeat(value)
  end
  if value.schema == T.schemas.browser_driver_summary then
    return copy_browser_driver(value)
  end
  if value.schema == T.schemas.mutation_policy_summary then
    return T.copy_mutation_policy_summary(value)
  end
  return nil
end

local function source_basis(source_ref, artifact_root, fallback)
  if type(source_ref) == "table" then
    return tostring(source_ref.kind or "source") .. ":" .. tostring(source_ref.ref or "unknown")
  end
  return tostring(artifact_root or fallback or "testing")
end

function T.trace_id(value, source_ref, artifact_root)
  if T.is_bounded_id(value) then return value end
  return "trace-" .. strings.decimal_checksum(source_basis(source_ref, artifact_root, "trace"))
end

function T.dedup_key(value, parts)
  if T.is_bounded_id(value) then return value end
  return T.safe_key(table.concat(parts or { "testing" }, "-"), "testing")
end

return T
