-- contract.testing_execution: value-only contracts for typed testing execution.
local strings = require("contract.strings")

local E = {}

E.schemas = {
  execution_request = "testing-runtime.execution-request.v1",
  execution_receipt = "testing-runtime.execution-receipt.v1",
  fixture_lifecycle = "testing-runtime.fixture-lifecycle.v1",
  fixture_receipt = "testing-runtime.fixture-receipt.v1",
  artifact_manifest = "test-artifacts.manifest.v1",
  artifact_attempt_commit_intent = "test-artifacts.attempt-commit-intent.v1",
  artifact_attempt_completed = "test-artifacts.attempt-completed.v1",
}

E.action_kinds = {
  navigate = true,
  ["wait-for-load"] = true,
  ["inspect-visible-elements"] = true,
  ["collect-console-network-health"] = true,
  ["bounded-navigation"] = true,
  ["open-visible-surface"] = true,
  ["safe-mutation-fixture"] = true,
}

E.assertion_kinds = {
  ["url-within-scope"] = true,
  ["document-ready"] = true,
  ["visible-text-present"] = true,
  ["visible-target-present"] = true,
  ["no-severe-console"] = true,
  ["no-failed-document-request"] = true,
}

E.mutation_kinds = {
  ["create-test-data"] = true,
  ["edit-test-data"] = true,
}

local max_string = 512
local max_actions = 32
local max_assertions = 8
local max_argv = 32

local function fail(classification, message)
  error("contract.testing-execution: " .. classification .. ": " .. message)
end

local function bounded(value, limit)
  return type(value) == "string"
    and value ~= ""
    and #value <= (limit or max_string)
    and value:find("[%z\1-\31]") == nil
end

local function dense_list(value, max_count)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    if key > highest then highest = key end
  end
  return count == highest and count <= max_count
end

local function only_fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, context .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then fail("malformed-" .. context, "unsupported field " .. tostring(key)) end
  end
end

local function require_bounded(value, field, limit)
  if not bounded(value, limit) then fail("malformed-field", field .. " must be a bounded string") end
  return value
end

local function require_integer(value, field, minimum, maximum)
  if type(value) ~= "number" or value ~= math.floor(value) or value < minimum or value > maximum then
    fail("malformed-field", field .. " must be an integer from " .. tostring(minimum) .. " to " .. tostring(maximum))
  end
  return value
end

local function require_sha256(value, field)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    fail("malformed-digest", field .. " must be a lowercase SHA-256 digest")
  end
  return value
end

local function require_artifact_pointer(value, field)
  if not strings.is_artifact_root(value, 4096) then
    fail("malformed-pointer", field .. " must be a safe .testing/runs/... pointer")
  end
  return value
end

local function require_identity_segment(value, field, limit)
  if not bounded(value, limit or 180) or value:match("^[%w._-]+$") == nil then
    fail("malformed-identity", field .. " must be a bounded path-safe identity segment")
  end
  return value
end

local function validate_string_list(value, field, max_count)
  if not dense_list(value, max_count) or #value == 0 then fail("malformed-list", field .. " must be a non-empty dense list") end
  for _, item in ipairs(value) do require_bounded(item, field .. " item") end
  return value
end

local assertion_fields = {
  type = true,
  target = true,
  expected = true,
}

local function validate_assertion(value)
  only_fields(value, assertion_fields, "assertion")
  if E.assertion_kinds[value.type] ~= true then fail("unsupported-assertion", tostring(value.type)) end
  if value.target ~= nil then require_bounded(value.target, "assertion.target") end
  if value.expected ~= nil then require_bounded(value.expected, "assertion.expected") end
  return value
end

local action_fields = {
  step = true,
  module_id = true,
  case_id = true,
  priority = true,
  action = true,
  target = true,
  url = true,
  assertions = true,
  mutation_kind = true,
  fixture_lifecycle_path = true,
}

local function validate_action(value, index)
  only_fields(value, action_fields, "action")
  require_integer(value.step, "actions[" .. tostring(index) .. "].step", 1, max_actions)
  require_bounded(value.module_id, "action.module_id", 180)
  require_bounded(value.case_id, "action.case_id", 180)
  require_bounded(value.priority, "action.priority", 8)
  if E.action_kinds[value.action] ~= true then fail("unsupported-action", tostring(value.action)) end
  require_bounded(value.target, "action.target")
  if value.url ~= nil then require_bounded(value.url, "action.url") end
  if not dense_list(value.assertions, max_assertions) or #value.assertions == 0 then
    fail("malformed-assertions", "action.assertions must be a non-empty bounded dense list")
  end
  for _, assertion in ipairs(value.assertions) do validate_assertion(assertion) end
  if value.action == "safe-mutation-fixture" then
    if E.mutation_kinds[value.mutation_kind] ~= true then fail("unsupported-mutation", tostring(value.mutation_kind)) end
    require_artifact_pointer(value.fixture_lifecycle_path, "action.fixture_lifecycle_path")
  elseif value.mutation_kind ~= nil or value.fixture_lifecycle_path ~= nil then
    fail("malformed-action", "fixture fields are only valid for safe-mutation-fixture")
  end
  return value
