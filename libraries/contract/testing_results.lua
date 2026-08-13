-- contract.testing_results: canonical, execution-only testing result contracts.
local strings = require("contract.strings")
local time = require("contract.time")

local R = {}
R.schemas = {
  observation = "testing-observation.v1",
  assertion_result = "testing-assertion-result.v1",
  case_result = "testing-case-result.v2",
  case_result_set = "testing-case-result-set.v2",
}
R.canonicalization = "fkst-testing-results-canonical-json.v1"
R.execution_modes = { cli = true, http = true, browser = true }
R.execution_statuses = { passed = true, failed = true, skipped = true, error = true, blocked = true, lost = true }
R.assertion_statuses = { passed = true, failed = true, skipped = true }
R.classifications = { deterministic = true, assertion_failure = true, not_applicable = true, skipped = true, execution_error = true, blocked = true, lost = true }

local assertion_outcomes = {
  passed = { deterministic = true },
  failed = { assertion_failure = true },
  skipped = { skipped = true, not_applicable = true },
}
local case_outcomes = {
  passed = { classifications={deterministic=true}, assertion_statuses={passed=true,skipped=true}, error="forbidden", reason="forbidden", required_assertions="passed" },
  failed = { classifications={assertion_failure=true}, assertion_statuses={passed=true,failed=true,skipped=true}, error="forbidden", reason="forbidden", required_assertions="failed" },
  skipped = { classifications={skipped=true,not_applicable=true}, assertion_statuses={skipped=true}, error="forbidden", reason="required" },
  error = { classifications={execution_error=true}, assertion_statuses={passed=true,skipped=true}, error="required", reason="forbidden" },
  blocked = { classifications={blocked=true}, assertion_statuses={passed=true,skipped=true}, error="forbidden", reason="required" },
  lost = { classifications={lost=true}, assertion_statuses={passed=true,skipped=true}, error="forbidden", reason="required" },
}

local function fail(classification, message) error("contract.testing-results: " .. classification .. ": " .. message) end
local function bounded(value, field, limit)
  if type(value) ~= "string" or value == "" or #value > (limit or 512) or value:find("[%z\1-\31]") ~= nil then fail("malformed-field", field .. " must be a bounded string") end
  return value
end
local function fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, "must be a table") end
  for key in pairs(value) do if allowed[key] ~= true then fail("malformed-" .. context, "unsupported field " .. tostring(key)) end end
end
local function integer(value, field, minimum, maximum)
  if type(value) ~= "number" or value ~= math.floor(value) or value < minimum or value > maximum then fail("malformed-field", field .. " must be an integer from " .. minimum .. " to " .. maximum) end
  return value
end
local function list(value, field, limit, required)
  if type(value) ~= "table" then fail("malformed-list", field .. " must be a list") end
  local highest, count = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then fail("malformed-list", field .. " must be dense") end
    highest, count = math.max(highest, key), count + 1
  end
  if count ~= highest or count > limit or (required and count == 0) then fail("malformed-list", field .. " has an invalid size") end
  return value
end
local function digest(value, field)
  if type(value) ~= "string" or not value:match("^[0-9a-f][0-9a-f]*$") or #value ~= 64 then fail("malformed-digest", field .. " must be lowercase SHA-256") end
  return value
end
local function reference(value, field, required_digest)
  fields(value, { kind = true, ref = true, sha256 = true }, field)
  bounded(value.kind, field .. ".kind", 96); bounded(value.ref, field .. ".ref", 4096)
  if required_digest or value.sha256 ~= nil then digest(value.sha256, field .. ".sha256") end
end
local function evidence(value, field)
  list(value, field, 64, false)
  for index, item in ipairs(value) do reference(item, field .. "[" .. index .. "]", false) end
end
local function timing(value)
  fields(value, { started_at = true, completed_at = true, duration_ms = true }, "timing")
  bounded(value.started_at, "timing.started_at", 40); bounded(value.completed_at, "timing.completed_at", 40)
  local started, completed = time.iso_timestamp_epoch_seconds(value.started_at), time.iso_timestamp_epoch_seconds(value.completed_at)
  if started == nil or completed == nil then fail("malformed-time", "timing timestamps must be UTC ISO timestamps") end
  integer(value.duration_ms, "timing.duration_ms", 0, 86400000)
  if completed < started then fail("contradictory-timing", "completed_at precedes started_at") end
