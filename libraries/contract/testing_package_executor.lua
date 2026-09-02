-- contract.testing_package_executor: closed contracts for the provider-neutral walking skeleton.
local canonical_json = require("contract.canonical_json")
local error_facts = require("contract.error_facts")
local strings = require("contract.strings")
local time = require("contract.time")
local M = {}

M.schemas = {
  request = "testing-package-executor.request.v1",
  identity = "testing-package-executor.identity.v1",
  resolved_invocation = "testing-package-executor.resolved-invocation.v1",
  admission_request = "testing-package-executor.admission-request.v1",
  admission_receipt = "testing-package-executor.admission-receipt.v1",
  admission_conflict = "testing-package-executor.admission-conflict.v1",
  resolver_failure = "testing-package-executor.resolver-failure.v1",
  source = "testing-package-source.v1",
  plan = "testing-package-plan.v1",
  pql_input = "testing-package-pql-input.v1",
  policy = "testing-package-policy.v1",
  capability_set = "testing-package-capability-set.v1",
  freshness_check = "testing-package-executor.freshness-check.v1",
  completed_execution_query = "testing-package-executor.completed-execution-query.v1",
  execution_claim_request = "testing-package-executor.execution-claim-request.v1",
  execution_claim_receipt = "testing-package-executor.execution-claim-receipt.v1",
  effect_state_query = "testing-package-executor.effect-state-query.v1",
  effect_intent = "testing-package-executor.effect-intent.v1",
  completed_execution = "testing-package-executor.completed-execution.v1",
  browser_read_title = "testing-package-executor.browser-read-title.v1",
  browser_read_title_receipt = "testing-package-executor.browser-read-title-receipt.v1",
  effect_receipt = "testing-package-executor.effect-receipt.v1",
  canonical_write = "testing-package-executor.canonical-write.v1",
  write_receipt = "testing-package-executor.write-receipt.v1",
  execution = "testing-package-executor.execution.v1",
}

M.profile = "browser-deterministic.v1"
M.package_id = "testing-runner"
M.entrypoint = "testing-runner.run"
M.contract_major = "testing-runner.v1"
M.capability = "browser.read-title.v1"
M.executor_id = "testing-package-executor.browser-title.v1"
M.target_url = "http://127.0.0.1:4173/"
M.case_id = "case-home-title"
M.assertion_id = "assert-home-title"
M.effect_id = "effect-case-home-title-title"
M.observation_id = "observation-home-title"
M.evidence_id = "evidence-case-home-title-title"

M.reference_order = {
  "package_manifest_ref",
  "source_ref",
  "plan_ref",
  "pql_input_ref",
  "policy_ref",
  "capability_set_ref",
}

M.reference_kinds = {
  package_manifest_ref = "testing-package-manifest",
  source_ref = "testing-package-source",
  plan_ref = "testing-package-plan",
  pql_input_ref = "testing-package-pql-input",
  policy_ref = "testing-package-policy",
  capability_set_ref = "testing-package-capability-set",
}

M.semantic_mappings = { {
  execution_profile = M.profile,
  package_id = M.package_id,
  package_version = "1.0.0",
  contract_major = M.contract_major,
  capabilities = { M.capability },
  executor_id = M.executor_id,
  entrypoint = M.entrypoint,
} }

M.resolver_failure_codes = {
  ["admission-conflict"] = true,
  ["capability-mismatch"] = true,
  ["caught-failure"] = true,
  ["current-claim-superseded"] = true,
  ["current-claim-unavailable"] = true,
  ["decode-failed"] = true,
  ["digest-mismatch"] = true,
  ["entrypoint-mismatch"] = true,
  ["identity-mismatch"] = true,
  ["immutable-load-failed"] = true,
  ["mapping-ambiguous"] = true,
  ["mapping-missing"] = true,
  ["package-content-mismatch"] = true,
  ["runtime-incompatible"] = true,
  ["missing-port"] = true,
  ["missing-ports"] = true,
  ["policy-mismatch"] = true,
  ["port-failed"] = true,
  ["sha256-failed"] = true,
  ["unsupported-mapping"] = true,
}