end

function E.validate_execution_request(value)
  only_fields(value, {
    schema = true,
    module = true,
    trace_id = true,
    dedup_key = true,
    artifact_root = true,
    base_url = true,
    allowed_origins = true,
    cdp_url = true,
    step_budget = true,
    plan_sha256 = true,
    actions = true,
  }, "execution-request")
  if value.schema ~= E.schemas.execution_request then fail("unknown-schema", "execution request schema") end
  require_bounded(value.module, "module", 180)
  require_bounded(value.trace_id, "trace_id", 180)
  require_bounded(value.dedup_key, "dedup_key", 180)
  require_artifact_pointer(value.artifact_root, "artifact_root")
  require_bounded(value.base_url, "base_url")
  validate_string_list(value.allowed_origins, "allowed_origins", 16)
  require_bounded(value.cdp_url, "cdp_url")
  require_integer(value.step_budget, "step_budget", 1, max_actions)
  require_sha256(value.plan_sha256, "plan_sha256")
  if not dense_list(value.actions, max_actions) or #value.actions == 0 then
    fail("malformed-actions", "actions must be a non-empty bounded dense list")
  end
  local seen = {}
  for index, action in ipairs(value.actions) do
    validate_action(action, index)
    if action.step ~= index then fail("malformed-actions", "action steps must be contiguous and ordered") end
    if seen[action.case_id] then fail("duplicate-case", action.case_id) end
    seen[action.case_id] = true
  end
  return value
end

local assertion_result_fields = {
  type = true,
  status = true,
  observation = true,
  evidence_pointer = true,
}

local function validate_assertion_result(value)
  only_fields(value, assertion_result_fields, "assertion-result")
  if E.assertion_kinds[value.type] ~= true then fail("unsupported-assertion", tostring(value.type)) end
  if value.status ~= "passed" and value.status ~= "failed" and value.status ~= "blocked" then
    fail("malformed-assertion-result", "unsupported status")
  end
  require_bounded(value.observation, "assertion_result.observation")
  require_artifact_pointer(value.evidence_pointer, "assertion_result.evidence_pointer")
  return value
end

local action_receipt_fields = {
  step = true,
  case_id = true,
  action = true,
  execution_status = true,
  assertion_status = true,
  observation = true,
  evidence_pointer = true,
  assertion_results = true,
  fixture_receipt_path = true,
}

local function validate_action_receipt(value, index)
  only_fields(value, action_receipt_fields, "action-receipt")
  require_integer(value.step, "receipt.actions.step", 1, max_actions)
  if value.step ~= index then fail("malformed-action-receipt", "receipt action steps must be contiguous and ordered") end
  require_bounded(value.case_id, "receipt.actions.case_id", 180)
  if E.action_kinds[value.action] ~= true then fail("unsupported-action", tostring(value.action)) end
  if value.execution_status ~= "executed" and value.execution_status ~= "failed" and value.execution_status ~= "blocked" then
    fail("malformed-action-receipt", "unsupported execution_status")
  end
  if value.assertion_status ~= "passed" and value.assertion_status ~= "failed" and value.assertion_status ~= "blocked" then
    fail("malformed-action-receipt", "unsupported assertion_status")
  end
  require_bounded(value.observation, "receipt.actions.observation")
  require_artifact_pointer(value.evidence_pointer, "receipt.actions.evidence_pointer")
  if not dense_list(value.assertion_results, max_assertions) or #value.assertion_results == 0 then
    fail("malformed-action-receipt", "assertion_results must be non-empty")
  end
  local passed, failed, blocked = 0, 0, 0
  for _, result in ipairs(value.assertion_results) do
    validate_assertion_result(result)
    if result.status == "passed" then passed = passed + 1
    elseif result.status == "failed" then failed = failed + 1
    else blocked = blocked + 1 end
  end
  if value.execution_status == "executed" then
    if value.assertion_status ~= "passed" or passed ~= #value.assertion_results then
      fail("inconsistent-action-receipt", "executed action requires all assertions passed")
    end
  elseif value.execution_status == "failed" then
    if value.assertion_status ~= "failed" or failed == 0 or blocked > 0 then
      fail("inconsistent-action-receipt", "failed action requires a failed assertion and no blocked assertions")
    end
  elseif value.assertion_status ~= "blocked" or blocked == 0 or failed > 0 then
    fail("inconsistent-action-receipt", "blocked action requires a blocked assertion and no failed assertions")
  end
  if value.fixture_receipt_path ~= nil then require_artifact_pointer(value.fixture_receipt_path, "fixture_receipt_path") end
  return value
