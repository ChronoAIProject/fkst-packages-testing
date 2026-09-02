local canonical_json = require("contract.canonical_json")
local error_facts = require("contract.error_facts")
local evidence = require("contract.testing_evidence_manifest")
local results = require("contract.testing_results")

local M = {}

M.schemas = {
  reducer = "testing-assertion-reducer-identity.v1",
  receipt = "testing-result-authority-receipt.v1",
}
M.canonicalization = "fkst-testing-result-authority-canonical-json.v1"
M.reducer_id = "testing.assertion-reducer.browser-title-equals"
M.reducer_version = "1.0.0"
M.policy_profile = "browser-title-equals.v1"
M.result_contract_major = "testing-case-result-set.v2"

local function fail(classification, message)
  error(error_facts.error_message("contract.testing-result-authority", classification, message))
end

local function fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, context .. " must be a table") end
  for key in pairs(value) do
    if allowed[key] ~= true then fail("malformed-" .. context, "unsupported field " .. tostring(key)) end
  end
end

local function bounded(value, field, limit)
  if type(value) ~= "string" or value == "" or #value > limit or not canonical_json.is_valid_utf8(value)
      or value:find("[%z\1-\31]") ~= nil then
    fail("malformed-field", field .. " must be bounded UTF-8")
  end
  return value
end

local function digest(value, field)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    fail("malformed-digest", field .. " must be lowercase SHA-256")
  end
  return value
end

local function reference(value, field)
  fields(value, { kind=true, ref=true, sha256=true }, field)
  bounded(value.kind, field .. ".kind", 96)
  bounded(value.ref, field .. ".ref", 4096)
  digest(value.sha256, field .. ".sha256")
  return value
end

local function sha256(sha256_fn, bytes, field)
  if type(sha256_fn) ~= "function" then fail("missing-sha256", "SHA-256 function is required") end
  return digest(sha256_fn(bytes), field)
end

local function equal(left, right, seen)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  seen = seen or {}
  if seen[left] == right then return true end
  seen[left] = right
  for key, value in pairs(left) do if not equal(value, right[key], seen) then return false end end
  for key in pairs(right) do if left[key] == nil then return false end end
  return true
end

local function exact_bytes(actual, expected, field)
  if type(actual) ~= "string" or actual ~= expected then
    fail("artifact-content-mismatch", field .. " bytes do not match canonical content")
  end
  return actual
end

local function artifact_digest(reference_value, bytes, field, sha256_fn)
  reference(reference_value, field)
  local computed = sha256(sha256_fn, bytes, field .. ".computed_sha256")
  if reference_value.sha256 ~= computed then fail("artifact-digest-mismatch", field .. " digest mismatch") end
  return computed
end

local function reducer_descriptor()
  return {
    schema = M.schemas.reducer,
    reducer_id = M.reducer_id,
    reducer_version = M.reducer_version,
    policy_profile = M.policy_profile,
    supported_result_contract_majors = { M.result_contract_major },
  }
end

function M.identity(sha256_fn)
  local value = reducer_descriptor()
  value.reducer_sha256 = sha256(sha256_fn, canonical_json.encode(value), "reducer_sha256")
  return value
end

function M.validate_identity(value, sha256_fn)
  fields(value, { schema=true,reducer_id=true,reducer_version=true,reducer_sha256=true,
    policy_profile=true,supported_result_contract_majors=true }, "reducer-identity")
  if value.schema ~= M.schemas.reducer or value.reducer_id ~= M.reducer_id
      or value.reducer_version ~= M.reducer_version or value.policy_profile ~= M.policy_profile then
    fail("unknown-reducer", "reducer identity is not supported")
  end
  if type(value.supported_result_contract_majors) ~= "table"
      or #value.supported_result_contract_majors ~= 1
      or value.supported_result_contract_majors[1] ~= M.result_contract_major then
    fail("unsupported-result-major", "reducer result contract major is unsupported")
  end
  if not equal(value, M.identity(sha256_fn)) then fail("reducer-digest-mismatch", "reducer identity digest mismatch") end
  return value