local function fail(classification, message)
  error(error_facts.error_message("contract.testing-package-executor", classification, message))
end

local function fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, "must be a table") end
  for key in pairs(value) do
    if allowed[key] ~= true then fail("malformed-" .. context, "unsupported field " .. tostring(key)) end
  end
end

local function required(value, field)
  if value == nil then fail("missing-field", field .. " is required") end
  return value
end

local function bounded(value, field, limit)
  if type(value) ~= "string" or value == "" or #value > (limit or 4096)
    or not canonical_json.is_valid_utf8(value) or value:find("[%z\1-\31\127]") ~= nil then
    fail("malformed-field", field .. " must be a bounded string without ASCII control characters")
  end
  return value
end

local function identity_string(value, field)
  return bounded(value, field, 180)
end

local function digest(value, field)
  bounded(value, field, 64)
  if #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    fail("malformed-digest", field .. " must be lowercase SHA-256")
  end
  return value
end

local function integer(value, field, minimum, maximum)
  if type(value) ~= "number" or value ~= math.floor(value) or value < minimum or value > maximum then
    fail("malformed-field", field .. " must be an integer from " .. minimum .. " to " .. maximum)
  end
  return value
end

local function semver(value, field)
  identity_string(value, field)
  if value:match("^[0-9]+%.[0-9]+%.[0-9]+$") == nil then
    fail("malformed-version", field .. " must be numeric X.Y.Z semantic version")
  end
  return value
end

local function dense_list(value, field, limit, nonempty)
  if type(value) ~= "table" then fail("malformed-list", field .. " must be a list") end
  local count, highest = 0, 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then fail("malformed-list", field .. " must be dense") end
    count = count + 1
    highest = math.max(highest, key)
  end
  if count ~= highest or count > limit or (nonempty and count == 0) then
    fail("malformed-list", field .. " has an invalid size")
  end
  return value
end

