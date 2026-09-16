local lineage = require("contract.execution_authorization_lineage")
local canonical_json = require("contract.canonical_json")
local sha256 = require("contract.sha256")
local t = fkst.test

local function digest(char) return string.rep(char, 64) end
local function canonical_digest(value) return sha256.hex(canonical_json.encode(value)) end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[copy(key)] = copy(item) end
  return result
end

local function ref(run_id, suffix) return ".testing/runs/" .. run_id .. "/" .. suffix end

local function expect_failure(fragment, fn)
  local ok, err = pcall(fn)
  t.eq(ok, false)
  t.is_true(tostring(err):find(fragment, 1, true) ~= nil)
end

local run_id = "authorization-lineage-run"
local repository = {
  url = "https://example.invalid/testing/fixture.git",
  commit_sha = string.rep("1", 40),
}

local function envelope(value)
  local result = {
    repository = copy(repository), run_id = run_id,
    trace_id = "trace-authorization-lineage", dedup_key = run_id,
    recorded_at = "2026-09-10T00:10:00Z", source_max_uses = 1,
    evidence_role = "audit-only", human_approval_required = false,
    authorization_capability = false,
    execution_authorized = false, promotion_authorized = false, reusable = false,
  }
  for key, item in pairs(value) do result[key] = copy(item) end
  return result
end

local function expected(value)
  local result = copy(value)
  for _, key in ipairs({
    "schema", "status", "receipt_id", "recorded_at", "source_max_uses",
    "evidence_role", "human_approval_required", "authorization_capability", "execution_authorized",
    "promotion_authorized", "reusable",
  }) do result[key] = nil end
  return result
end

local paths = {}
for name, suffix in pairs(lineage.paths) do paths[name] = ref(run_id, suffix) end

local artifact_digests = {
  profile_claim = digest("1"), preauthorization_claim = digest("2"),
  grant_verification = digest("3"), execution_claim = digest("4"),
  execution_completion = digest("5"),
}

local function profile_claim()
  return envelope({
    schema = lineage.schemas.profile_claim, status = "claimed",
    receipt_id = "profile-approval-claim-receipt-1",
    profile_source_ref = { kind = "host-profile-policy", ref = "policies/profile-v1" },
    profile_artifact_ref = ref(run_id, "authorization/project-profile.json"),
    profile_artifact_sha256 = digest("6"), profile_sha256 = digest("7"),
    profile_revision = "fixture-profile-v1",
    approval_artifact_ref = ref(run_id, "authorization/profile-approval.json"),
    approval_artifact_sha256 = digest("8"), approval_id = "profile-approval-1",
    approval_sha256 = digest("9"),
    approval_authority = { kind = "host-policy", ref = "policies/profile-approval-v1" },
    policy_revision = "profile-approval-v1",
    evidence_ref = { kind = "signed-attestation", ref = "attestations/profile-approval-1" },
    validation_receipt_ref = ref(run_id, "authorization/profile-validation-receipt.json"),
    validation_receipt_sha256 = digest("a"), claim_fingerprint_sha256 = digest("b"),
    claimed_at = "2026-09-10T00:01:00Z",
  })
end

local function preauthorization_claim()
  return envelope({
    schema = lineage.schemas.preauthorization_claim, status = "claimed",
    receipt_id = "preauthorization-claim-receipt-1",
    profile_claim_receipt_ref = paths.profile_claim,
    profile_claim_receipt_sha256 = artifact_digests.profile_claim,
    preauthorization_ref = ref(run_id, "execution/preauthorization.json"),
    preauthorization_sha256 = digest("c"), authorization_id = "preauthorization-1",
    profile_sha256 = digest("7"), case_catalog_ref = ref(run_id, "execution/case-catalog.json"),
    case_catalog_sha256 = digest("d"), plan_ref = ref(run_id, "execution/structured-plan.json"),
    plan_sha256 = digest("e"),
    environment_receipt_ref = ref(run_id, "environment/environment-receipt-ready.json"),
    environment_receipt_sha256 = digest("f"),
    authority = { kind = "host-policy", ref = "policies/execution-v1" },
    policy_revision = "execution-v1",
    evidence_ref = { kind = "signed-attestation", ref = "attestations/preauthorization-1" },
    claim_fingerprint_sha256 = digest("0"), claimed_at = "2026-09-10T00:02:00Z",
  })
end

