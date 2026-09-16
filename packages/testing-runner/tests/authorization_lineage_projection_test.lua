local canonical_json = require("contract.canonical_json")
local lineage = require("contract.execution_authorization_lineage")
local projection = require("testing_runtime.authorization_lineage_projection")
local sha256 = require("contract.sha256")
local t = fkst.test

local run_id = "authorization-lineage-projection-run"
local root = ".testing/runs/" .. run_id
local repository = {
  url = "https://example.invalid/testing/fixture.git",
  commit_sha = string.rep("1", 40),
}

local function digest(char) return string.rep(char, 64) end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[copy(key)] = copy(item) end
  return result
end

local function memory_store(options)
  options = options or {}
  local store = { artifacts = {} }

  function store:load(path)
    return self.artifacts[path] and copy(self.artifacts[path]) or nil
  end

  function store:write_raw(path, body)
    if options.reject_writes then return false end
    if self.artifacts[path] ~= nil then return self.artifacts[path].raw == body end
    self.artifacts[path] = {
      raw = body,
      digest = sha256.hex(body),
      value = json.decode(body),
    }
    return true
  end

  return store
end

local function new_projector(store, overrides)
  local options = {
    store = store or memory_store(),
    sha256 = sha256.hex,
    fingerprint_secret = string.rep("private-fixture-secret-", 2),
    repository = copy(repository),
    run_id = run_id,
    trace_id = "trace-authorization-lineage-projection",
    dedup_key = run_id,
    artifact_root = root,
  }
  for key, value in pairs(overrides or {}) do options[key] = value end
  return projection.new(options), options
end

local function source(fields)
  local value = {
    repository = copy(repository),
    run_id = run_id,
    trace_id = "trace-authorization-lineage-projection",
    dedup_key = run_id,
  }
  for key, item in pairs(fields) do value[key] = copy(item) end
  return value
end

local function receipt_fields(value)
  local result = copy(value)
  result.repository = nil
  result.run_id = nil
  result.trace_id = nil
  result.dedup_key = nil
  return result
end