local function exact_string_list(value, field, expected)
  dense_list(value, field, #expected, #expected > 0)
  if #value ~= #expected then fail("mapping-mismatch", field .. " does not match the execution profile") end
  local seen = {}
  for index, item in ipairs(value) do
    identity_string(item, field .. "[" .. index .. "]")
    if seen[item] then fail("duplicate-item", field .. " contains " .. item .. " more than once") end
    seen[item] = true
    if item ~= expected[index] then fail("mapping-mismatch", field .. " does not match the execution profile") end
  end
  return value
end

local function validate_identity(value)
  fields(value, {
    schema = true,
    package_id = true,
    package_version = true,
    package_content_sha256 = true,
    manifest_digest = true,
    entrypoint = true,
    contract_major = true,
  }, "identity")
  if value.schema ~= M.schemas.identity then fail("unknown-schema", "executor identity schema") end
  identity_string(required(value.package_id, "executor.package_id"), "executor.package_id")
  semver(required(value.package_version, "executor.package_version"), "executor.package_version")
  digest(required(value.package_content_sha256, "executor.package_content_sha256"), "executor.package_content_sha256")
  digest(required(value.manifest_digest, "executor.manifest_digest"), "executor.manifest_digest")
  identity_string(required(value.entrypoint, "executor.entrypoint"), "executor.entrypoint")
  identity_string(required(value.contract_major, "executor.contract_major"), "executor.contract_major")
  return value
end

local function validate_reference(value, field, expected_kind)
  fields(value, { kind = true, ref = true, sha256 = true }, field)
  local kind = identity_string(required(value.kind, field .. ".kind"), field .. ".kind")
  if kind ~= expected_kind then fail("reference-kind-mismatch", field .. ".kind must be " .. expected_kind) end
  local ref = bounded(required(value.ref, field .. ".ref"), field .. ".ref")
  if ref:sub(1, 12) ~= "immutable://" then fail("mutable-reference", field .. ".ref must be immutable") end
  if ref:find("[?#]") ~= nil then fail("unsafe-reference", field .. ".ref must not contain query or fragment data") end
  digest(required(value.sha256, field .. ".sha256"), field .. ".sha256")
  return value
end

local function validate_refs(value)
  fields(value, {
    package_manifest_ref = true,
    source_ref = true,
    plan_ref = true,
    pql_input_ref = true,
    policy_ref = true,
    capability_set_ref = true,
  }, "approved-input-refs")
  for _, field in ipairs(M.reference_order) do
    validate_reference(required(value[field], "approved_input_refs." .. field), "approved_input_refs." .. field, M.reference_kinds[field])
  end
  return value
end

local function validate_request(value)
  fields(value, {
    schema = true,
    executor = true,
    execution_profile = true,
    approved_input_refs = true,
    trace_id = true,
    dedup_key = true,
  }, "request")
  if value.schema ~= M.schemas.request then fail("unknown-schema", "request schema") end
  validate_identity(required(value.executor, "executor"))
  identity_string(required(value.execution_profile, "execution_profile"), "execution_profile")
  validate_refs(required(value.approved_input_refs, "approved_input_refs"))
  identity_string(required(value.trace_id, "trace_id"), "trace_id")
  identity_string(required(value.dedup_key, "dedup_key"), "dedup_key")
  return value
end

local function validate_source(value)
  fields(value, { schema = true, source_id = true, target_url = true }, "source")
  if value.schema ~= M.schemas.source then fail("unknown-schema", "source schema") end
  if identity_string(required(value.source_id, "source.source_id"), "source.source_id") ~= "fixture-home" then fail("unsupported-source", "source.source_id is outside the walking skeleton") end
  local target_url = bounded(required(value.target_url, "source.target_url"), "source.target_url")
  if target_url ~= M.target_url then fail("unsupported-target", "source.target_url is outside the walking skeleton") end
  return value
end

local function validate_plan(value)
  fields(value, { schema = true, case_id = true, assertion = true }, "plan")
  if value.schema ~= M.schemas.plan then fail("unknown-schema", "plan schema") end
  if identity_string(required(value.case_id, "plan.case_id"), "plan.case_id") ~= M.case_id then
    fail("unsupported-case", "plan.case_id is outside the walking skeleton")
  end
  local assertion = required(value.assertion, "plan.assertion")
  fields(assertion, { assertion_id = true, expected = true, required = true, type = true }, "plan-assertion")
  if identity_string(required(assertion.assertion_id, "plan.assertion.assertion_id"), "plan.assertion.assertion_id") ~= M.assertion_id then
    fail("unsupported-assertion", "plan assertion is outside the walking skeleton")
  end
  if bounded(required(assertion.expected, "plan.assertion.expected"), "plan.assertion.expected") ~= "Fixture Home" then fail("unsupported-assertion", "plan assertion expected title is outside the walking skeleton") end
  if assertion.required ~= true then fail("unsupported-assertion", "plan assertion must be required") end
  if identity_string(required(assertion.type, "plan.assertion.type"), "plan.assertion.type") ~= "title-equals" then
    fail("unsupported-assertion", "plan assertion type must be title-equals")
  end
  return value
end

local function validate_pql_input(value)
  fields(value, { schema = true, requirement_id = true }, "pql-input")
  if value.schema ~= M.schemas.pql_input then fail("unknown-schema", "PQL input schema") end
  if identity_string(required(value.requirement_id, "pql_input.requirement_id"), "pql_input.requirement_id") ~= "REQ-HOME-TITLE" then fail("unsupported-requirement", "PQL requirement is outside the walking skeleton") end
  return value
end

local function validate_policy(value)
  fields(value, {
    schema = true,
    execution_profile = true,
    authorized_entrypoint = true,
    allowed_capabilities = true,
  }, "policy")
  if value.schema ~= M.schemas.policy then fail("unknown-schema", "policy schema") end
  identity_string(required(value.execution_profile, "policy.execution_profile"), "policy.execution_profile")
  identity_string(required(value.authorized_entrypoint, "policy.authorized_entrypoint"), "policy.authorized_entrypoint")
  exact_string_list(required(value.allowed_capabilities, "policy.allowed_capabilities"), "policy.allowed_capabilities", { M.capability })
  return value
end

local function validate_capability_set(value)
  fields(value, { schema = true, capabilities = true }, "capability-set")
  if value.schema ~= M.schemas.capability_set then fail("unknown-schema", "capability-set schema") end
  exact_string_list(required(value.capabilities, "capability_set.capabilities"), "capability_set.capabilities", { M.capability })
  return value
end

local function validate_entrypoint(value)
  fields(value, { executor_id = true, name = true, contract_major = true, capabilities = true }, "selected-entrypoint")
  if identity_string(required(value.executor_id, "selected_entrypoint.executor_id"), "selected_entrypoint.executor_id") ~= M.executor_id then
    fail("mapping-mismatch", "selected executor ID")
  end
  if identity_string(required(value.name, "selected_entrypoint.name"), "selected_entrypoint.name") ~= M.entrypoint then
    fail("mapping-mismatch", "selected entrypoint name")
  end
  if identity_string(required(value.contract_major, "selected_entrypoint.contract_major"), "selected_entrypoint.contract_major") ~= M.contract_major then
    fail("mapping-mismatch", "selected entrypoint contract major")
  end
  exact_string_list(required(value.capabilities, "selected_entrypoint.capabilities"), "selected_entrypoint.capabilities", { M.capability })
  return value
end

local function compute_admission_digest(executor, execution_profile, approved_input_refs, selected_entrypoint, admission_key, sha256_fn)
  validate_identity(executor)
  identity_string(execution_profile, "execution_profile")
  validate_refs(approved_input_refs)
  validate_entrypoint(selected_entrypoint)
  identity_string(admission_key, "admission_key")
  if type(sha256_fn) ~= "function" then fail("missing-sha256", "admission digest requires SHA-256") end
  local bytes = canonical_json.encode({
    schema = M.schemas.admission_request,
    admission_key = admission_key,
    executor = executor,
    execution_profile = execution_profile,
    approved_input_refs = approved_input_refs,
    selected_entrypoint = selected_entrypoint,
  })
  local ok, value = pcall(sha256_fn, bytes)
  if not ok then fail("sha256-failed", "admission SHA-256 failed") end
  return digest(value, "admission SHA-256")
end

local function validate_admission_receipt(value, admission_key, admission_digest)
  fields(value, { schema = true, status = true, admission_key = true, admission_digest = true }, "admission-receipt")
  if value.schema ~= M.schemas.admission_receipt or value.status ~= "admitted" then
    fail("malformed-admission-receipt", "admission receipt schema or status is invalid")
  end
  if identity_string(required(value.admission_key, "admission_receipt.admission_key"), "admission_receipt.admission_key") ~= admission_key then
    fail("admission-mismatch", "admission receipt key does not match")
  end
  if digest(required(value.admission_digest, "admission_receipt.admission_digest"), "admission_receipt.admission_digest") ~= admission_digest then
    fail("admission-mismatch", "admission receipt digest does not match")
  end
  return value
end

local function validate_admission_conflict(value, admission_key, attempted_digest)
  fields(value, {
    schema = true, status = true, admission_key = true,
    admitted_digest = true, attempted_digest = true,
  }, "admission-conflict")
  if value.schema ~= M.schemas.admission_conflict or value.status ~= "conflict" then
    fail("malformed-admission-conflict", "admission conflict schema or status is invalid")
  end
  if identity_string(required(value.admission_key, "admission_conflict.admission_key"), "admission_conflict.admission_key") ~= admission_key then
    fail("admission-mismatch", "admission conflict key does not match")
  end
  local admitted_digest = digest(required(value.admitted_digest, "admission_conflict.admitted_digest"), "admission_conflict.admitted_digest")
  local actual_attempted_digest = digest(required(value.attempted_digest, "admission_conflict.attempted_digest"), "admission_conflict.attempted_digest")
  if actual_attempted_digest ~= attempted_digest then
    fail("admission-mismatch", "admission conflict attempted digest does not match")
  end
  if admitted_digest == actual_attempted_digest then
    fail("malformed-admission-conflict", "admission conflict digests must differ")
  end
  return value
end

local function validate_resolver_failure(value)
  fields(value, { schema = true, status = true, admission_key = true, code = true }, "resolver-failure")
  if value.schema ~= M.schemas.resolver_failure or value.status ~= "rejected" then
    fail("malformed-resolver-failure", "resolver failure schema or status is invalid")
  end
  identity_string(required(value.admission_key, "resolver_failure.admission_key"), "resolver_failure.admission_key")
  local code = identity_string(required(value.code, "resolver_failure.code"), "resolver_failure.code")
  if not M.resolver_failure_codes[code] then fail("unknown-resolver-failure", code) end
  return value
end

local function validate_resolved_invocation(value, sha256_fn)
  fields(value, {
    schema = true,
    executor = true,
    execution_profile = true,
    approved_input_refs = true,
    source = true,
    plan = true,
    pql_input = true,
    selected_entrypoint = true,
    admission_digest = true,
    admission_receipt = true,
    trace_id = true,
    dedup_key = true,
  }, "resolved-invocation")
  if value.schema ~= M.schemas.resolved_invocation then fail("unknown-schema", "resolved invocation schema") end
  validate_identity(required(value.executor, "executor"))
  if value.executor.package_id ~= M.package_id or value.executor.entrypoint ~= M.entrypoint
    or value.executor.contract_major ~= M.contract_major then
    fail("mapping-mismatch", "resolved executor identity")
  end
  if identity_string(required(value.execution_profile, "execution_profile"), "execution_profile") ~= M.profile then
    fail("mapping-mismatch", "resolved execution profile")
  end
  validate_refs(required(value.approved_input_refs, "approved_input_refs"))
  validate_source(required(value.source, "source"))
  validate_plan(required(value.plan, "plan"))
  validate_pql_input(required(value.pql_input, "pql_input"))
  validate_entrypoint(required(value.selected_entrypoint, "selected_entrypoint"))
  identity_string(required(value.trace_id, "trace_id"), "trace_id")
  local admission_key = identity_string(required(value.dedup_key, "dedup_key"), "dedup_key")
  local admission_digest = digest(required(value.admission_digest, "admission_digest"), "admission_digest")
  validate_admission_receipt(required(value.admission_receipt, "admission_receipt"), admission_key, admission_digest)
  if sha256_fn ~= nil then
    local computed = compute_admission_digest(
      value.executor, value.execution_profile, value.approved_input_refs,
      value.selected_entrypoint, admission_key, sha256_fn
    )
    if computed ~= admission_digest then fail("admission-mismatch", "resolved invocation does not match its admission digest") end
  end
  return value
end

function M.validate_request(value) return validate_request(value) end
function M.validate_identity(value) return validate_identity(value) end
function M.validate_reference(value, field, expected_kind) return validate_reference(value, field, expected_kind) end
function M.validate_source(value) return validate_source(value) end
function M.validate_plan(value) return validate_plan(value) end
function M.validate_pql_input(value) return validate_pql_input(value) end
function M.validate_policy(value) return validate_policy(value) end
function M.validate_capability_set(value) return validate_capability_set(value) end
function M.validate_resolved_invocation(value, sha256_fn) return validate_resolved_invocation(value, sha256_fn) end
function M.compute_admission_digest(executor, execution_profile, approved_input_refs, selected_entrypoint, admission_key, sha256_fn)
  return compute_admission_digest(executor, execution_profile, approved_input_refs, selected_entrypoint, admission_key, sha256_fn)
end
function M.validate_admission_receipt(value, admission_key, admission_digest) return validate_admission_receipt(value, admission_key, admission_digest) end
function M.validate_admission_conflict(value, admission_key, attempted_digest) return validate_admission_conflict(value, admission_key, attempted_digest) end
function M.validate_resolver_failure(value) return validate_resolver_failure(value) end

function M.validate_freshness_check(value)
  fields(value, { schema = true, dedup_key = true, effect_id = true }, "freshness-check")
  if value.schema ~= M.schemas.freshness_check then fail("unknown-schema", "freshness check schema") end
  identity_string(required(value.dedup_key, "freshness_check.dedup_key"), "freshness_check.dedup_key")
  if identity_string(required(value.effect_id, "freshness_check.effect_id"), "freshness_check.effect_id") ~= M.effect_id then
    fail("mapping-mismatch", "freshness effect ID")
  end
  return value
end

function M.validate_browser_read_title(value)
  fields(value, { schema = true, effect_id = true, url = true }, "browser-read-title")
  if value.schema ~= M.schemas.browser_read_title then fail("unknown-schema", "Browser request schema") end
  if identity_string(required(value.effect_id, "browser.effect_id"), "browser.effect_id") ~= M.effect_id then
    fail("mapping-mismatch", "Browser effect ID")
  end
  if bounded(required(value.url, "browser.url"), "browser.url") ~= M.target_url then
    fail("mapping-mismatch", "Browser URL")
  end
  return value
end

local function validate_effect_receipt(value, expected_schema, completed_required, context, artifact_root)
  local allowed = { schema = true, effect_id = true, status = true, observed_url = true, observed_title = true,
    evidence_refs = true, evidence_size_bytes = true }
  if completed_required then allowed.completed_at = true end
  fields(value, allowed, context)
  if value.schema ~= expected_schema then fail("unknown-schema", context .. " schema") end
  if identity_string(required(value.effect_id, "effect_receipt.effect_id"), "effect_receipt.effect_id") ~= M.effect_id then
    fail("mapping-mismatch", "effect receipt ID")
  end
  if identity_string(required(value.status, "effect_receipt.status"), "effect_receipt.status") ~= "succeeded" then
    fail("effect-failed", "effect receipt status must be succeeded")
  end
  if bounded(required(value.observed_url, "effect_receipt.observed_url"), "effect_receipt.observed_url") ~= M.target_url then fail("mapping-mismatch", "effect receipt URL") end
  bounded(required(value.observed_title, "effect_receipt.observed_title"), "effect_receipt.observed_title", 4096)
  dense_list(required(value.evidence_refs, "effect_receipt.evidence_refs"), "effect_receipt.evidence_refs", 1, true)
  if #value.evidence_refs ~= 1 then fail("unsupported-evidence", "effect receipt must contain one evidence artifact") end
  local ref = value.evidence_refs[1]
  fields(ref, { kind=true, ref=true, sha256=true }, "effect-receipt-evidence-ref")
  if ref.kind ~= "artifact" then fail("reference-kind-mismatch", "effect evidence must be an artifact") end
  local root = artifact_root or ".testing/runs/dedup-walking-skeleton"
  if not strings.is_artifact_root(root, 4096) then fail("cross-run-pointer", "effect artifact root") end
  local expected = root .. "/evidence/title.json"
  if bounded(ref.ref, "effect_receipt.evidence_refs[1].ref") ~= expected then fail("cross-run-pointer", "effect evidence path") end
  digest(ref.sha256, "effect_receipt.evidence_refs[1].sha256")
  integer(required(value.evidence_size_bytes, "effect_receipt.evidence_size_bytes"), "effect_receipt.evidence_size_bytes", 0, 1000000000)
  if completed_required and time.iso_timestamp_epoch_seconds(required(value.completed_at, "effect_receipt.completed_at")) == nil then
    fail("invalid-timestamp", "effect_receipt.completed_at must be a UTC timestamp")
  end
  return value
end

function M.validate_browser_read_title_receipt(value, artifact_root)
  return validate_effect_receipt(value, M.schemas.browser_read_title_receipt, false, "browser-read-title-receipt", artifact_root)
end
function M.validate_effect_receipt(value, artifact_root)
  return validate_effect_receipt(value, M.schemas.effect_receipt, true, "effect-receipt", artifact_root)
end

function M.validate_canonical_write(value)
  fields(value, { schema = true, kind = true, dedup_key = true, canonical_sha256 = true, canonical_bytes = true }, "canonical-write")
  if value.schema ~= M.schemas.canonical_write then fail("unknown-schema", "canonical write schema") end
  local kind = identity_string(required(value.kind, "write.kind"), "write.kind")
  if kind ~= "evidence-manifest" and kind ~= "case-result-set" and kind ~= "result-authority-receipt" then
    fail("unsupported-write", "write kind")
  end
  identity_string(required(value.dedup_key, "write.dedup_key"), "write.dedup_key")
  digest(required(value.canonical_sha256, "write.canonical_sha256"), "write.canonical_sha256")
  local bytes = required(value.canonical_bytes, "write.canonical_bytes")
  if kind == "result-authority-receipt" then
    local body = type(bytes) == "string" and bytes:sub(1, -2) or nil
    if type(bytes) ~= "string" or bytes == "" or #bytes > 65536 or bytes:sub(-1) ~= "\n"
        or not canonical_json.is_valid_utf8(bytes) or body:find("[%z\1-\31\127]") ~= nil then
      fail("malformed-field", "write.canonical_bytes must be canonical JSON with one trailing LF")
    end
  else
    bounded(bytes, "write.canonical_bytes", 65536)
  end
  return value
end

local function execution_identity(value, schema, context)
  fields(value, { schema=true, dedup_key=true, admission_digest=true }, context)
  if value.schema ~= schema then fail("unknown-schema", context .. " schema") end
  identity_string(required(value.dedup_key, context .. ".dedup_key"), context .. ".dedup_key")
  digest(required(value.admission_digest, context .. ".admission_digest"), context .. ".admission_digest")
  return value
end

function M.validate_completed_execution_query(value) return execution_identity(value, M.schemas.completed_execution_query, "completed-execution-query") end
function M.validate_execution_claim_request(value) return execution_identity(value, M.schemas.execution_claim_request, "execution-claim-request") end

function M.validate_effect_state_query(value)
  fields(value, { schema=true, dedup_key=true, admission_digest=true, effect_id=true }, "effect-state-query")
  if value.schema ~= M.schemas.effect_state_query then fail("unknown-schema", "effect-state-query schema") end
  identity_string(required(value.dedup_key, "effect_state_query.dedup_key"), "effect_state_query.dedup_key")
  digest(required(value.admission_digest, "effect_state_query.admission_digest"), "effect_state_query.admission_digest")
  if identity_string(required(value.effect_id, "effect_state_query.effect_id"), "effect_state_query.effect_id") ~= M.effect_id then
    fail("mapping-mismatch", "effect-state-query effect ID")
  end
  return value
end

function M.validate_execution_claim_receipt(value, request)
  fields(value, { schema=true, status=true, dedup_key=true, admission_digest=true, claim_id=true }, "execution-claim-receipt")
  if value.schema ~= M.schemas.execution_claim_receipt or value.status ~= "claimed" then fail("claim-failed", "claim receipt schema or status") end
  identity_string(value.dedup_key, "claim.dedup_key"); digest(value.admission_digest, "claim.admission_digest"); identity_string(value.claim_id, "claim.claim_id")
  if request and (value.dedup_key ~= request.dedup_key or value.admission_digest ~= request.admission_digest) then fail("claim-mismatch", "claim identity") end
  return value
end

function M.validate_effect_intent(value, dedup_key, admission_digest)
  fields(value, { schema=true, dedup_key=true, admission_digest=true, claim_id=true, effect_id=true, url=true, started_at=true }, "effect-intent")
  if value.schema ~= M.schemas.effect_intent then fail("unknown-schema", "effect intent schema") end
  identity_string(value.dedup_key, "intent.dedup_key"); digest(value.admission_digest, "intent.admission_digest"); identity_string(value.claim_id, "intent.claim_id")
  if value.effect_id ~= M.effect_id or value.url ~= M.target_url then fail("mapping-mismatch", "effect intent") end
  if time.iso_timestamp_epoch_seconds(required(value.started_at, "intent.started_at")) == nil then
    fail("invalid-timestamp", "intent.started_at must be a UTC timestamp")
  end
  if dedup_key and (value.dedup_key ~= dedup_key or value.admission_digest ~= admission_digest) then
    fail("effect-state-mismatch", "effect intent identity")
  end
  return value
end

local function artifact_ref(value, field)
  fields(value, { kind=true, ref=true, sha256=true }, field)
  if value.kind ~= "artifact" then fail("reference-kind-mismatch", field) end
  bounded(value.ref, field .. ".ref"); digest(value.sha256, field .. ".sha256")
end

function M.validate_completed_execution(value, dedup_key, admission_digest)
  fields(value, { schema=true,status=true,dedup_key=true,admission_digest=true,claim_id=true,effect_id=true,case_result_set_ref=true,case_result_set_sha256=true,evidence_manifest_ref=true,evidence_manifest_sha256=true }, "completed-execution")
  if value.schema ~= M.schemas.completed_execution or value.status ~= "completed" then fail("completion-failed", "completed receipt schema or status") end
  identity_string(value.dedup_key, "completed.dedup_key"); digest(value.admission_digest, "completed.admission_digest"); identity_string(value.claim_id, "completed.claim_id")
  if value.effect_id ~= M.effect_id then fail("mapping-mismatch", "completed effect ID") end
  artifact_ref(value.case_result_set_ref, "completed.case_result_set_ref"); digest(value.case_result_set_sha256, "completed.case_result_set_sha256")
  artifact_ref(value.evidence_manifest_ref, "completed.evidence_manifest_ref"); digest(value.evidence_manifest_sha256, "completed.evidence_manifest_sha256")
  if dedup_key and (value.dedup_key ~= dedup_key or value.admission_digest ~= admission_digest) then fail("completion-mismatch", "completed identity") end
  return value
end

function M.validate_write_receipt(value)
  fields(value, { schema = true, status = true, ref = true }, "write-receipt")
  if value.schema ~= M.schemas.write_receipt then fail("unknown-schema", "write receipt schema") end
  if identity_string(required(value.status, "write_receipt.status"), "write_receipt.status") ~= "written" then
    fail("write-failed", "write receipt status must be written")
  end
  local ref = required(value.ref, "write_receipt.ref")
  fields(ref, { kind = true, ref = true, sha256 = true }, "write-receipt-ref")
  if identity_string(required(ref.kind, "write_receipt.ref.kind"), "write_receipt.ref.kind") ~= "artifact" then
    fail("reference-kind-mismatch", "write receipt ref must be an artifact")
  end
  bounded(required(ref.ref, "write_receipt.ref.ref"), "write_receipt.ref.ref")
  digest(required(ref.sha256, "write_receipt.ref.sha256"), "write_receipt.ref.sha256")
  return value
end

function M.validate_execution(value)
  fields(value, { schema = true, case_result = true, effect_receipt = true, case_result_ref = true }, "execution")
  if value.schema ~= M.schemas.execution then fail("unknown-schema", "execution schema") end
  if type(required(value.case_result, "case_result")) ~= "table" then fail("malformed-execution", "case_result must be a table") end
  M.validate_effect_receipt(required(value.effect_receipt, "effect_receipt"))
  local ref = required(value.case_result_ref, "case_result_ref")
  fields(ref, { kind = true, ref = true, sha256 = true }, "case-result-ref")
  if identity_string(required(ref.kind, "case_result_ref.kind"), "case_result_ref.kind") ~= "artifact" then
    fail("reference-kind-mismatch", "case result ref must be an artifact")
  end
  bounded(required(ref.ref, "case_result_ref.ref"), "case_result_ref.ref")
  digest(required(ref.sha256, "case_result_ref.sha256"), "case_result_ref.sha256")
  return value
end

return M
