-- contract.execution_authorization_lineage: non-capability audit evidence for Host authorization.
local error_facts = require("contract.error_facts")
local canonical_json = require("contract.canonical_json")
local sha256 = require("contract.sha256")
local time = require("contract.time")

local M = {}

M.schemas = {
  profile_claim = "testing-project-profile-approval-claim-receipt.v1",
  preauthorization_claim = "testing-structured-preauthorization-claim-receipt.v1",
  grant_verification = "testing-structured-execution-grant-verification-receipt.v1",
  execution_claim = "testing-structured-execution-claim-receipt.v1",
  execution_completion = "testing-structured-execution-completion-receipt.v1",
  lineage_index = "testing-execution-authorization-lineage-index.v1",
}

M.paths = {
  profile_claim = "authorization-lineage/profile-approval-claim.json",
  preauthorization_claim = "authorization-lineage/preauthorization-claim.json",
  grant_verification = "authorization-lineage/grant-verification.json",
  execution_claim = "authorization-lineage/execution-claim.json",
  execution_completion = "authorization-lineage/execution-completion.json",
}

local common_fields = {
  schema = true, status = true, receipt_id = true, repository = true, run_id = true,
  trace_id = true, dedup_key = true, recorded_at = true, source_max_uses = true,
  evidence_role = true, human_approval_required = true, authorization_capability = true,
  execution_authorized = true, promotion_authorized = true, reusable = true,
}

local function fail(classification, message)
  error(error_facts.error_message("contract.execution-authorization-lineage", classification, message))
end

local function field_set(specific)
  local result = {}
  for key in pairs(common_fields) do result[key] = true end
  for _, key in ipairs(specific) do result[key] = true end
  return result
end

local function only_fields(value, allowed, context)
  if type(value) ~= "table" then fail("malformed-" .. context, context .. " must be a table") end
  for key in pairs(value) do
    if type(key) ~= "string" or allowed[key] ~= true then
      fail("malformed-" .. context, "unsupported field " .. tostring(key))
    end
  end
end

local function bounded(value, field, limit)
  if type(value) ~= "string" or value == "" or #value > (limit or 1024)
    or value:find("[%z\1-\31\127]") ~= nil then
    fail("malformed-field", field .. " must be a bounded string")
  end
  return value
end

local function identity(value, field)
  bounded(value, field, 180)
  if value:find("%s") ~= nil then fail("malformed-field", field .. " must not contain whitespace") end
  return value
end

local function digest(value, field)
  if type(value) ~= "string" or #value ~= 64 or value:match("^[0-9a-f]+$") == nil then
    fail("malformed-digest", field .. " must be a lowercase SHA-256 digest")
  end
  return value
end

local function timestamp(value, field)
  local epoch = time.iso_timestamp_epoch_seconds(value)
  if epoch == nil then fail("malformed-time", field .. " must be a UTC timestamp") end
  return epoch
end

local function repository(value, field)
  only_fields(value, { url = true, commit_sha = true }, field)
  bounded(value.url, field .. ".url", 2048)
  if value.url:match("^https://[^%s@/?#]+/[^%s?#]+$") == nil
    or value.url:sub(-1) == "/" or value.url:find("\\", 1, true) ~= nil then
    fail("malformed-repository", field .. ".url must be a canonical credential-free HTTPS URL")
  end
  if type(value.commit_sha) ~= "string" or #value.commit_sha ~= 40
    or value.commit_sha:match("^[0-9a-f]+$") == nil then
    fail("mutable-revision", field .. ".commit_sha must be an immutable lowercase commit SHA")
  end
end

local function source_ref(value, field, expected_kind)
  only_fields(value, { kind = true, ref = true }, field)
  identity(value.kind, field .. ".kind")
  bounded(value.ref, field .. ".ref", 4096)
  if value.kind ~= expected_kind
    or value.ref:match("^[A-Za-z0-9][A-Za-z0-9._/-]*$") == nil
    or value.ref:find("//", 1, true) ~= nil or value.ref:sub(-1) == "/" then
    fail("unsafe-reference", field .. " must be a closed Host identity reference")
  end
  for segment in value.ref:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      fail("unsafe-reference", field .. ".ref contains traversal")
    end
  end