end

function M.reduce(input)
  fields(input, { outcome=true, expected=true, observed_title=true, failure_kind=true }, "reducer-input")
  bounded(input.outcome, "outcome", 64)
  if input.outcome == "observed" then
    bounded(input.expected, "expected", 512)
    bounded(input.observed_title, "observed_title", 512)
    local passed = input.expected == input.observed_title
    return { receipt_classification=passed and "passed" or "assertion_failure",
      execution_status=passed and "passed" or "failed", classification=passed and "deterministic" or "assertion_failure",
      assertion_status=passed and "passed" or "failed", assertion_classification=passed and "deterministic" or "assertion_failure" }
  end
  local outcomes = {
    cancelled = { "cancelled", "blocked", "blocked", "skipped", "skipped" },
    infrastructure_failure = { "infrastructure_failure", "error", "execution_error", "skipped", "skipped" },
    lost = { "lost_or_inconclusive", "lost", "lost", "skipped", "skipped" },
  }
  local outcome = outcomes[input.outcome]
  if outcome == nil then fail("unsupported-outcome", "reducer outcome is unsupported") end
  return { receipt_classification=outcome[1], execution_status=outcome[2], classification=outcome[3],
    assertion_status=outcome[4], assertion_classification=outcome[5] }
end

function M.validate_reduction(input, result_set, evidence_manifest, sha256_fn, validation_context)
  local reduction = M.reduce(input)
  results.validate_case_result_set(result_set, nil, evidence_manifest, sha256_fn, validation_context)
  if #result_set.cases ~= 1 or #result_set.cases[1].assertions ~= 1 then
    fail("semantic-output-mismatch", "reducer requires one case and one assertion")
  end
  local case = result_set.cases[1]
  local assertion = case.assertions[1]
  if case.execution_status ~= reduction.execution_status or case.classification ~= reduction.classification
      or assertion.status ~= reduction.assertion_status or assertion.classification ~= reduction.assertion_classification then
    fail("semantic-output-mismatch", "CaseResultSet disagrees with independently recomputed reducer output")
  end
  if input.outcome == "observed" then
    if #case.observations ~= 1 or case.observations[1].value ~= input.observed_title then
      fail("semantic-output-mismatch", "CaseResultSet observation disagrees with reducer input")
    end
  end
  return reduction
end

local receipt_fields = { schema=true,canonicalization=true,receipt_id=true,run_id=true,invocation_id=true,
  admitted_release_ref=true,admission_digest=true,package_id=true,package_version=true,package_content_sha256=true,
  manifest_digest=true,executor_id=true,structured_plan_ref=true,reducer=true,case_result_set_ref=true,
  case_result_set_content_sha256=true,evidence_manifest_ref=true,evidence_manifest_content_sha256=true,
  completed_execution_sha256=true,classification=true,receipt_sha256=true }

local classifications = { passed=true,assertion_failure=true,cancelled=true,infrastructure_failure=true,lost_or_inconclusive=true }

local function validate_receipt_shape(value, sha256_fn)
  fields(value, receipt_fields, "receipt")
  if value.schema ~= M.schemas.receipt or value.canonicalization ~= M.canonicalization then
    fail("unknown-schema", "result authority receipt schema or canonicalization is unsupported")
  end
  for _, field in ipairs({ "receipt_id", "run_id", "invocation_id", "package_id", "package_version", "executor_id" }) do
    bounded(value[field], field, 180)
  end
  reference(value.admitted_release_ref, "admitted_release_ref")
  reference(value.structured_plan_ref, "structured_plan_ref")
  reference(value.case_result_set_ref, "case_result_set_ref")
  reference(value.evidence_manifest_ref, "evidence_manifest_ref")
  for _, field in ipairs({ "admission_digest", "package_content_sha256", "manifest_digest", "case_result_set_content_sha256",
    "evidence_manifest_content_sha256", "completed_execution_sha256", "receipt_sha256" }) do digest(value[field], field) end
  M.validate_identity(value.reducer, sha256_fn)
  if not classifications[value.classification] then fail("unsupported-classification", "receipt classification is unsupported") end
  local copy = {}
  for key, item in pairs(value) do copy[key] = item end
  copy.receipt_sha256 = string.rep("0", 64)
  if value.receipt_sha256 ~= sha256(sha256_fn, canonical_json.encode(copy), "computed receipt_sha256") then
    fail("receipt-digest-mismatch", "receipt canonical digest mismatch")
  end
  return value