end

local function validate_observation(value)
  fields(value, { schema=true, observation_id=true, kind=true, subject=true, value=true, source_ref=true, evidence_refs=true }, "observation")
  if value.schema ~= R.schemas.observation then fail("unknown-schema", "observation schema") end
  bounded(value.observation_id, "observation_id", 180); bounded(value.kind, "observation.kind", 96); bounded(value.subject, "observation.subject", 180); bounded(value.value, "observation.value")
  reference(value.source_ref, "observation.source_ref"); evidence(value.evidence_refs, "observation.evidence_refs")
  return value
end

local function validate_assertion(value, observation_ids)
  fields(value, { schema=true, assertion_id=true, type=true, required=true, status=true, classification=true, observation_ids=true, evidence_refs=true }, "assertion-result")
  if value.schema ~= R.schemas.assertion_result then fail("unknown-schema", "assertion result schema") end
  bounded(value.assertion_id, "assertion_id", 180); bounded(value.type, "assertion.type", 96)
  if type(value.required) ~= "boolean" then fail("malformed-field", "assertion.required must be boolean") end
  if not R.assertion_statuses[value.status] then fail("malformed-field", "assertion.status is unsupported") end
  if not R.classifications[value.classification] then fail("malformed-field", "assertion.classification is unsupported") end
  if not assertion_outcomes[value.status][value.classification] then fail("contradictory-assertion", "assertion status and classification disagree") end
  list(value.observation_ids, "assertion.observation_ids", 64, false); local seen = {}
  for _, id in ipairs(value.observation_ids) do bounded(id, "assertion.observation_ids item", 180); if seen[id] or (observation_ids and not observation_ids[id]) then fail("foreign-observation", "assertion references an invalid observation") end; seen[id] = true end
  evidence(value.evidence_refs, "assertion.evidence_refs")
  return value
end

local function same_plan(plan_ref, plan_sha256, expected)
  return plan_ref.kind == expected.plan_ref.kind and plan_ref.ref == expected.plan_ref.ref and plan_sha256 == expected.plan_sha256
end
local function validate_assertion_authority(value, reviewed_case_id)
  fields(value, { plan_ref=true, plan_sha256=true, reviewed_case_id=true, assertions=true }, "assertion-authority")
  reference(value.plan_ref, "assertion-authority.plan_ref"); digest(value.plan_sha256, "assertion-authority.plan_sha256")
  bounded(value.reviewed_case_id, "assertion-authority.reviewed_case_id", 180)
  if reviewed_case_id ~= nil and value.reviewed_case_id ~= reviewed_case_id then fail("foreign-plan", "assertion authority belongs to another reviewed case") end
  list(value.assertions, "assertion-authority.assertions", 32, false); local assertions = {}
  for _, item in ipairs(value.assertions) do
    fields(item, { assertion_id=true, required=true }, "assertion-authority-item")
    bounded(item.assertion_id, "assertion-authority.assertion_id", 180)
    if type(item.required) ~= "boolean" then fail("malformed-field", "assertion-authority.required must be boolean") end
    if assertions[item.assertion_id] ~= nil then fail("duplicate-assertion", item.assertion_id) end
    assertions[item.assertion_id] = item.required
  end
  return assertions
end
local function validate_authoritative_assertions(value, authority, assertion_ids)
  if authority == nil then return end
  local planned = validate_assertion_authority(authority, value.reviewed_case_id)
  if not same_plan(value.plan_ref, value.plan_sha256, authority) then fail("foreign-plan", "assertion authority does not match the case plan") end
  for _, assertion in ipairs(value.assertions) do
    local required = planned[assertion.assertion_id]
    if required == nil then fail("foreign-assertion", assertion.assertion_id) end
    if assertion.required ~= required then fail("contradictory-requiredness", assertion.assertion_id) end
  end
  for assertion_id in pairs(planned) do if not assertion_ids[assertion_id] then fail("missing-assertion", assertion_id) end end