local function write_lineage(projector)
  local expected = {}
  local artifacts = {}
  expected.profile_claim = source({
    profile_source_ref = { kind = "host-profile-policy", ref = "policies/profile-v1" },
    profile_artifact_ref = root .. "/authorization/project-profile.json",
    profile_artifact_sha256 = digest("1"),
    profile_sha256 = digest("2"),
    profile_revision = "profile-v1",
    approval_artifact_ref = root .. "/authorization/profile-approval.json",
    approval_artifact_sha256 = digest("3"),
    approval_id = "profile-approval-1",
    approval_sha256 = digest("4"),
    approval_authority = { kind = "host-policy", ref = "policies/profile-approval-v1" },
    policy_revision = "profile-policy-v1",
    evidence_ref = { kind = "signed-attestation", ref = "attestations/profile-approval-1" },
    validation_receipt_ref = root .. "/authorization/profile-validation.json",
    validation_receipt_sha256 = digest("5"),
    claim_fingerprint_sha256 = digest("6"),
    claimed_at = "2026-09-10T00:01:00Z",
  })
  artifacts.profile_claim = projector:write_receipt(
    "profile_claim", "profile-claim-1", "2026-09-10T00:01:00Z",
    receipt_fields(expected.profile_claim), expected.profile_claim)

  expected.preauthorization_claim = source({
    profile_claim_receipt_ref = artifacts.profile_claim.ref,
    profile_claim_receipt_sha256 = artifacts.profile_claim.sha256,
    preauthorization_ref = root .. "/execution/preauthorization.json",
    preauthorization_sha256 = digest("7"),
    authorization_id = "preauthorization-1",
    profile_sha256 = digest("2"),
    case_catalog_ref = root .. "/execution/case-catalog.json",
    case_catalog_sha256 = digest("8"),
    plan_ref = root .. "/execution/structured-plan.json",
    plan_sha256 = digest("9"),
    environment_receipt_ref = root .. "/environment/ready.json",
    environment_receipt_sha256 = digest("a"),
    authority = { kind = "host-policy", ref = "policies/execution-v1" },
    policy_revision = "execution-v1",
    evidence_ref = { kind = "signed-attestation", ref = "attestations/preauthorization-1" },
    claim_fingerprint_sha256 = digest("b"),
    claimed_at = "2026-09-10T00:02:00Z",
  })
  artifacts.preauthorization_claim = projector:write_receipt(
    "preauthorization_claim", "preauthorization-claim-1", "2026-09-10T00:02:00Z",
    receipt_fields(expected.preauthorization_claim), expected.preauthorization_claim)

  expected.grant_verification = source({
    preauthorization_claim_receipt_ref = artifacts.preauthorization_claim.ref,
    preauthorization_claim_receipt_sha256 = artifacts.preauthorization_claim.sha256,
    grant_ref = root .. "/execution/execution-grant.json",
    grant_sha256 = digest("c"),
    grant_id = "execution-grant-1",
    parent_authorization_ref = root .. "/execution/preauthorization.json",
    parent_authorization_sha256 = digest("7"),
    plan_ref = root .. "/execution/structured-plan.json",
    plan_sha256 = digest("9"),
    environment_receipt_ref = root .. "/environment/ready.json",
    environment_receipt_sha256 = digest("a"),
    authority = { kind = "host-policy", ref = "policies/execution-v1" },
    policy_revision = "execution-v1",
    evidence_ref = { kind = "signed-attestation", ref = "attestations/execution-grant-1" },
    verifier_ref = { kind = "host-verifier", ref = "verifiers/execution-v1" },
    verification_id = "grant-verification-1",
    verified_at = "2026-09-10T00:03:00Z",
  })
  artifacts.grant_verification = projector:write_receipt(
    "grant_verification", "grant-verification-1", "2026-09-10T00:03:00Z",
    receipt_fields(expected.grant_verification), expected.grant_verification)

  expected.execution_claim = source({
    grant_verification_receipt_ref = artifacts.grant_verification.ref,
    grant_verification_receipt_sha256 = artifacts.grant_verification.sha256,
    preauthorization_claim_receipt_ref = artifacts.preauthorization_claim.ref,
    preauthorization_claim_receipt_sha256 = artifacts.preauthorization_claim.sha256,
    grant_ref = root .. "/execution/execution-grant.json",
    grant_sha256 = digest("c"),
    grant_id = "execution-grant-1",
    plan_ref = root .. "/execution/structured-plan.json",
    plan_sha256 = digest("9"),
    environment_receipt_ref = root .. "/environment/ready.json",
    environment_receipt_sha256 = digest("a"),
    artifact_root = root .. "/execution",
    operation_id = run_id,
    claim_fingerprint_sha256 = digest("d"),
    claimed_at = "2026-09-10T00:04:00Z",
  })
  artifacts.execution_claim = projector:write_receipt(
    "execution_claim", "execution-claim-1", "2026-09-10T00:04:00Z",
    receipt_fields(expected.execution_claim), expected.execution_claim)

  expected.execution_completion = source({
    execution_claim_receipt_ref = artifacts.execution_claim.ref,
    execution_claim_receipt_sha256 = artifacts.execution_claim.sha256,
    result_ref = root .. "/execution/execution.json",
    result_sha256 = digest("e"),
    case_result_set_ref = root .. "/execution/case-result-set.json",
    case_result_set_artifact_sha256 = digest("f"),
    evidence_manifest_ref = root .. "/execution/evidence-manifest.json",
    evidence_manifest_artifact_sha256 = digest("0"),
    completed_at = "2026-09-10T00:05:00Z",
  })
  artifacts.execution_completion = projector:write_receipt(
    "execution_completion", "execution-completion-1", "2026-09-10T00:05:00Z",
    receipt_fields(expected.execution_completion), expected.execution_completion)

  return artifacts, expected
end

