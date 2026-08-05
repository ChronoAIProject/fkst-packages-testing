local binding = require("host_structured_effect_binding")
local t = fkst.test

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function fixture()
  local repository = {
    url = "https://example.invalid/generic-host.git",
    commit_sha = string.rep("a", 40),
  }
  local trace_id = "binding-trace"
  local dedup_key = "binding-dedup"
  local profile_sha256 = string.rep("1", 64)
  local profile_digest = string.rep("2", 64)
  local approval_digest = string.rep("9", 64)
  local validation_digest = string.rep("3", 64)
  local preauthorization_digest = string.rep("4", 64)
  local environment_digest = string.rep("5", 64)
  local plan_digest = string.rep("6", 64)
  local grant_digest = string.rep("7", 64)
  local authority = { kind = "host-policy", ref = "generic-host" }
  local evidence_ref = { kind = "signed-attestation", ref = "run-1-execution-grant" }
  local workspace_ref = { kind = "workspace", ref = "run-1-workspace" }
  local origin = "http://127.0.0.1:4173"
  local runtime_ports = { { name = "application", port = 4173 } }
  local envelope = {
    repository = repository, operation_id = "run-1", workspace_ref = workspace_ref,
    profile_artifact_sha256 = profile_digest, profile_sha256 = profile_sha256,
    validation_receipt_sha256 = validation_digest,
    preauthorization_sha256 = preauthorization_digest,
    environment_receipt_sha256 = environment_digest,
    plan_sha256 = plan_digest, grant_sha256 = grant_digest,
    trace_id = trace_id, dedup_key = dedup_key,
  }
  local artifacts = {
    profile = { digest = profile_digest, value = {
      revision = "profile-v1", repository = copy(repository),
    } },
    approval = { digest = approval_digest, value = {
      approval_id = "approval-1", authority = copy(authority), policy_revision = "policy-v1",
    } },
    validation = { digest = validation_digest, value = {
      profile_revision = "profile-v1", profile_sha256 = profile_sha256,
      approval_sha256 = approval_digest, repository = copy(repository),
      trace_id = trace_id, dedup_key = dedup_key,
    } },
    preauthorization = { digest = preauthorization_digest, value = {
      profile_sha256 = profile_sha256, case_catalog_sha256 = string.rep("8", 64),
      repository = copy(repository), authority = copy(authority), policy_revision = "policy-v1",
      trace_id = trace_id, dedup_key = dedup_key,
    } },
    environment = { digest = environment_digest, value = {
      status = "ready", operation_id = "run-1", profile_sha256 = profile_sha256,
      workspace_ref = copy(workspace_ref), repository = copy(repository), base_url = origin .. "/health",
      runtime_ports = copy(runtime_ports), trace_id = trace_id, dedup_key = dedup_key,
    } },
    plan = { digest = plan_digest, value = {
      environment_receipt_sha256 = environment_digest,
      case_catalog_sha256 = string.rep("8", 64), repository = copy(repository),
      trace_id = trace_id, dedup_key = dedup_key,
    } },
    grant = { digest = grant_digest, value = {
      parent_authorization_sha256 = preauthorization_digest,
      plan_sha256 = plan_digest, environment_receipt_sha256 = environment_digest,
      repository = copy(repository), authority = copy(authority), policy_revision = "policy-v1",
      evidence_ref = copy(evidence_ref), trace_id = trace_id, dedup_key = dedup_key,
    } },
  }
  return {
    envelope = envelope, artifacts = artifacts, profile_authorization_verified = true,
    profile_sha256 = profile_sha256, expected_base_url = origin .. "/health",
    expected_runtime_ports = runtime_ports,
    expected_grant_evidence_ref = evidence_ref,
  }
end

return {
  test_accepts_one_fully_bound_authority_chain = function()
    t.eq(binding.matches(fixture()), true)
  end,

  test_rejects_authority_environment_and_identity_drift = function()
    local mutations = {
      function(value) value.profile_authorization_verified = false end,
      function(value) value.artifacts.grant.value.authority.ref = "foreign-policy" end,
      function(value) value.artifacts.environment.value.status = "starting" end,
      function(value) value.artifacts.environment.value.base_url = "http://127.0.0.1:4174/health" end,
      function(value) value.artifacts.environment.value.runtime_ports[1].port = 4174 end,
      function(value) value.artifacts.validation.value.repository.commit_sha = string.rep("b", 40) end,
      function(value) value.artifacts.plan.value.trace_id = "foreign-trace" end,
      function(value) value.artifacts.grant.value.evidence_ref.ref = "foreign-evidence" end,
    }
    for _, mutate in ipairs(mutations) do
      local value = fixture()
      mutate(value)
      t.eq(binding.matches(value), false)
    end
  end,
}