end
local function validate_case_outcome(value)
  local outcome = case_outcomes[value.execution_status]
  if not outcome.classifications[value.classification] then fail("contradictory-status", "execution status and classification disagree") end
  if outcome.error == "required" and value.error == nil then fail("contradictory-status", "execution status requires error") end
  if outcome.error == "forbidden" and value.error ~= nil then fail("contradictory-status", "execution status forbids error") end
  if outcome.reason == "required" and value.non_execution_reason == nil then fail("contradictory-status", "execution status requires non-execution reason") end
  if outcome.reason == "forbidden" and value.non_execution_reason ~= nil then fail("contradictory-status", "execution status forbids non-execution reason") end
  local required, required_passed, required_failed = 0, 0, 0
  for _, assertion in ipairs(value.assertions) do
    if not outcome.assertion_statuses[assertion.status] then fail("contradictory-status", "execution status forbids assertion status " .. assertion.status) end
    if assertion.required then
      required = required + 1
      if assertion.status == "passed" then required_passed = required_passed + 1 elseif assertion.status == "failed" then required_failed = required_failed + 1 end
    end
  end
  if outcome.required_assertions == "passed" and (required == 0 or required_passed ~= required) then fail("contradictory-status", "passed requires every required assertion to pass") end
  if outcome.required_assertions == "failed" and required_failed == 0 then fail("contradictory-status", "failed requires a failed required assertion") end
end

local case_fields = { schema=true, case_id=true, repository=true, reviewed_case_id=true, asset_ref=true, requirement_ref=true, plan_ref=true, plan_sha256=true, execution_mode=true, execution_status=true, classification=true, observations=true, assertions=true, evidence_refs=true, timing=true, error=true, non_execution_reason=true, trace_id=true, dedup_key=true }
local function validate_case(value, expected_plan, assertion_authority)
  fields(value, case_fields, "case-result")
  if value.schema ~= R.schemas.case_result then fail("unknown-schema", "case result schema") end
  bounded(value.case_id, "case_id", 180); fields(value.repository, { id=true, source_ref=true, source_sha256=true }, "repository"); bounded(value.repository.id, "repository.id", 180); reference(value.repository.source_ref, "repository.source_ref"); digest(value.repository.source_sha256, "repository.source_sha256")
  bounded(value.reviewed_case_id, "reviewed_case_id", 180); if value.asset_ref ~= nil then reference(value.asset_ref, "asset_ref") end; if value.requirement_ref ~= nil then reference(value.requirement_ref, "requirement_ref") end
  reference(value.plan_ref, "plan_ref"); digest(value.plan_sha256, "plan_sha256")
  if expected_plan and not same_plan(value.plan_ref, value.plan_sha256, expected_plan) then fail("foreign-plan", "case does not belong to the result set plan") end
  if not R.execution_modes[value.execution_mode] then fail("malformed-field", "execution_mode is unsupported") end; if not R.execution_statuses[value.execution_status] then fail("malformed-field", "execution_status is unsupported") end; if not R.classifications[value.classification] then fail("malformed-field", "classification is unsupported") end
  list(value.observations, "observations", 64, false); local observation_ids = {}; for _, item in ipairs(value.observations) do validate_observation(item); if observation_ids[item.observation_id] then fail("duplicate-observation", item.observation_id) end; observation_ids[item.observation_id] = true end
  list(value.assertions, "assertions", 32, false); local assertion_ids = {}; for _, item in ipairs(value.assertions) do validate_assertion(item, observation_ids); if assertion_ids[item.assertion_id] then fail("duplicate-assertion", item.assertion_id) end; assertion_ids[item.assertion_id] = true end
  validate_authoritative_assertions(value, assertion_authority, assertion_ids)
  evidence(value.evidence_refs, "evidence_refs"); timing(value.timing)
  if value.error ~= nil then fields(value.error, { code=true, message=true }, "error"); bounded(value.error.code, "error.code", 96); bounded(value.error.message, "error.message") end
  if value.non_execution_reason ~= nil then bounded(value.non_execution_reason, "non_execution_reason", 96) end
  bounded(value.trace_id, "trace_id", 180); bounded(value.dedup_key, "dedup_key", 180)
  validate_case_outcome(value)
  return value