end

local function artifact_pointer(value, field)
  bounded(value, field, 4096)
  if value:match("^%.testing/runs/[A-Za-z0-9._-]+/.+$") == nil
    or value:find("\\", 1, true) ~= nil or value:find("//", 1, true) ~= nil
    or value:find("%s") ~= nil or value:find("?", 1, true) ~= nil
    or value:find("#", 1, true) ~= nil then
    fail("unsafe-reference", field .. " must be a run-scoped artifact pointer")
  end
  for segment in value:gmatch("[^/]+") do
    if segment == "." or segment == ".." then fail("unsafe-reference", field .. " contains traversal") end
  end
end

local function run_root(value)
  return value:match("^(%.testing/runs/[A-Za-z0-9._-]+)")
end

local function validate_run_pointers(value, fields, context)
  local expected_root = ".testing/runs/" .. value.run_id
  for _, field in ipairs(fields) do
    artifact_pointer(value[field], context .. "." .. field)
    if run_root(value[field]) ~= expected_root then
      fail("cross-run-reference", context .. "." .. field .. " is outside the receipt run")
    end
  end
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

local function require_bindings(value, expected, fields, context)
  if type(expected) ~= "table" then
    fail("missing-source-bindings", context .. " requires complete source bindings")
  end
  local allowed = {}
  for _, field in ipairs(fields) do allowed[field] = true end
  only_fields(expected, allowed, context .. "-source-bindings")
  for _, field in ipairs(fields) do
    if expected[field] == nil then
      fail("missing-source-binding", context .. "." .. field .. " source binding is required")
    end
    if not equal(value[field], expected[field]) then
      fail("foreign-receipt", context .. "." .. field .. " differs from the authorized effect")
    end
  end
end

local function validate_common(value, schema, status, context)
  if value.schema ~= schema or value.status ~= status then
    fail("malformed-receipt", context .. " schema or status is invalid")
  end
  identity(value.receipt_id, context .. ".receipt_id")
  identity(value.run_id, context .. ".run_id")
  identity(value.trace_id, context .. ".trace_id")
  identity(value.dedup_key, context .. ".dedup_key")
  timestamp(value.recorded_at, context .. ".recorded_at")
  repository(value.repository, context .. ".repository")
  if value.source_max_uses ~= 1 or value.evidence_role ~= "audit-only"
    or value.human_approval_required ~= false
    or value.authorization_capability ~= false or value.execution_authorized ~= false
    or value.promotion_authorized ~= false or value.reusable ~= false then
    fail("capability-confusion", context .. " must remain non-reusable audit evidence")
  end
end

local profile_fields = {
  "repository", "run_id", "trace_id", "dedup_key", "profile_source_ref",
  "profile_artifact_ref", "profile_artifact_sha256", "profile_sha256", "profile_revision",
  "approval_artifact_ref", "approval_artifact_sha256", "approval_id", "approval_sha256",
  "approval_authority", "policy_revision", "evidence_ref", "validation_receipt_ref",
  "validation_receipt_sha256", "claim_fingerprint_sha256", "claimed_at",
}

function M.validate_profile_claim_receipt(value, expected)
  local context = "profile-approval-claim-receipt"
  only_fields(value, field_set({
    "profile_source_ref", "profile_artifact_ref", "profile_artifact_sha256", "profile_sha256",
    "profile_revision", "approval_artifact_ref", "approval_artifact_sha256", "approval_id",
    "approval_sha256", "approval_authority", "policy_revision", "evidence_ref",
    "validation_receipt_ref", "validation_receipt_sha256", "claim_fingerprint_sha256",
    "claimed_at",
  }), context)
  validate_common(value, M.schemas.profile_claim, "claimed", context)
  source_ref(value.profile_source_ref, context .. ".profile_source_ref", "host-profile-policy")
  source_ref(value.approval_authority, context .. ".approval_authority", "host-policy")
  source_ref(value.evidence_ref, context .. ".evidence_ref", "signed-attestation")
  identity(value.profile_revision, context .. ".profile_revision")
  identity(value.approval_id, context .. ".approval_id")
  identity(value.policy_revision, context .. ".policy_revision")
  validate_run_pointers(value, {
    "profile_artifact_ref", "approval_artifact_ref", "validation_receipt_ref",
  }, context)
  for _, field in ipairs({
    "profile_artifact_sha256", "profile_sha256", "approval_artifact_sha256",
    "approval_sha256", "validation_receipt_sha256", "claim_fingerprint_sha256",
  }) do digest(value[field], context .. "." .. field) end
  if timestamp(value.claimed_at, context .. ".claimed_at") > timestamp(value.recorded_at, context .. ".recorded_at") then
    fail("malformed-time", context .. " cannot be recorded before its claim")
  end
  require_bindings(value, expected, profile_fields, context)
  return value
