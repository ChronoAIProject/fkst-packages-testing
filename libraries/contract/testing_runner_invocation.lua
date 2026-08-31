local canonical_json = require("contract.canonical_json")
local error_facts = require("contract.error_facts")
local executor = require("contract.testing_package_executor")
local M = { schema = "testing-runner-invocation.v1", canonicalization = "fkst-testing-runner-invocation-canonical-json.v1" }
local function fail(classification, message) error(error_facts.error_message("contract.testing-runner-invocation", classification, message)) end
local function fields(value, allowed, name)
  if type(value) ~= "table" then fail("malformed-" .. name, "must be an object") end
  for key in pairs(value) do if not allowed[key] then fail("malformed-" .. name, "unsupported field " .. tostring(key)) end end
end
local function required(value, key) if value[key] == nil then fail("missing-field", key .. " is required") end return value[key] end
local function identity(value, field)
  if type(value) ~= "string" or #value < 1 or #value > 180 or not canonical_json.is_valid_utf8(value) or value:find("[%z\1-\31\127]") then fail("malformed-field", field .. " must be a bounded identity string") end
end
local function digest(value, field)
  identity(value, field); if #value ~= 64 or not value:match("^[0-9a-f]+$") then fail("malformed-digest", field .. " must be lowercase SHA-256") end
end
local function semver(value, field)
  identity(value, field); if not value:match("^[0-9]+%.[0-9]+%.[0-9]+$") then fail("malformed-field", field .. " must be semantic version") end
end
local function integer(value, field, minimum, maximum)
  if type(value) ~= "number" or value ~= math.floor(value) or value < minimum or value > maximum then fail("malformed-field", field .. " must be an integer in range") end
end
local function validate_ref(value, field, kind) executor.validate_reference(value, field, kind) end
local reference_kinds = { source_ref="testing-package-source", pql_input_set_ref="testing-package-pql-input", approved_test_case_set_ref="testing-approved-test-case-set", structured_plan_ref="testing-structured-plan", package_release_ref="testing-package-release", package_manifest_ref="testing-package-manifest", schema_catalog_ref="testing-schema-catalog", capability_port_set_ref="testing-package-capability-set", policy_ref="testing-package-policy" }
local function validate_refs(value)
  fields(value, reference_kinds, "approved-input-refs")
  for field, kind in pairs(reference_kinds) do validate_ref(required(value, field), "approved_input_refs." .. field, kind) end
end
local function validate_executor(value)
  executor.validate_identity(value)
  if value.contract_major ~= "testing-runner.v1" then fail("unsupported-contract", "executor.contract_major") end
end
local function validate_resolved(value)
  fields(value, { executor_id=true, version=true, capability_digest=true }, "resolved-executor")
  identity(required(value, "executor_id"), "resolved_executor.executor_id"); semver(required(value, "version"), "resolved_executor.version"); digest(required(value, "capability_digest"), "resolved_executor.capability_digest")
end
local function validate_budgets(value)
  fields(value, { step_budget=true, time_budget_seconds=true }, "budgets")
  integer(required(value, "step_budget"), "budgets.step_budget", 1, 8); integer(required(value, "time_budget_seconds"), "budgets.time_budget_seconds", 1, 600)
end
local function validate_producer(value)
  fields(value, { name=true, version=true }, "producer"); identity(required(value, "name"), "producer.name"); semver(required(value, "version"), "producer.version")
end
local function canonical_copy(value, omit_digest)
  if type(value) ~= "table" then return value end
  local numeric = true; local count = 0; local highest = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then numeric = false; break end
    count = count + 1; highest = math.max(highest, key)
  end
  if numeric and count == highest then
    local copy = {}; for index = 1, highest do copy[index] = canonical_copy(value[index], false) end; return canonical_json.array(copy)
  end
  local copy = {}
  for key, item in pairs(value) do if not (omit_digest and key == "canonical_request_sha256") then copy[key] = canonical_copy(item, false) end end
  return canonical_json.object(copy)
end
local function without_digest(value) return canonical_copy(value, true) end
function M.validate(value, sha256_fn)
  fields(value, { schema=true, canonicalization=true, invocation_id=true, qa_run_ref=true, attempt_ref=true, executor=true, resolved_executor=true, execution_profile=true, approved_input_refs=true, requested_capabilities=true, budgets=true, deadline_epoch_seconds=true, producer=true, trace_id=true, dedup_key=true, canonical_request_sha256=true }, "invocation")
  if required(value, "schema") ~= M.schema then fail("unknown-schema", "schema") end; if required(value, "canonicalization") ~= M.canonicalization then fail("unsupported-canonicalization", "canonicalization") end
  identity(required(value, "invocation_id"), "invocation_id"); identity(required(value, "qa_run_ref"), "qa_run_ref"); identity(required(value, "attempt_ref"), "attempt_ref"); validate_executor(required(value, "executor")); validate_resolved(required(value, "resolved_executor")); identity(required(value, "execution_profile"), "execution_profile"); validate_refs(required(value, "approved_input_refs"))
  local capabilities = required(value, "requested_capabilities"); if type(capabilities) ~= "table" then fail("malformed-field", "requested_capabilities must be an array") end; if #capabilities < 1 or #capabilities > 64 then fail("malformed-field", "requested_capabilities has an invalid item count") end
  local seen = {}; for index, item in ipairs(capabilities) do identity(item, "requested_capabilities[" .. index .. "]"); if seen[item] then fail("duplicate-item", "requested_capabilities must be unique") end; seen[item] = true end
  validate_budgets(required(value, "budgets")); integer(required(value, "deadline_epoch_seconds"), "deadline_epoch_seconds", 1, canonical_json.max_integer); validate_producer(required(value, "producer")); identity(required(value, "trace_id"), "trace_id"); identity(required(value, "dedup_key"), "dedup_key"); digest(required(value, "canonical_request_sha256"), "canonical_request_sha256")
  if type(sha256_fn) ~= "function" then fail("missing-sha256", "SHA-256 function must be callable") end
  local ok, bytes = pcall(canonical_json.encode, without_digest(value)); if not ok then fail("canonicalization-failed", bytes) end
  local hashed, computed = pcall(sha256_fn, bytes); if not hashed then fail("sha256-failed", "SHA-256 function failed") end
  if computed ~= value.canonical_request_sha256 then fail("digest-mismatch", "canonical request digest does not match") end
  return value
end
return M