end

function R.validate_observation(value) return validate_observation(value) end
function R.validate_assertion_result(value) return validate_assertion(value) end
function R.validate_case_result(value, assertion_authority) return validate_case(value, nil, assertion_authority) end
function R.validate_case_result_set(value, assertion_authorities)
  fields(value, { schema=true, set_id=true, plan_ref=true, plan_sha256=true, cases=true, trace_id=true, dedup_key=true }, "case-result-set")
  if value.schema ~= R.schemas.case_result_set then fail("unknown-schema", "case result set schema") end
  bounded(value.set_id, "set_id", 180); reference(value.plan_ref, "plan_ref"); digest(value.plan_sha256, "plan_sha256"); list(value.cases, "cases", 64, true); local seen = {}; local plan = { plan_ref=value.plan_ref, plan_sha256=value.plan_sha256 }
  local authorities = {}
  if assertion_authorities ~= nil then
    list(assertion_authorities, "assertion-authorities", 64, true)
    for _, authority in ipairs(assertion_authorities) do
      validate_assertion_authority(authority)
      if not same_plan(value.plan_ref, value.plan_sha256, authority) then fail("foreign-plan", "assertion authority does not match the result set plan") end
      if authorities[authority.reviewed_case_id] ~= nil then fail("duplicate-case", authority.reviewed_case_id) end
      authorities[authority.reviewed_case_id] = authority
    end
  end
  for _, item in ipairs(value.cases) do
    validate_case(item, plan, assertion_authorities and authorities[item.reviewed_case_id])
    if seen[item.case_id] then fail("duplicate-case", item.case_id) end
    seen[item.case_id] = true
    if assertion_authorities and authorities[item.reviewed_case_id] == nil then fail("missing-assertion-authority", item.reviewed_case_id) end
  end
  if assertion_authorities then
    for reviewed_case_id in pairs(authorities) do
      local found = false
      for _, item in ipairs(value.cases) do if item.reviewed_case_id == reviewed_case_id then found = true end end
      if not found then fail("foreign-assertion-authority", reviewed_case_id) end
    end
  end
  bounded(value.trace_id, "trace_id", 180); bounded(value.dedup_key, "dedup_key", 180); return value
end
function R.negotiate(schema, supported)
  bounded(schema, "schema", 96); local major = tonumber(schema:match("%.v(%d+)$")); if major == nil or type(supported) ~= "table" or supported[major] ~= true then fail("unsupported-major", schema) end; return major
end

local function canonical_json(value)
  local kind = type(value); if kind == "boolean" then return value and "true" or "false" end; if kind == "number" then if value ~= math.floor(value) then fail("canonicalization", "only integers are supported") end; return tostring(value) end; if kind == "string" then return strings.json_string(value) end; if kind ~= "table" then fail("canonicalization", "unsupported value type " .. kind) end
  local numeric, keys = 0, {}; for key in pairs(value) do if type(key) == "number" then numeric = numeric + 1 else table.insert(keys, key) end end
  if numeric > 0 or next(value) == nil then local parts = {}; for _, item in ipairs(value) do table.insert(parts, canonical_json(item)) end; return "[" .. table.concat(parts, ",") .. "]" end
  table.sort(keys); local parts = {}; for _, key in ipairs(keys) do table.insert(parts, strings.json_string(key) .. ":" .. canonical_json(value[key])) end; return "{" .. table.concat(parts, ",") .. "}"
end
function R.canonicalize(value)
  if value.schema == R.schemas.observation then validate_observation(value) elseif value.schema == R.schemas.assertion_result then validate_assertion(value) elseif value.schema == R.schemas.case_result then validate_case(value) elseif value.schema == R.schemas.case_result_set then R.validate_case_result_set(value) else fail("unknown-schema", "unsupported result schema") end
  return canonical_json(value)
end
function R.sha256(value, sha256_fn)
  if type(sha256_fn) ~= "function" then fail("missing-sha256", "a host-supplied SHA-256 function is required") end
  local ok, result = pcall(sha256_fn, R.canonicalize(value)); if not ok then fail("sha256-failed", "the host SHA-256 function failed") end; return digest(result, "sha256 result")
end
return R
