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
  list(value.observation_ids, "assertion.observation_ids", 64, false); local seen = {}
  for _, id in ipairs(value.observation_ids) do bounded(id, "assertion.observation_ids item", 180); if seen[id] or (observation_ids and not observation_ids[id]) then fail("foreign-observation", "assertion references an invalid observation") end; seen[id] = true end
  evidence(value.evidence_refs, "assertion.evidence_refs")
  return value
end

local case_fields = { schema=true, case_id=true, repository=true, reviewed_case_id=true, asset_ref=true, requirement_ref=true, plan_ref=true, plan_sha256=true, execution_mode=true, execution_status=true, classification=true, observations=true, assertions=true, evidence_refs=true, timing=true, error=true, non_execution_reason=true, trace_id=true, dedup_key=true }
local function validate_case(value, expected_plan)
  fields(value, case_fields, "case-result")
  if value.schema ~= R.schemas.case_result then fail("unknown-schema", "case result schema") end
  bounded(value.case_id, "case_id", 180); fields(value.repository, { id=true, source_ref=true, source_sha256=true }, "repository"); bounded(value.repository.id, "repository.id", 180); reference(value.repository.source_ref, "repository.source_ref"); digest(value.repository.source_sha256, "repository.source_sha256")
  bounded(value.reviewed_case_id, "reviewed_case_id", 180); if value.asset_ref ~= nil then reference(value.asset_ref, "asset_ref") end; if value.requirement_ref ~= nil then reference(value.requirement_ref, "requirement_ref") end
  reference(value.plan_ref, "plan_ref"); digest(value.plan_sha256, "plan_sha256")
  if expected_plan and (value.plan_ref.ref ~= expected_plan.ref or value.plan_sha256 ~= expected_plan.sha256) then fail("foreign-plan", "case does not belong to the result set plan") end
  if not R.execution_modes[value.execution_mode] then fail("malformed-field", "execution_mode is unsupported") end; if not R.execution_statuses[value.execution_status] then fail("malformed-field", "execution_status is unsupported") end; if not R.classifications[value.classification] then fail("malformed-field", "classification is unsupported") end
  list(value.observations, "observations", 64, false); local observation_ids = {}; for _, item in ipairs(value.observations) do validate_observation(item); if observation_ids[item.observation_id] then fail("duplicate-observation", item.observation_id) end; observation_ids[item.observation_id] = true end
  list(value.assertions, "assertions", 32, false); local assertion_ids = {}; for _, item in ipairs(value.assertions) do validate_assertion(item, observation_ids); if assertion_ids[item.assertion_id] then fail("duplicate-assertion", item.assertion_id) end; assertion_ids[item.assertion_id] = true end
  evidence(value.evidence_refs, "evidence_refs"); timing(value.timing)
  if value.error ~= nil then fields(value.error, { code=true, message=true }, "error"); bounded(value.error.code, "error.code", 96); bounded(value.error.message, "error.message") end
  if value.non_execution_reason ~= nil then bounded(value.non_execution_reason, "non_execution_reason", 96) end
  bounded(value.trace_id, "trace_id", 180); bounded(value.dedup_key, "dedup_key", 180)
  local required, passed, failed, any_failed = 0, 0, 0, 0; for _, assertion in ipairs(value.assertions) do if assertion.status == "failed" then any_failed = any_failed + 1 end; if assertion.required then required = required + 1; if assertion.status == "passed" then passed = passed + 1 elseif assertion.status == "failed" then failed = failed + 1 end end end
  if value.execution_status == "passed" and (required == 0 or passed ~= required or value.classification ~= "deterministic") then fail("contradictory-status", "passed requires every required assertion to pass") end
  if value.execution_status == "failed" and failed == 0 then fail("contradictory-status", "failed requires a failed required assertion") end
  if (value.execution_status == "lost" or value.execution_status == "blocked" or value.execution_status == "error") then
    if value.non_execution_reason == nil and value.error == nil then fail("contradictory-status", "uncertain execution requires an error or non-execution reason") end
    if any_failed > 0 then fail("contradictory-status", "uncertain execution cannot contain failed assertions") end
  end
  return value
end

function R.validate_observation(value) return validate_observation(value) end
function R.validate_assertion_result(value) return validate_assertion(value) end
function R.validate_case_result(value) return validate_case(value) end
function R.validate_case_result_set(value)
  fields(value, { schema=true, set_id=true, plan_ref=true, plan_sha256=true, cases=true, trace_id=true, dedup_key=true }, "case-result-set")
  if value.schema ~= R.schemas.case_result_set then fail("unknown-schema", "case result set schema") end
  bounded(value.set_id, "set_id", 180); reference(value.plan_ref, "plan_ref"); digest(value.plan_sha256, "plan_sha256"); list(value.cases, "cases", 64, true); local seen = {}; local plan = { ref=value.plan_ref.ref, sha256=value.plan_sha256 }
  for _, item in ipairs(value.cases) do validate_case(item, plan); if seen[item.case_id] then fail("duplicate-case", item.case_id) end; seen[item.case_id] = true end
  bounded(value.trace_id, "trace_id", 180); bounded(value.dedup_key, "dedup_key", 180); return value
end
function R.negotiate(schema, supported)
  bounded(schema, "schema", 96); local major = tonumber(schema:match("%.v(%d+)$")); if major == nil or type(supported) ~= "table" or supported[major] ~= true then fail("unsupported-major", schema) end; return major
end

local function canonical_json(value)
  local kind = type(value); if kind == "boolean" then return value and "true" or "false" end; if kind == "number" then if value ~= math.floor(value) then fail("canonicalization", "only integers are supported") end; return tostring(value) end; if kind == "string" then return strings.json_string(value) end; if kind ~= "table" then fail("canonicalization", "unsupported value type " .. kind) end
  local numeric, keys = 0, {}; for key in pairs(value) do if type(key) == "number" then numeric = numeric + 1 else table.insert(keys, key) end end
  if numeric > 0 then local parts = {}; for _, item in ipairs(value) do table.insert(parts, canonical_json(item)) end; return "[" .. table.concat(parts, ",") .. "]" end
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