end

function E.validate_execution_receipt(value)
  only_fields(value, {
    schema = true,
    module = true,
    request_sha256 = true,
    status = true,
    classification = true,
    action_count = true,
    executed_action_count = true,
    failed_action_count = true,
    blocked_action_count = true,
    actions = true,
  }, "execution-receipt")
  if value.schema ~= E.schemas.execution_receipt then fail("unknown-schema", "execution receipt schema") end
  require_bounded(value.module, "receipt.module", 180)
  require_sha256(value.request_sha256, "receipt.request_sha256")
  if value.status ~= "passed" and value.status ~= "failed" and value.status ~= "blocked" and value.status ~= "degraded" then
    fail("malformed-receipt", "unsupported status")
  end
  require_bounded(value.classification, "receipt.classification", 120)
  local expected_classification = value.status == "passed" and "typed-browser-assertions-passed"
    or value.status == "failed" and "typed-browser-assertion-failed"
    or "browser-execution-incomplete"
  if value.classification ~= expected_classification then
    fail("inconsistent-receipt", "classification does not match terminal status")
  end
  if not dense_list(value.actions, max_actions) then fail("malformed-receipt", "actions must be a bounded dense list") end
  require_integer(value.action_count, "receipt.action_count", 0, max_actions)
  require_integer(value.executed_action_count, "receipt.executed_action_count", 0, max_actions)
  require_integer(value.failed_action_count, "receipt.failed_action_count", 0, max_actions)
  require_integer(value.blocked_action_count, "receipt.blocked_action_count", 0, max_actions)
  if value.action_count ~= #value.actions then fail("receipt-count-mismatch", "action_count") end
  local executed, failed, blocked = 0, 0, 0
  for index, action in ipairs(value.actions) do
    validate_action_receipt(action, index)
    if action.execution_status == "executed" then executed = executed + 1
    elseif action.execution_status == "failed" then failed = failed + 1
    else blocked = blocked + 1 end
  end
  if executed ~= value.executed_action_count or failed ~= value.failed_action_count or blocked ~= value.blocked_action_count then
    fail("receipt-count-mismatch", "terminal counters")
  end
  if value.status == "passed" then
    if executed == 0 or executed ~= value.action_count or failed > 0 or blocked > 0 then
      fail("false-pass", "passed receipt requires every action executed and no failures or blocks")
    end
  elseif value.status == "failed" then
    if failed == 0 or blocked > 0 then
      fail("inconsistent-receipt", "failed receipt requires failed actions and no blocked actions")
    end
  elseif value.status == "degraded" then
    if blocked == 0 or failed > 0 then
      fail("inconsistent-receipt", "degraded receipt requires blocked actions and no failed actions")
    end
  elseif value.action_count > 0 and (blocked == 0 or executed > 0 or failed > 0) then
    fail("inconsistent-receipt", "blocked receipt requires only blocked actions")
  end
  return value
end

local fixture_fields = {
  schema = true,
  case_id = true,
  mutation_kind = true,
  prepare_argv = true,
  verify_ready_argv = true,
  cleanup_argv = true,
  rollback_argv = true,
  verify_clean_argv = true,
}

function E.validate_fixture_lifecycle(value)
  only_fields(value, fixture_fields, "fixture-lifecycle")
  if value.schema ~= E.schemas.fixture_lifecycle then fail("unknown-schema", "fixture lifecycle schema") end
  require_bounded(value.case_id, "fixture.case_id", 180)
  if E.mutation_kinds[value.mutation_kind] ~= true then fail("unsupported-mutation", tostring(value.mutation_kind)) end
  validate_string_list(value.prepare_argv, "prepare_argv", max_argv)
  validate_string_list(value.verify_ready_argv, "verify_ready_argv", max_argv)
  validate_string_list(value.cleanup_argv, "cleanup_argv", max_argv)
  validate_string_list(value.verify_clean_argv, "verify_clean_argv", max_argv)
  if value.rollback_argv ~= nil then validate_string_list(value.rollback_argv, "rollback_argv", max_argv) end
  return value
end

