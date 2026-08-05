local M = {}

local function equal(left, right)
  if left == right then return true end
  if type(left) ~= "table" or type(right) ~= "table" then return false end
  for key, value in pairs(left) do
    if not equal(value, right[key]) then return false end
  end
  for key, _ in pairs(right) do
    if left[key] == nil then return false end
  end
  return true
end

local function same_repository(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.url == right.url and left.commit_sha == right.commit_sha
end

local function same_pointer(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.kind == right.kind and left.ref == right.ref
end

local function same_run(value, envelope)
  return type(value) == "table"
    and value.trace_id == envelope.trace_id and value.dedup_key == envelope.dedup_key
end

local function artifact(value)
  return type(value) == "table" and type(value.value) == "table"
    and type(value.digest) == "string"
end

function M.matches(spec)
  local envelope = spec.envelope
  local artifacts = spec.artifacts
  if type(envelope) ~= "table" or type(artifacts) ~= "table"
    or not artifact(artifacts.profile) or not artifact(artifacts.approval)
    or not artifact(artifacts.validation) or not artifact(artifacts.preauthorization)
    or not artifact(artifacts.environment) or not artifact(artifacts.plan)
    or not artifact(artifacts.grant) or spec.profile_authorization_verified ~= true then
    return false
  end

  local profile = artifacts.profile
  local approval = artifacts.approval
  local validation = artifacts.validation
  local preauthorization = artifacts.preauthorization
  local environment = artifacts.environment
  local plan = artifacts.plan
  local grant = artifacts.grant
  local repository = envelope.repository

  if profile.digest ~= envelope.profile_artifact_sha256
    or spec.profile_sha256 ~= envelope.profile_sha256
    or not same_repository(profile.value.repository, repository)
    or validation.digest ~= envelope.validation_receipt_sha256
    or validation.value.profile_revision ~= profile.value.revision
    or validation.value.profile_sha256 ~= envelope.profile_sha256
    or not same_repository(validation.value.repository, repository)
    or not same_run(validation.value, envelope)
    or preauthorization.digest ~= envelope.preauthorization_sha256
    or preauthorization.value.profile_sha256 ~= envelope.profile_sha256
    or not same_repository(preauthorization.value.repository, repository)
    or not same_run(preauthorization.value, envelope)
    or environment.digest ~= envelope.environment_receipt_sha256
    or environment.value.status ~= "ready"
    or environment.value.operation_id ~= envelope.operation_id
    or environment.value.profile_sha256 ~= envelope.profile_sha256
    or not equal(environment.value.workspace_ref, envelope.workspace_ref)
    or not same_repository(environment.value.repository, repository)
    or not same_run(environment.value, envelope)
    or plan.digest ~= envelope.plan_sha256
    or plan.value.environment_receipt_sha256 ~= environment.digest
    or plan.value.case_catalog_sha256 ~= preauthorization.value.case_catalog_sha256
    or not same_repository(plan.value.repository, repository)
    or not same_run(plan.value, envelope)
    or grant.digest ~= envelope.grant_sha256
    or grant.value.parent_authorization_sha256 ~= preauthorization.digest
    or grant.value.plan_sha256 ~= plan.digest
    or grant.value.environment_receipt_sha256 ~= environment.digest
    or not same_repository(grant.value.repository, repository)
    or not same_run(grant.value, envelope)
    or not same_pointer(grant.value.authority, preauthorization.value.authority)
    or grant.value.policy_revision ~= preauthorization.value.policy_revision
    or not same_pointer(grant.value.evidence_ref, spec.expected_grant_evidence_ref) then
    return false
  end

  if spec.expected_base_url ~= nil and environment.value.base_url ~= spec.expected_base_url then
    return false
  end
  if spec.expected_runtime_ports ~= nil
    and not equal(environment.value.runtime_ports, spec.expected_runtime_ports) then
    return false
  end
  return true
end

return M