end

local preauthorization_fields = {
  "repository", "run_id", "trace_id", "dedup_key", "profile_claim_receipt_ref",
  "profile_claim_receipt_sha256", "preauthorization_ref", "preauthorization_sha256",
  "authorization_id", "profile_sha256", "case_catalog_ref", "case_catalog_sha256",
  "plan_ref", "plan_sha256", "environment_receipt_ref", "environment_receipt_sha256",
  "authority", "policy_revision", "evidence_ref", "claim_fingerprint_sha256", "claimed_at",
}

function M.validate_preauthorization_claim_receipt(value, expected)
  local context = "preauthorization-claim-receipt"
  only_fields(value, field_set({
    "profile_claim_receipt_ref", "profile_claim_receipt_sha256", "preauthorization_ref",
    "preauthorization_sha256", "authorization_id", "profile_sha256", "case_catalog_ref",
    "case_catalog_sha256", "plan_ref", "plan_sha256", "environment_receipt_ref",
    "environment_receipt_sha256", "authority", "policy_revision", "evidence_ref",
    "claim_fingerprint_sha256", "claimed_at",
  }), context)
  validate_common(value, M.schemas.preauthorization_claim, "claimed", context)
  identity(value.authorization_id, context .. ".authorization_id")
  identity(value.policy_revision, context .. ".policy_revision")
  source_ref(value.authority, context .. ".authority", "host-policy")
  source_ref(value.evidence_ref, context .. ".evidence_ref", "signed-attestation")
  validate_run_pointers(value, {
    "profile_claim_receipt_ref", "preauthorization_ref", "case_catalog_ref", "plan_ref",
    "environment_receipt_ref",
  }, context)
  for _, field in ipairs({
    "profile_claim_receipt_sha256", "preauthorization_sha256", "profile_sha256",
    "case_catalog_sha256", "plan_sha256", "environment_receipt_sha256",
    "claim_fingerprint_sha256",
  }) do digest(value[field], context .. "." .. field) end
  if timestamp(value.claimed_at, context .. ".claimed_at") > timestamp(value.recorded_at, context .. ".recorded_at") then
    fail("malformed-time", context .. " cannot be recorded before its claim")
  end
  require_bindings(value, expected, preauthorization_fields, context)
  return value
end

local grant_fields = {
  "repository", "run_id", "trace_id", "dedup_key", "preauthorization_claim_receipt_ref",
  "preauthorization_claim_receipt_sha256", "grant_ref", "grant_sha256", "grant_id",
  "parent_authorization_ref", "parent_authorization_sha256", "plan_ref", "plan_sha256",
  "environment_receipt_ref", "environment_receipt_sha256", "authority", "policy_revision",
  "evidence_ref", "verifier_ref", "verification_id", "verified_at",
}