function E.validate_fixture_receipt(value)
  only_fields(value, {
    schema = true,
    operation_id = true,
    case_id = true,
    mutation_kind = true,
    status = true,
    prepare_status = true,
    verify_ready_status = true,
    cleanup_status = true,
    rollback_status = true,
    verify_clean_status = true,
    evidence_pointer = true,
  }, "fixture-receipt")
  if value.schema ~= E.schemas.fixture_receipt then fail("unknown-schema", "fixture receipt schema") end
  require_bounded(value.operation_id, "fixture_receipt.operation_id", 180)
  require_bounded(value.case_id, "fixture_receipt.case_id", 180)
  if E.mutation_kinds[value.mutation_kind] ~= true then fail("unsupported-mutation", tostring(value.mutation_kind)) end
  if value.status ~= "clean" and value.status ~= "blocked" then fail("malformed-fixture-receipt", "unsupported status") end
  for _, field in ipairs({ "prepare_status", "verify_ready_status", "cleanup_status", "verify_clean_status" }) do
    require_bounded(value[field], "fixture_receipt." .. field, 32)
  end
  if value.rollback_status ~= nil then require_bounded(value.rollback_status, "fixture_receipt.rollback_status", 32) end
  require_artifact_pointer(value.evidence_pointer, "fixture_receipt.evidence_pointer")
  if value.status == "clean" and (value.cleanup_status ~= "passed" or value.verify_clean_status ~= "passed") then
    fail("false-clean", "clean fixture receipt requires cleanup and verify-clean")
  end
  return value
end

local artifact_attempt_identity_fields = {
  run_id = true,
  trace_id = true,
  dedup_key = true,
  artifact_kind = true,
  attempt_id = true,
  fence_version = true,
}

local function validate_artifact_attempt_identity(value)
  require_identity_segment(value.run_id, "run_id")
  require_bounded(value.trace_id, "trace_id", 180)
  require_bounded(value.dedup_key, "dedup_key", 180)
  require_identity_segment(value.artifact_kind, "artifact_kind", 120)
  require_identity_segment(value.attempt_id, "attempt_id")
  require_integer(value.fence_version, "fence_version", 1, 9007199254740991)
  return value
end

function E.validate_artifact_attempt_intent(value)
  local allowed = { schema = true }
  for field, present in pairs(artifact_attempt_identity_fields) do allowed[field] = present end
  only_fields(value, allowed, "artifact-attempt-intent")
  if value.schema ~= E.schemas.artifact_attempt_commit_intent then
    fail("unknown-schema", "artifact attempt commit intent schema")
  end
  return validate_artifact_attempt_identity(value)
end

function E.validate_artifact_attempt_completion(value)
  local allowed = {
    schema = true,
    manifest_sha256 = true,
    artifact_pointer = true,
  }
  for field, present in pairs(artifact_attempt_identity_fields) do allowed[field] = present end
  only_fields(value, allowed, "artifact-attempt-completion")
  if value.schema ~= E.schemas.artifact_attempt_completed then
    fail("unknown-schema", "artifact attempt completion schema")
  end
  validate_artifact_attempt_identity(value)
  require_sha256(value.manifest_sha256, "manifest_sha256")
  require_artifact_pointer(value.artifact_pointer, "artifact_pointer")
  return value
end

function E.validate_artifact_manifest(value)
  only_fields(value, {
    schema = true,
    artifact_root = true,
    algorithm = true,
    entries = true,
    entry_count = true,
    root_digest = true,
  }, "artifact-manifest")
  if value.schema ~= E.schemas.artifact_manifest then fail("unknown-schema", "artifact manifest schema") end
  require_artifact_pointer(value.artifact_root, "manifest.artifact_root")
  if value.algorithm ~= "sha256" then fail("malformed-manifest", "algorithm must be sha256") end
  if not dense_list(value.entries, 256) then fail("malformed-manifest", "entries must be a bounded dense list") end
  require_integer(value.entry_count, "manifest.entry_count", 0, 256)
  if value.entry_count ~= #value.entries then fail("manifest-count-mismatch", "entry_count") end
  require_sha256(value.root_digest, "manifest.root_digest")
  local previous, seen = nil, {}
  for _, entry in ipairs(value.entries) do
    only_fields(entry, { path = true, media_type = true, size_bytes = true, sha256 = true }, "manifest-entry")
    require_artifact_pointer(entry.path, "manifest.entries.path")
    if entry.path:sub(1, #value.artifact_root + 1) ~= value.artifact_root .. "/" then
      fail("manifest-path-escape", entry.path)
    end
    if entry.path == value.artifact_root .. "/artifact-manifest.json" then fail("manifest-self-inclusion", entry.path) end
    require_bounded(entry.media_type, "manifest.entries.media_type", 120)
    require_integer(entry.size_bytes, "manifest.entries.size_bytes", 0, 1000000000)
    require_sha256(entry.sha256, "manifest.entries.sha256")
    if seen[entry.path] then fail("duplicate-manifest-path", entry.path) end
    if previous ~= nil and entry.path <= previous then fail("manifest-order", "entries must be sorted by path") end
    seen[entry.path] = true
    previous = entry.path
  end
  return value
end

E.require_sha256 = require_sha256
E.require_artifact_pointer = require_artifact_pointer

return E