local function grant_verification()
  return envelope({
    schema = lineage.schemas.grant_verification, status = "authenticated",
    receipt_id = "grant-verification-receipt-1",
    preauthorization_claim_receipt_ref = paths.preauthorization_claim,
    preauthorization_claim_receipt_sha256 = artifact_digests.preauthorization_claim,
    grant_ref = ref(run_id, "execution/execution-grant.json"), grant_sha256 = digest("a"),
    grant_id = "execution-grant-1",
    parent_authorization_ref = ref(run_id, "execution/preauthorization.json"),
    parent_authorization_sha256 = digest("c"),
    plan_ref = ref(run_id, "execution/structured-plan.json"), plan_sha256 = digest("e"),
    environment_receipt_ref = ref(run_id, "environment/environment-receipt-ready.json"),
    environment_receipt_sha256 = digest("f"),
    authority = { kind = "host-policy", ref = "policies/execution-v1" },
    policy_revision = "execution-v1",
    evidence_ref = { kind = "signed-attestation", ref = "attestations/execution-grant-1" },
    verifier_ref = { kind = "host-verifier", ref = "verifiers/execution-v1" },
    verification_id = "grant-verification-1", verified_at = "2026-09-10T00:03:00Z",
  })
end

local function execution_claim()
  return envelope({
    schema = lineage.schemas.execution_claim, status = "claimed",
    receipt_id = "execution-claim-receipt-1",
    grant_verification_receipt_ref = paths.grant_verification,
    grant_verification_receipt_sha256 = artifact_digests.grant_verification,
    preauthorization_claim_receipt_ref = paths.preauthorization_claim,
    preauthorization_claim_receipt_sha256 = artifact_digests.preauthorization_claim,
    grant_ref = ref(run_id, "execution/execution-grant.json"), grant_sha256 = digest("a"),
    grant_id = "execution-grant-1", plan_ref = ref(run_id, "execution/structured-plan.json"),
    plan_sha256 = digest("e"),
    environment_receipt_ref = ref(run_id, "environment/environment-receipt-ready.json"),
    environment_receipt_sha256 = digest("f"), artifact_root = ref(run_id, "execution"),
    operation_id = run_id, claim_fingerprint_sha256 = digest("1"),
    claimed_at = "2026-09-10T00:04:00Z",
  })
end

local function execution_completion()
  return envelope({
    schema = lineage.schemas.execution_completion, status = "completed",
    receipt_id = "execution-completion-receipt-1",
    execution_claim_receipt_ref = paths.execution_claim,
    execution_claim_receipt_sha256 = artifact_digests.execution_claim,
    result_ref = ref(run_id, "execution/execution.json"), result_sha256 = digest("2"),
    case_result_set_ref = ref(run_id, "execution/case-result-set.json"),
    case_result_set_artifact_sha256 = digest("3"),
    evidence_manifest_ref = ref(run_id, "execution/evidence-manifest.json"),
    evidence_manifest_artifact_sha256 = digest("4"), completed_at = "2026-09-10T00:05:00Z",
  })
end

local function lineage_fixture()
  local values = {
    profile_claim = profile_claim(), preauthorization_claim = preauthorization_claim(),
    grant_verification = grant_verification(), execution_claim = execution_claim(),
    execution_completion = execution_completion(),
  }
  local bound_digests = {}
  bound_digests.profile_claim = canonical_digest(values.profile_claim)
  values.preauthorization_claim.profile_claim_receipt_sha256 = bound_digests.profile_claim
  bound_digests.preauthorization_claim = canonical_digest(values.preauthorization_claim)
  values.grant_verification.preauthorization_claim_receipt_sha256 = bound_digests.preauthorization_claim
  bound_digests.grant_verification = canonical_digest(values.grant_verification)
  values.execution_claim.grant_verification_receipt_sha256 = bound_digests.grant_verification
  values.execution_claim.preauthorization_claim_receipt_sha256 = bound_digests.preauthorization_claim
  bound_digests.execution_claim = canonical_digest(values.execution_claim)
  values.execution_completion.execution_claim_receipt_sha256 = bound_digests.execution_claim
  bound_digests.execution_completion = canonical_digest(values.execution_completion)
  local artifacts, bindings, expected_values = {}, {}, {}
  for name, value in pairs(values) do
    artifacts[name] = { ref = paths[name], sha256 = bound_digests[name], value = value }
    bindings[name] = { ref = paths[name], sha256 = bound_digests[name] }
    expected_values[name] = expected(value)
  end
  local index = {
    schema = lineage.schemas.lineage_index, status = "complete", repository = copy(repository),
    run_id = run_id, trace_id = "trace-authorization-lineage", dedup_key = run_id,
    recorded_at = "2026-09-10T00:10:00Z", receipts = bindings, lineage_complete = true,
    source_max_uses = 1, evidence_role = "audit-only", human_approval_required = false,
    authorization_capability = false, execution_authorized = false,
    promotion_authorized = false, reusable = false,
  }
  return index, artifacts, expected_values