return {
  test_persists_complete_canonical_lineage_and_replays_immutably = function()
    local store = memory_store()
    local projector = new_projector(store)
    local artifacts, expected = write_lineage(projector)
    local index = projector:write_index("2026-09-10T00:06:00Z", artifacts, expected)
    t.eq(index.ref, root .. "/authorization-lineage/index.json")
    t.eq(index.value.status, "complete")
    t.eq(index.value.lineage_complete, true)
    t.eq(index.value.human_approval_required, false)
    t.eq(index.value.authorization_capability, false)
    t.eq(index.value.execution_authorized, false)
    t.eq(index.value.promotion_authorized, false)
    t.eq(index.value.receipts.execution_completion.sha256, artifacts.execution_completion.sha256)

    local replayed, replay_expected = write_lineage(projector)
    local replayed_index = projector:write_index("2026-09-10T00:06:00Z", replayed, replay_expected)
    t.eq(replayed_index.sha256, index.sha256)
    t.eq(projector:load_receipt("profile_claim", expected.profile_claim).sha256,
      artifacts.profile_claim.sha256)
  end,

  test_fingerprint_is_private_deterministic_and_domain_separated = function()
    local projector = new_projector(memory_store())
    local first = projector:fingerprint("execution-claim", "private-claim-1")
    t.eq(#first, 64)
    t.eq(first, projector:fingerprint("execution-claim", "private-claim-1"))
    t.is_true(first ~= projector:fingerprint("execution-claim", "private-claim-2"))
    t.is_true(first ~= projector:fingerprint("grant-claim", "private-claim-1"))
  end,

  test_constructor_and_identity_inputs_fail_closed = function()
    t.raises(function() projection.new(nil) end)
    t.raises(function() new_projector(memory_store(), { fingerprint_secret = "short" }) end)
    t.raises(function() new_projector(memory_store(), { run_id = "bad run" }) end)
    t.raises(function() new_projector(memory_store(), { artifact_root = root .. "/foreign" }) end)
    local projector = new_projector(memory_store())
    t.raises(function() projector:path("unknown") end)
    t.raises(function() projector:fingerprint("bad domain", "claim") end)
  end,

  test_receipt_writes_reject_missing_sources_shadowing_and_storage_failure = function()
    local projector = new_projector(memory_store())
    t.raises(function() projector:write_receipt("unknown", "receipt", "2026-09-10T00:00:00Z", {}, {}) end)
    t.raises(function()
      projector:write_receipt("profile_claim", "receipt", "2026-09-10T00:00:00Z",
        { run_id = "shadow" }, {})
    end)
    local rejecting = new_projector(memory_store({ reject_writes = true }))
    local expected = source({})
    t.raises(function()
      rejecting:write_receipt("profile_claim", "receipt", "2026-09-10T00:00:00Z", {}, expected)
    end)
  end,

  test_loading_and_indexing_require_canonical_complete_predecessors = function()
    local store = memory_store()
    local projector = new_projector(store)
    t.raises(function() projector:load_receipt("profile_claim", {}) end)
    t.raises(function() projector:load_receipt("profile_claim", nil) end)
    t.raises(function() projector:write_index("2026-09-10T00:00:00Z", nil, {}) end)

    local artifacts, expected = write_lineage(projector)
    local profile_path = projector:path("profile_claim")
    store.artifacts[profile_path].raw = canonical_json.encode({ foreign = true })
    t.raises(function() projector:load_receipt("profile_claim", expected.profile_claim) end)

    local foreign_value = copy(artifacts.profile_claim.value)
    foreign_value.profile_revision = "foreign-profile"
    local foreign_raw = canonical_json.encode(foreign_value)
    store.artifacts[profile_path] = {
      raw = foreign_raw,
      digest = sha256.hex(foreign_raw),
      value = foreign_value,
    }
    t.raises(function()
      projector:write_receipt("profile_claim", "profile-claim-1", "2026-09-10T00:01:00Z",
        receipt_fields(expected.profile_claim), expected.profile_claim)
    end)
  end,
}