end

function M.create_receipt(bindings, sha256_fn)
  local manifest_context = #bindings.evidence_manifest.entries == 0 and { allow_empty_entries=true } or nil
  local reduction = M.validate_reduction(bindings.reducer_input, bindings.case_result_set,
    bindings.evidence_manifest, sha256_fn, manifest_context)
  evidence.validate(bindings.evidence_manifest, bindings.case_result_set, sha256_fn, manifest_context)
  local evidence_bytes = exact_bytes(bindings.evidence_manifest_bytes,
    evidence.serialize(bindings.evidence_manifest, manifest_context), "evidence_manifest")
  local result_bytes = exact_bytes(bindings.case_result_set_bytes,
    results.canonicalize(bindings.case_result_set, bindings.evidence_manifest, sha256_fn, manifest_context), "case_result_set")
  local result_sha256 = artifact_digest(bindings.case_result_set_ref, result_bytes, "case_result_set_ref", sha256_fn)
  artifact_digest(bindings.evidence_manifest_ref, evidence_bytes, "evidence_manifest_ref", sha256_fn)
  local completed = bindings.completed_execution
  if type(completed) ~= "table" or not equal(completed.case_result_set_ref, bindings.case_result_set_ref)
      or completed.case_result_set_sha256 ~= result_sha256
      or not equal(completed.evidence_manifest_ref, bindings.evidence_manifest_ref)
      or completed.evidence_manifest_sha256 ~= bindings.evidence_manifest.canonical_sha256 then
    fail("completion-mismatch", "completed execution does not bind the exact result and evidence artifacts")
  end
  local completed_execution_sha256 = sha256(sha256_fn, canonical_json.encode(bindings.completed_execution),
    "completed_execution_sha256")
  local value = {
    schema=M.schemas.receipt, canonicalization=M.canonicalization, receipt_id=bindings.receipt_id,
    run_id=bindings.run_id, invocation_id=bindings.invocation_id, admitted_release_ref=bindings.admitted_release_ref,
    admission_digest=bindings.admission_digest, package_id=bindings.package_id, package_version=bindings.package_version,
    package_content_sha256=bindings.package_content_sha256, manifest_digest=bindings.manifest_digest,
    executor_id=bindings.executor_id, structured_plan_ref=bindings.structured_plan_ref, reducer=M.identity(sha256_fn),
    case_result_set_ref=bindings.case_result_set_ref, case_result_set_content_sha256=result_sha256,
    evidence_manifest_ref=bindings.evidence_manifest_ref,
    evidence_manifest_content_sha256=bindings.evidence_manifest.canonical_sha256,
    completed_execution_sha256=completed_execution_sha256, classification=reduction.receipt_classification,
    receipt_sha256=string.rep("0", 64),
  }
  value.receipt_sha256 = sha256(sha256_fn, canonical_json.encode(value), "receipt_sha256")
  return validate_receipt_shape(value, sha256_fn)
end

function M.validate_receipt(value, bindings, sha256_fn)
  validate_receipt_shape(value, sha256_fn)
  local expected = M.create_receipt(bindings, sha256_fn)
  if not equal(value, expected) then fail("binding-mismatch", "result authority receipt bindings do not match") end
  return value
end

function M.canonicalize(value, sha256_fn)
  validate_receipt_shape(value, sha256_fn)
  return canonical_json.encode(value) .. "\n"
end

return M
