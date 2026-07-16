local project_profile = require("contract.project_profile")
local t = fkst.test

local commit_sha = string.rep("a", 40)

local function fake_sha256(value)
  local first, second = 2166136261, 2246822519
  local text = tostring(value or "")
  for index = 1, #text do
    local byte = text:byte(index)
    first = (first * 33 + byte) % 4294967291
    second = (second * 65599 + byte + index) % 4294967279
  end
  local block = string.format("%08x%08x", first, second)
  return block .. block .. block .. block
end

local function copy(value)
  if type(value) ~= "table" then return value end
  local result = {}
  for key, item in pairs(value) do result[copy(key)] = copy(item) end
  return result
end

local function profile()
  return {
    schema = project_profile.schemas.profile,
    revision = "profile-revision-1",
    repository = {
      url = "https://github.com/ChronoAIProject/example-project.git",
      commit_sha = commit_sha,
    },
    working_directory = ".",
    commands = {
      install = { "npm", "ci" },
      build = { "npm", "run", "build" },
      migrate = { "npm", "run", "migrate" },
      seed = { "npm", "run", "seed:test" },
      start = { "node", "server.js" },
      cleanup = { "scripts/cleanup-test-project" },
    },
    dependent_services = {
      {
        name = "cache",
        start_argv = { "redis-server", "--port", "6380" },
        cleanup_argv = { "redis-cli", "-p", "6380", "shutdown" },
        readiness_checks = {
          { type = "tcp", host = "127.0.0.1", port = 6380 },
        },
      },
    },
    readiness_checks = {
      { type = "http", url = "http://127.0.0.1:4173/health", expected_status = 200 },
      { type = "argv", argv = { "scripts/verify-test-project" } },
    },
    allowed_origins = {
      "http://127.0.0.1:4173",
    },
    secret_refs = {
      {
        name = "DATABASE_URL",
        type = "secret-reference",
        source_ref = { kind = "host-secret", ref = "testing/example-project/database-url" },
      },
    },
    mutation_policy = {
      mode = "fixture-scoped",
      allowed_operations = { "create", "update", "delete" },
      cleanup_required = true,
    },
    timeouts = {
      install_seconds = 30,
      build_seconds = 30,
      migrate_seconds = 30,
      seed_seconds = 30,
      start_seconds = 30,
      readiness_seconds = 30,
      cleanup_seconds = 30,
      total_seconds = 300,
      receipt_ttl_seconds = 120,
    },
    resource_budgets = {
      cpu_millis = 2000,
      memory_mb = 2048,
      disk_mb = 4096,
      processes = 32,
      network_requests = 1000,
      output_bytes = 1048576,
    },
  }
end

local function approval(value)
  return {
    schema = project_profile.schemas.approval,
    approval_id = "approval-example-project-1",
    canonicalization = project_profile.canonicalization,
    profile_sha256 = project_profile.profile_sha256(value, fake_sha256),
    repository = copy(value.repository),
    authority = { kind = "host-policy", ref = "testing/project-profile" },
    policy_revision = "policy-revision-7",
    evidence_ref = { kind = "signed-attestation", ref = "approvals/example-project/1" },
    issued_at = "2026-07-16T00:00:00Z",
    expires_at = "2026-07-16T01:00:00Z",
    max_uses = 1,
    trace_id = "trace-example-project-1",
    dedup_key = "example-project-1",
  }
end

local function trusted_authority(options)
  local opts = options or {}
  return {
    source_ref = { kind = "host-policy", ref = "testing/project-profile" },
    policy_revision = "policy-revision-7",
    verify = function(request)
      if opts.reject then return { authenticated = false } end
      local artifact = request.approval
      return {
        authenticated = true,
        approval_sha256 = opts.foreign_digest or request.approval_sha256,
        authority = copy(artifact.authority),
        policy_revision = artifact.policy_revision,
        evidence_ref = copy(artifact.evidence_ref),
      }
    end,
  }
end