function M.validate_grant_verification_receipt(value, expected)
  local context = "grant-verification-receipt"
  only_fields(value, field_set({
    "preauthorization_claim_receipt_ref", "preauthorization_claim_receipt_sha256",
    "grant_ref", "grant_sha256", "grant_id", "parent_authorization_ref",
    "parent_authorization_sha256", "plan_ref", "plan_sha256", "environment_receipt_ref",
    "environment_receipt_sha256", "authority", "policy_revision", "evidence_ref",
    "verifier_ref", "verification_id", "verified_at",
  }), context)
  validate_common(value, M.schemas.grant_verification, "authenticated", context)
  identity(value.grant_id, context .. ".grant_id")
  identity(value.policy_revision, context .. ".policy_revision")
  identity(value.verification_id, context .. ".verification_id")
  source_ref(value.authority, context .. ".authority", "host-policy")
  source_ref(value.evidence_ref, context .. ".evidence_ref", "signed-attestation")
  source_ref(value.verifier_ref, context .. ".verifier_ref", "host-verifier")
  validate_run_pointers(value, {
    "preauthorization_claim_receipt_ref", "grant_ref", "parent_authorization_ref",
    "plan_ref", "environment_receipt_ref",
  }, context)
  for _, field in ipairs({
    "preauthorization_claim_receipt_sha256", "grant_sha256",
    "parent_authorization_sha256", "plan_sha256", "environment_receipt_sha256",
  }) do digest(value[field], context .. "." .. field) end
  if timestamp(value.verified_at, context .. ".verified_at") > timestamp(value.recorded_at, context .. ".recorded_at") then
    fail("malformed-time", context .. " cannot be recorded before verification")
  end
  require_bindings(value, expected, grant_fields, context)
  return value
end

local execution_claim_fields = {
  "repository", "run_id", "trace_id", "dedup_key", "grant_verification_receipt_ref",
  "grant_verification_receipt_sha256", "preauthorization_claim_receipt_ref",
  "preauthorization_claim_receipt_sha256", "grant_ref", "grant_sha256", "grant_id",
  "plan_ref", "plan_sha256", "environment_receipt_ref", "environment_receipt_sha256",
  "artifact_root", "operation_id", "claim_fingerprint_sha256", "claimed_at",
}

function M.validate_execution_claim_receipt(value, expected)
  local context = "execution-claim-receipt"
  only_fields(value, field_set({
    "grant_verification_receipt_ref", "grant_verification_receipt_sha256",
    "preauthorization_claim_receipt_ref", "preauthorization_claim_receipt_sha256",
    "grant_ref", "grant_sha256", "grant_id", "plan_ref", "plan_sha256",
    "environment_receipt_ref", "environment_receipt_sha256", "artifact_root",
    "operation_id", "claim_fingerprint_sha256", "claimed_at",
  }), context)
  validate_common(value, M.schemas.execution_claim, "claimed", context)
  identity(value.grant_id, context .. ".grant_id")
  identity(value.operation_id, context .. ".operation_id")
  artifact_pointer(value.artifact_root, context .. ".artifact_root")
  if run_root(value.artifact_root) ~= ".testing/runs/" .. value.run_id
    or value.artifact_root:sub(-1) == "/" then
    fail("cross-run-reference", context .. ".artifact_root must be inside the exact receipt run")
  end
  validate_run_pointers(value, {
    "grant_verification_receipt_ref", "preauthorization_claim_receipt_ref", "grant_ref",
    "plan_ref", "environment_receipt_ref",
  }, context)
  for _, field in ipairs({
    "grant_verification_receipt_sha256", "preauthorization_claim_receipt_sha256",
    "grant_sha256", "plan_sha256", "environment_receipt_sha256",
    "claim_fingerprint_sha256",
  }) do digest(value[field], context .. "." .. field) end
  if timestamp(value.claimed_at, context .. ".claimed_at") > timestamp(value.recorded_at, context .. ".recorded_at") then
    fail("malformed-time", context .. " cannot be recorded before its claim")
  end
  require_bindings(value, expected, execution_claim_fields, context)
  return value
end

local completion_fields = {
  "repository", "run_id", "trace_id", "dedup_key", "execution_claim_receipt_ref",
  "execution_claim_receipt_sha256", "result_ref", "result_sha256", "case_result_set_ref",
  "case_result_set_artifact_sha256", "evidence_manifest_ref",
  "evidence_manifest_artifact_sha256", "completed_at",
}