end

local function reseal_lineage(index, artifacts, expected_values)
  local function bind(name)
    local value = artifacts[name].value
    local value_digest = canonical_digest(value)
    artifacts[name].sha256 = value_digest
    index.receipts[name].sha256 = value_digest
    expected_values[name] = expected(value)
    return value_digest
  end

  local profile_digest = bind("profile_claim")
  artifacts.preauthorization_claim.value.profile_claim_receipt_sha256 = profile_digest
  local preauthorization_digest = bind("preauthorization_claim")
  artifacts.grant_verification.value.preauthorization_claim_receipt_sha256 = preauthorization_digest
  artifacts.execution_claim.value.preauthorization_claim_receipt_sha256 = preauthorization_digest
  local grant_digest = bind("grant_verification")
  artifacts.execution_claim.value.grant_verification_receipt_sha256 = grant_digest
  local claim_digest = bind("execution_claim")
  artifacts.execution_completion.value.execution_claim_receipt_sha256 = claim_digest
  bind("execution_completion")
end

return {
  test_accepts_complete_non_capability_authorization_lineage = function()
    local index, artifacts, expected_values = lineage_fixture()
    t.eq(lineage.validate_lineage_index(index, artifacts, expected_values), index)
  end,

  test_individual_receipts_require_complete_source_bindings = function()
    local value = profile_claim()
    t.raises(function() lineage.validate_profile_claim_receipt(value) end)
    local expected_value = expected(value)
    expected_value.profile_sha256 = nil
    t.raises(function() lineage.validate_profile_claim_receipt(value, expected_value) end)
    t.eq(lineage.validate_profile_claim_receipt(value, expected(value)), value)
  end,

  test_execution_claim_cannot_be_recorded_before_the_claim_event = function()
    local value = execution_claim()
    value.recorded_at = "2026-09-10T00:03:00Z"
    t.raises(function() lineage.validate_execution_claim_receipt(value, expected(value)) end)
  end,

  test_profile_claim_cannot_be_recorded_before_the_claim_event = function()
    local value = profile_claim()
    value.recorded_at = "2026-09-10T00:00:59Z"
    expect_failure("malformed-time: profile-approval-claim-receipt cannot be recorded before its claim", function()
      lineage.validate_profile_claim_receipt(value, expected(value))
    end)
  end,

  test_execution_completion_cannot_be_recorded_before_completion = function()
    local value = execution_completion()
    value.recorded_at = "2026-09-10T00:04:59Z"
    expect_failure("malformed-time: execution-completion-receipt cannot be recorded before completion", function()
      lineage.validate_execution_completion_receipt(value, expected(value))
    end)
  end,

  test_exported_claim_receipts_reject_raw_claim_handles_and_capability_flags = function()
    local value = execution_claim()
    value.claim_id = "runtime-fence-handle"
    t.raises(function() lineage.validate_execution_claim_receipt(value, expected(value)) end)
    for _, mutate in ipairs({
      function(item) item.human_approval_required = true end,
      function(item) item.authorization_capability = true end,
      function(item) item.execution_authorized = true end,
      function(item) item.promotion_authorized = true end,
      function(item) item.reusable = true end,
      function(item) item.source_max_uses = 2 end,
      function(item) item.evidence_role = "authorization" end,
    }) do
      value = profile_claim()
      mutate(value)
      t.raises(function() lineage.validate_profile_claim_receipt(value, expected(value)) end)
    end
  end,

  test_source_identity_references_reject_credentials_paths_and_url_metadata = function()
    for _, changed in ipairs({
      { field = "profile_source_ref", ref = "file:///private/tmp/profile" },
      { field = "profile_source_ref", ref = "https://user:token@example.test/profile" },
      { field = "profile_source_ref", ref = "policies/../durable-store/claim" },
      { field = "approval_authority", ref = "~/.ssh/id_ed25519" },
      { field = "approval_authority", ref = "policies/profile?id=secret" },
      { field = "evidence_ref", ref = "attestations/profile#replay-handle" },
    }) do
      local value = profile_claim()
      value[changed.field].ref = changed.ref
      t.raises(function() lineage.validate_profile_claim_receipt(value, expected(value)) end)
    end
  end,

  test_source_identity_fields_reject_interchangeable_kinds = function()
    for _, changed in ipairs({
      { field = "profile_source_ref", kind = "host-policy", ref = "policies/profile-v1" },
      { field = "approval_authority", kind = "signed-attestation", ref = "attestations/approval" },
      { field = "evidence_ref", kind = "host-verifier", ref = "verifiers/profile" },
    }) do
      local value = profile_claim()
      value[changed.field] = { kind = changed.kind, ref = changed.ref }
      t.raises(function() lineage.validate_profile_claim_receipt(value, expected(value)) end)
    end
    local value = grant_verification()
    value.verifier_ref = { kind = "host-policy", ref = "policies/execution-v1" }
    t.raises(function() lineage.validate_grant_verification_receipt(value, expected(value)) end)
  end,

  test_source_identity_fields_accept_existing_host_relative_identity_keys = function()
    local value = profile_claim()
    value.profile_source_ref.ref = "fixtures/canonical-qa-profile"
    value.approval_authority.ref = "fixtures/canonical-qa"
    value.evidence_ref.ref = "fixtures/approvals/canonical-qa"
    t.eq(lineage.validate_profile_claim_receipt(value, expected(value)), value)
  end,

  test_rejects_digest_domain_cross_run_and_cross_repository_substitution = function()
    local value = profile_claim()
    local source = expected(value)
    value.profile_artifact_sha256, value.profile_sha256 = value.profile_sha256, value.profile_artifact_sha256
    t.raises(function() lineage.validate_profile_claim_receipt(value, source) end)

    value = grant_verification()
    source = expected(value)
    value.plan_ref = ref("another-run", "execution/structured-plan.json")
    t.raises(function() lineage.validate_grant_verification_receipt(value, source) end)

    value = preauthorization_claim()
    source = expected(value)
    value.repository.commit_sha = string.rep("2", 40)
    t.raises(function() lineage.validate_preauthorization_claim_receipt(value, source) end)
  end,

  test_claim_and_completion_are_distinct_immutable_receipts = function()
    local value = execution_claim()
    value.result_ref = ref(run_id, "execution/execution.json")
    value.result_sha256 = digest("2")
    t.raises(function() lineage.validate_execution_claim_receipt(value, expected(value)) end)

    local completion = execution_completion()
    completion.claim_fingerprint_sha256 = digest("1")
    t.raises(function() lineage.validate_execution_completion_receipt(completion, expected(completion)) end)
  end,

  test_index_rejects_incomplete_or_resealed_cross_artifact_lineage = function()
    local index, artifacts, expected_values = lineage_fixture()
    index.receipts.execution_completion = nil
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)

    index, artifacts, expected_values = lineage_fixture()
    artifacts.preauthorization_claim.value.profile_sha256 = digest("5")
    expected_values.preauthorization_claim = expected(artifacts.preauthorization_claim.value)
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)

    index, artifacts, expected_values = lineage_fixture()
    artifacts.execution_claim.sha256 = digest("9")
    index.receipts.execution_claim.sha256 = digest("9")
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)
  end,

  test_index_rejects_resealed_cross_grant_identity = function()
    local index, artifacts, expected_values = lineage_fixture()
    artifacts.execution_claim.value.grant_id = "foreign-execution-grant"
    reseal_lineage(index, artifacts, expected_values)
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)
  end,

  test_index_rejects_completion_outside_claimed_execution_root = function()
    local index, artifacts, expected_values = lineage_fixture()
    artifacts.execution_completion.value.result_ref = ref(run_id, "foreign/execution.json")
    reseal_lineage(index, artifacts, expected_values)
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)
  end,

  test_index_rejects_resealed_authority_or_policy_discontinuity = function()
    for _, mutate in ipairs({
      function(value) value.authority.ref = "policies/foreign-execution-v1" end,
      function(value) value.policy_revision = "foreign-execution-v1" end,
    }) do
      local index, artifacts, expected_values = lineage_fixture()
      mutate(artifacts.grant_verification.value)
      reseal_lineage(index, artifacts, expected_values)
      t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)
    end
  end,

  test_index_rejects_resealed_plan_or_environment_substitution = function()
    for _, mutate in ipairs({
      function(grant, claim)
        grant.plan_ref = ref(run_id, "execution/foreign-plan.json")
        grant.plan_sha256 = digest("6")
        claim.plan_ref = grant.plan_ref
        claim.plan_sha256 = grant.plan_sha256
      end,
      function(grant, claim)
        grant.environment_receipt_ref = ref(run_id, "environment/foreign-ready.json")
        grant.environment_receipt_sha256 = digest("6")
        claim.environment_receipt_ref = grant.environment_receipt_ref
        claim.environment_receipt_sha256 = grant.environment_receipt_sha256
      end,
    }) do
      local index, artifacts, expected_values = lineage_fixture()
      mutate(artifacts.grant_verification.value, artifacts.execution_claim.value)
      reseal_lineage(index, artifacts, expected_values)
      t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)
    end
  end,

  test_index_rejects_resealed_out_of_order_authorization_events = function()
    local index, artifacts, expected_values = lineage_fixture()
    artifacts.preauthorization_claim.value.claimed_at = "2026-09-09T23:59:59Z"
    reseal_lineage(index, artifacts, expected_values)
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)
  end,

  test_receipts_reject_malformed_identity_digest_repository_pointer_and_time = function()
    local cases = {
      {
        factory = profile_claim,
        validate = lineage.validate_profile_claim_receipt,
        mutate = function(value) value.receipt_id = "" end,
      },
      {
        factory = profile_claim,
        validate = lineage.validate_profile_claim_receipt,
        mutate = function(value) value.profile_sha256 = "bad" end,
      },
      {
        factory = profile_claim,
        validate = lineage.validate_profile_claim_receipt,
        mutate = function(value) value.repository.url = "http://example.invalid/repository.git" end,
      },
      {
        factory = profile_claim,
        validate = lineage.validate_profile_claim_receipt,
        mutate = function(value) value.repository.commit_sha = "mutable" end,
      },
      {
        factory = profile_claim,
        validate = lineage.validate_profile_claim_receipt,
        mutate = function(value) value.profile_artifact_ref = "outside.json" end,
      },
      {
        factory = profile_claim,
        validate = lineage.validate_profile_claim_receipt,
        mutate = function(value) value.schema = "unknown-profile-claim" end,
      },
      {
        factory = preauthorization_claim,
        validate = lineage.validate_preauthorization_claim_receipt,
        mutate = function(value) value.claimed_at = "2026-09-10T00:10:01Z" end,
      },
      {
        factory = grant_verification,
        validate = lineage.validate_grant_verification_receipt,
        mutate = function(value) value.verified_at = "2026-09-10T00:10:01Z" end,
      },
      {
        factory = execution_claim,
        validate = lineage.validate_execution_claim_receipt,
        mutate = function(value) value.artifact_root = ref("another-run", "execution") end,
      },
    }
    for _, item in ipairs(cases) do
      local value = item.factory()
      item.mutate(value)
      t.raises(function() item.validate(value, expected(value)) end)
    end
  end,

  test_all_receipt_families_reject_execution_authority_capability = function()
    for _, item in ipairs({
      { factory = profile_claim, validate = lineage.validate_profile_claim_receipt },
      { factory = preauthorization_claim, validate = lineage.validate_preauthorization_claim_receipt },
      { factory = grant_verification, validate = lineage.validate_grant_verification_receipt },
      { factory = execution_claim, validate = lineage.validate_execution_claim_receipt },
      { factory = execution_completion, validate = lineage.validate_execution_completion_receipt },
    }) do
      local value = item.factory()
      value.execution_authorized = true
      t.raises(function() item.validate(value, expected(value)) end)
    end
  end,

  test_index_rejects_capability_missing_sources_noncanonical_and_foreign_receipts = function()
    local index, artifacts, expected_values = lineage_fixture()
    index.authorization_capability = true
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)

    index, artifacts, expected_values = lineage_fixture()
    index.human_approval_required = true
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)

    index, artifacts, expected_values = lineage_fixture()
    index.execution_authorized = true
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)

    index, artifacts, expected_values = lineage_fixture()
    index.promotion_authorized = true
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)

    index, artifacts, expected_values = lineage_fixture()
    t.raises(function() lineage.validate_lineage_index(index, nil, expected_values) end)

    index, artifacts, expected_values = lineage_fixture()
    index.receipts.profile_claim.ref = ref(run_id, "authorization-lineage/not-canonical.json")
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)

    index, artifacts, expected_values = lineage_fixture()
    artifacts.profile_claim = nil
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)

    index, artifacts, expected_values = lineage_fixture()
    artifacts.profile_claim.value.repository.commit_sha = string.rep("2", 40)
    reseal_lineage(index, artifacts, expected_values)
    t.raises(function() lineage.validate_lineage_index(index, artifacts, expected_values) end)
  end,
}