local function receipt_context(now, authorities)
  return {
    now = now or "2026-07-16T00:00:30Z",
    sha256 = fake_sha256,
    trusted_authorities = authorities or { trusted_authority() },
    approval_ref = { kind = "host-artifact", ref = ".testing/approvals/example-project-1.json" },
  }
end

local function replay_guard()
  local claimed = {}
  return function(request)
    local key = request.approval_id .. "\0" .. request.dedup_key
    if claimed[key] then return { claimed = false, claim_id = "claim-replayed" } end
    claimed[key] = true
    return { claimed = true, claim_id = "claim-example-project-1" }
  end
end

local function execution_context(now, guard, authorities)
  local context = receipt_context(now, authorities)
  context.replay_guard = guard or replay_guard()
  return context
end

local function validation_receipt(value, artifact, now)
  return project_profile.issue_validation_receipt(value, artifact, receipt_context(now))
end

local function attempt_target_effect(value, artifact, receipt, context)
  local effects = 0
  local ok = pcall(function()
    local authorized_profile = project_profile.authorize_execution(value, artifact, receipt, context)
    t.eq(authorized_profile.repository.commit_sha, value.repository.commit_sha)
    effects = effects + 1
  end)
  return ok, effects
end

return {
  test_accepts_canonical_profile_and_authenticated_single_use_approval = function()
    local value = profile()
    local artifact = approval(value)
    local receipt = validation_receipt(value, artifact)
    local authorized = project_profile.authorize_execution(value, artifact, receipt, execution_context())
    t.eq(receipt.schema, project_profile.schemas.validation_receipt)
    t.eq(receipt.profile_sha256, artifact.profile_sha256)
    t.eq(receipt.repository.commit_sha, commit_sha)
    t.eq(receipt.approval_ref.ref, ".testing/approvals/example-project-1.json")
    t.eq(receipt.authority.ref, "testing/project-profile")
    t.eq(receipt.trace_id, artifact.trace_id)
    t.eq(receipt.dedup_key, artifact.dedup_key)
    t.eq(authorized.commands.start[1], "node")
    t.eq(authorized == value, false)
    t.eq(receipt.secret_refs, nil)
  end,

  test_canonicalization_is_stable_and_profile_changes_change_the_digest = function()
    local first = profile()
    local second = copy(first)
    t.eq(project_profile.canonicalize_profile(first), project_profile.canonicalize_profile(second))
    t.eq(project_profile.profile_sha256(first, fake_sha256), project_profile.profile_sha256(second, fake_sha256))
    second.commands.build[3] = "build:ci"
    t.eq(project_profile.profile_sha256(first, fake_sha256) == project_profile.profile_sha256(second, fake_sha256), false)
    t.eq(#project_profile.approval_sha256(approval(first), fake_sha256), 64)
  end,

  test_valid_but_unapproved_profile_fails_without_target_effect = function()
    local value = profile()
    local artifact = approval(value)
    local effects = 0
    t.raises(function()
      project_profile.issue_validation_receipt(value, artifact, receipt_context(nil, {}))
      effects = effects + 1
    end)
    t.eq(effects, 0)
  end,

  test_unknown_authority_fails_without_target_effect = function()
    local value = profile()
    local artifact = approval(value)
    artifact.authority.ref = "testing/unknown-policy"
    local effects = 0
    t.raises(function()
      project_profile.issue_validation_receipt(value, artifact, receipt_context())
      effects = effects + 1
    end)
    t.eq(effects, 0)
  end,

  test_source_ref_matching_without_authenticated_digest_is_not_approval = function()
    local value = profile()
    local artifact = approval(value)
    local effects = 0
    t.raises(function()
      project_profile.issue_validation_receipt(value, artifact, receipt_context(nil, {
        trusted_authority({ foreign_digest = string.rep("f", 64) }),
      }))
      effects = effects + 1
    end)
    t.eq(effects, 0)
  end,

  test_altered_profile_fails_at_point_of_use_before_target_effect = function()
    local value = profile()
    local artifact = approval(value)
    local receipt = validation_receipt(value, artifact)
    value.commands.start[2] = "other-server.js"
    local ok, effects = attempt_target_effect(value, artifact, receipt, execution_context())
    t.eq(ok, false)
    t.eq(effects, 0)
  end,

  test_digest_mismatch_fails_before_receipt_or_target_effect = function()
    local value = profile()
    local artifact = approval(value)
    artifact.profile_sha256 = string.rep("f", 64)
    local effects = 0
    t.raises(function()
      project_profile.issue_validation_receipt(value, artifact, receipt_context())
      effects = effects + 1
    end)
    t.eq(effects, 0)
  end,

  test_repository_and_commit_mismatches_fail_closed = function()
    local value = profile()
    local artifact = approval(value)
    artifact.repository.url = "https://github.com/ChronoAIProject/foreign-project.git"
    local effects = 0
    t.raises(function()
      project_profile.issue_validation_receipt(value, artifact, receipt_context())
      effects = effects + 1
    end)
    t.eq(effects, 0)

    artifact = approval(value)
    artifact.repository.commit_sha = string.rep("b", 40)
    t.raises(function()
      project_profile.issue_validation_receipt(value, artifact, receipt_context())
      effects = effects + 1
    end)
    t.eq(effects, 0)
  end,

  test_stale_receipt_fails_at_point_of_use_before_target_effect = function()
    local value = profile()
    local artifact = approval(value)
    local receipt = validation_receipt(value, artifact, "2026-07-16T00:00:30Z")
    local ok, effects = attempt_target_effect(
      value,
      artifact,
      receipt,
      execution_context("2026-07-16T00:03:00Z")
    )
    t.eq(ok, false)
    t.eq(effects, 0)
  end,

  test_foreign_approval_pointer_receipt_fails_before_target_effect = function()
    local value = profile()
    local artifact = approval(value)
    local receipt = validation_receipt(value, artifact)
    receipt.approval_ref.ref = ".testing/approvals/foreign.json"
    local ok, effects = attempt_target_effect(value, artifact, receipt, execution_context())
    t.eq(ok, false)
    t.eq(effects, 0)
  end,

  test_missing_or_mis_scoped_approval_fails_before_target_effect = function()
    local value = profile()
    local artifact = approval(value)
    local receipt = validation_receipt(value, artifact)
    local ok, effects = attempt_target_effect(value, nil, receipt, execution_context())
    t.eq(ok, false)
    t.eq(effects, 0)

    artifact.trace_id = "trace-foreign-campaign"
    ok, effects = attempt_target_effect(value, artifact, receipt, execution_context())
    t.eq(ok, false)
    t.eq(effects, 0)
  end,

  test_replay_guard_allows_one_effect_and_rejects_replay = function()
    local value = profile()
    local artifact = approval(value)
    local receipt = validation_receipt(value, artifact)
    local guard = replay_guard()
    local context = execution_context(nil, guard)
    local effects = 0
    local first = project_profile.authorize_execution(value, artifact, receipt, context)
    t.eq(first.revision, value.revision)
    effects = effects + 1
    t.raises(function()
      project_profile.authorize_execution(value, artifact, receipt, context)
      effects = effects + 1
    end)
    t.eq(effects, 1)
  end,

  test_rejects_shell_strings_sparse_lists_unsupported_fields_and_unsafe_paths = function()
    local value = profile()
    value.commands.install = "npm ci"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.commands.install[3] = "--ignore-scripts"
    value.commands.install[2] = nil
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.commands.start = { "sh", "-c", "node server.js" }
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.commands.start = { "env", "NODE_ENV=test", "bash", "-c", "node server.js" }
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.working_directory = "../foreign"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.working_directory = "/tmp/foreign"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.extra = true
    t.raises(function() project_profile.validate_profile(value) end)
  end,

  test_rejects_credentials_secret_values_mutable_refs_and_unbounded_values = function()
    local value = profile()
    value.repository.url = "https://user:password@github.com/ChronoAIProject/example-project.git"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.readiness_checks[1].url = "http://user:password@127.0.0.1:4173/health"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.commands.start = { "node", "server.js", "--token=raw-secret" }
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.commands.start = { "node", "server.js", "--password", "raw-secret" }
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.secret_refs[1].value = "raw-secret"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.secret_refs[1].type = "literal"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.secret_refs[1].source_ref.kind = "literal"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.secret_refs[1].name = "INVALID-NAME"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.repository.commit_sha = "main"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.timeouts.total_seconds = 14401
    t.raises(function() project_profile.validate_profile(value) end)
  end,

  test_rejects_malformed_origins_services_readiness_and_mutation_policies = function()
    local value = profile()
    value.allowed_origins = {}
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.secret_refs = {}
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.dependent_services = {}
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.readiness_checks = {}
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.readiness_checks[2].url = "http://127.0.0.1:4173/health"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.readiness_checks[1].host = "127.0.0.1"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.dependent_services[1].readiness_checks[1].host = "invalid host"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.mutation_policy = { mode = "read-only", cleanup_required = true }
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.mutation_policy.allowed_operations = {}
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.mutation_policy.cleanup_required = false
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.mutation_policy = { mode = "unbounded" }
    t.raises(function() project_profile.validate_profile(value) end)
  end,

  test_rejects_noncanonical_urls_and_accepts_bracketed_ipv6_origins = function()
    local value = profile()
    value.readiness_checks[1].url = "http://127.0.0.1:4173/health?token-reference=omitted"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.readiness_checks[1].url = "http://127.0.0.1:4173/unsafe\\path"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.repository.url = "https://github.com/ChronoAIProject/example!project.git"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.repository.url = "https://github.com/ChronoAIProject/example-project.git/"
    t.raises(function() project_profile.validate_profile(value) end)

    value = profile()
    value.allowed_origins = { "http://[::1]:4173" }
    value.readiness_checks[1].url = "http://[::1]:4173/health"
    t.eq(project_profile.validate_profile(value).allowed_origins[1], "http://[::1]:4173")

    value = profile()
    value.working_directory = "apps/web"
    t.eq(project_profile.validate_profile(value).working_directory, "apps/web")
  end,

  test_rejects_stale_approval_missing_replay_guard_and_replayable_approval = function()
    local value = profile()
    local artifact = approval(value)
    artifact.max_uses = 2
    t.raises(function() project_profile.validate_approval(artifact) end)

    artifact = approval(value)
    artifact.profile_sha256 = "invalid"
    t.raises(function() project_profile.validate_approval(artifact) end)

    t.raises(function() project_profile.profile_sha256(value, function() return "invalid" end) end)

    artifact = approval(value)
    artifact.expires_at = artifact.issued_at
    t.raises(function() project_profile.validate_approval(artifact) end)

    artifact = approval(value)
    artifact.expires_at = "2026-07-17T00:00:01Z"
    t.raises(function() project_profile.validate_approval(artifact) end)

    artifact = approval(value)
    local broken_authority = trusted_authority()
    broken_authority.verify = function() error("fixture verifier failure") end
    t.raises(function()
      project_profile.issue_validation_receipt(value, artifact, receipt_context(nil, { broken_authority }))
    end)

    local empty_authority = trusted_authority()
    empty_authority.verify = function() return nil end
    t.raises(function()
      project_profile.issue_validation_receipt(value, artifact, receipt_context(nil, { empty_authority }))
    end)

    artifact = approval(value)
    t.raises(function()
      project_profile.issue_validation_receipt(
        value,
        artifact,
        receipt_context("2026-07-16T01:00:00Z")
      )
    end)

    artifact = approval(value)
    local receipt = validation_receipt(value, artifact)
    local stale_receipt = copy(receipt)
    stale_receipt.profile_revision = "foreign-profile-revision"
    local ok, effects = attempt_target_effect(value, artifact, stale_receipt, execution_context())
    t.eq(ok, false)
    t.eq(effects, 0)

    local context = receipt_context()
    context.replay_guard = nil
    t.raises(function() project_profile.authorize_execution(value, artifact, receipt, context) end)
  end,
}