function M.validate_execution_completion_receipt(value, expected)
  local context = "execution-completion-receipt"
  only_fields(value, field_set({
    "execution_claim_receipt_ref", "execution_claim_receipt_sha256", "result_ref",
    "result_sha256", "case_result_set_ref", "case_result_set_artifact_sha256",
    "evidence_manifest_ref", "evidence_manifest_artifact_sha256", "completed_at",
  }), context)
  validate_common(value, M.schemas.execution_completion, "completed", context)
  validate_run_pointers(value, {
    "execution_claim_receipt_ref", "result_ref", "case_result_set_ref",
    "evidence_manifest_ref",
  }, context)
  for _, field in ipairs({
    "execution_claim_receipt_sha256", "result_sha256", "case_result_set_artifact_sha256",
    "evidence_manifest_artifact_sha256",
  }) do digest(value[field], context .. "." .. field) end
  if timestamp(value.completed_at, context .. ".completed_at") > timestamp(value.recorded_at, context .. ".recorded_at") then
    fail("malformed-time", context .. " cannot be recorded before completion")
  end
  require_bindings(value, expected, completion_fields, context)
  return value
end

local receipt_names = {
  "profile_claim", "preauthorization_claim", "grant_verification",
  "execution_claim", "execution_completion",
}

function M.validate_lineage_index(value, artifacts, expected)
  local context = "authorization-lineage-index"
  only_fields(value, {
    schema = true, status = true, repository = true, run_id = true, trace_id = true,
    dedup_key = true, recorded_at = true, receipts = true, lineage_complete = true,
    source_max_uses = true, evidence_role = true, human_approval_required = true,
    authorization_capability = true, execution_authorized = true,
    promotion_authorized = true, reusable = true,
  }, context)
  if value.schema ~= M.schemas.lineage_index or value.status ~= "complete"
    or value.lineage_complete ~= true or value.evidence_role ~= "audit-only"
    or value.human_approval_required ~= false
    or value.source_max_uses ~= 1 or value.authorization_capability ~= false
    or value.execution_authorized ~= false or value.promotion_authorized ~= false
    or value.reusable ~= false then
    fail("capability-confusion", context .. " must be complete non-reusable audit evidence")
  end
  identity(value.run_id, context .. ".run_id")
  identity(value.trace_id, context .. ".trace_id")
  identity(value.dedup_key, context .. ".dedup_key")
  timestamp(value.recorded_at, context .. ".recorded_at")
  repository(value.repository, context .. ".repository")
  only_fields(value.receipts, {
    profile_claim = true, preauthorization_claim = true, grant_verification = true,
    execution_claim = true, execution_completion = true,
  }, context .. ".receipts")
  if type(artifacts) ~= "table" or type(expected) ~= "table" then
    fail("missing-source-bindings", context .. " requires all receipt artifacts and source bindings")
  end
  local validators = {
    profile_claim = M.validate_profile_claim_receipt,
    preauthorization_claim = M.validate_preauthorization_claim_receipt,
    grant_verification = M.validate_grant_verification_receipt,
    execution_claim = M.validate_execution_claim_receipt,
    execution_completion = M.validate_execution_completion_receipt,
  }
  local root = ".testing/runs/" .. value.run_id .. "/"
  for _, name in ipairs(receipt_names) do
    local binding = value.receipts[name]
    only_fields(binding, { ref = true, sha256 = true }, context .. ".receipts." .. name)
    artifact_pointer(binding.ref, context .. ".receipts." .. name .. ".ref")
    digest(binding.sha256, context .. ".receipts." .. name .. ".sha256")
    if binding.ref ~= root .. M.paths[name] then
      fail("noncanonical-reference", context .. ".receipts." .. name .. " path is not canonical")
    end
    local artifact = artifacts[name]
    if type(artifact) ~= "table" or artifact.ref ~= binding.ref or artifact.sha256 ~= binding.sha256
      or type(artifact.value) ~= "table" then
      fail("immutable-binding-failed", context .. ".receipts." .. name .. " bytes are not bound")
    end
    if sha256.hex(canonical_json.encode(artifact.value)) ~= binding.sha256 then
      fail("immutable-binding-failed", context .. ".receipts." .. name .. " canonical bytes differ")
    end
    validators[name](artifact.value, expected[name])
    if not equal(artifact.value.repository, value.repository)
      or artifact.value.run_id ~= value.run_id or artifact.value.trace_id ~= value.trace_id
      or artifact.value.dedup_key ~= value.dedup_key then
      fail("foreign-receipt", context .. ".receipts." .. name .. " belongs to another run")
    end
  end
  local profile = artifacts.profile_claim.value
  local preauthorization = artifacts.preauthorization_claim.value
  local grant = artifacts.grant_verification.value
  local claim = artifacts.execution_claim.value
  local completion = artifacts.execution_completion.value
  if preauthorization.profile_claim_receipt_ref ~= value.receipts.profile_claim.ref
    or preauthorization.profile_claim_receipt_sha256 ~= value.receipts.profile_claim.sha256
    or grant.preauthorization_claim_receipt_ref ~= value.receipts.preauthorization_claim.ref
    or grant.preauthorization_claim_receipt_sha256 ~= value.receipts.preauthorization_claim.sha256
    or claim.grant_verification_receipt_ref ~= value.receipts.grant_verification.ref
    or claim.grant_verification_receipt_sha256 ~= value.receipts.grant_verification.sha256
    or claim.preauthorization_claim_receipt_ref ~= value.receipts.preauthorization_claim.ref
    or claim.preauthorization_claim_receipt_sha256 ~= value.receipts.preauthorization_claim.sha256
    or completion.execution_claim_receipt_ref ~= value.receipts.execution_claim.ref
    or completion.execution_claim_receipt_sha256 ~= value.receipts.execution_claim.sha256
    or profile.profile_sha256 ~= preauthorization.profile_sha256
    or preauthorization.preauthorization_ref ~= grant.parent_authorization_ref
    or preauthorization.preauthorization_sha256 ~= grant.parent_authorization_sha256
    or grant.grant_ref ~= claim.grant_ref or grant.grant_sha256 ~= claim.grant_sha256
    or grant.grant_id ~= claim.grant_id
    or not equal(preauthorization.authority, grant.authority)
    or preauthorization.policy_revision ~= grant.policy_revision
    or preauthorization.plan_ref ~= grant.plan_ref
    or preauthorization.plan_sha256 ~= grant.plan_sha256
    or preauthorization.environment_receipt_ref ~= grant.environment_receipt_ref
    or preauthorization.environment_receipt_sha256 ~= grant.environment_receipt_sha256
    or grant.plan_ref ~= claim.plan_ref or grant.plan_sha256 ~= claim.plan_sha256
    or grant.environment_receipt_ref ~= claim.environment_receipt_ref
    or grant.environment_receipt_sha256 ~= claim.environment_receipt_sha256 then
    fail("lineage-binding-mismatch", context .. " receipt chain is incomplete or inconsistent")
  end
  if completion.result_ref ~= claim.artifact_root .. "/execution.json"
    or completion.case_result_set_ref ~= claim.artifact_root .. "/case-result-set.json"
    or completion.evidence_manifest_ref ~= claim.artifact_root .. "/evidence-manifest.json" then
    fail("lineage-binding-mismatch", context .. " completion artifacts differ from the claimed execution root")
  end
  local profile_epoch = timestamp(profile.claimed_at, context .. ".profile_claim.claimed_at")
  local preauthorization_epoch = timestamp(
    preauthorization.claimed_at, context .. ".preauthorization_claim.claimed_at")
  local grant_epoch = timestamp(grant.verified_at, context .. ".grant_verification.verified_at")
  local claim_epoch = timestamp(claim.claimed_at, context .. ".execution_claim.claimed_at")
  local completion_epoch = timestamp(
    completion.completed_at, context .. ".execution_completion.completed_at")
  local index_epoch = timestamp(value.recorded_at, context .. ".recorded_at")
  if profile_epoch > preauthorization_epoch or preauthorization_epoch > grant_epoch
    or grant_epoch > claim_epoch or claim_epoch > completion_epoch
    or completion_epoch > index_epoch then
    fail("lineage-chronology-invalid", context .. " authorization events are out of order")
  end
  return value
end

return M
