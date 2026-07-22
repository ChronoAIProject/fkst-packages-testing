local contract = require("contract.environment_factory")
local project_profile = require("contract.project_profile")
local t = fkst.test

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function request()
  return {
    schema = contract.schemas.start,
    operation_id = "contract-fixture",
    repository = { url = "https://example.invalid/testing/fixture.git", commit_sha = string.rep("a", 40) },
    profile_ref = { kind = "host-profile", ref = "fixtures/profile" },
    approval_ref = { kind = "host-artifact", ref = ".testing/approvals/fixture.json" },
    validation_receipt_ref = { kind = "artifact", ref = ".testing/approvals/fixture.receipt.json" },
    operation_state_ref = { kind = "artifact", ref = ".testing/runs/contract-fixture/operation-state.json" },
    artifact_root = ".testing/runs/contract-fixture",
    base_url = "http://127.0.0.1:4173/health",
    runtime_ports = { { name = "application", port = 4173 } },
    sessions = { { role = "browser", cdp_url = "http://[::1]:9222" } },
    trace_id = "trace-contract-fixture",
    dedup_key = "dedup-contract-fixture",
  }
end

local function profile(fixture_scoped)
  return {
    schema = project_profile.schemas.profile,
    revision = "contract-profile",
    repository = { url = "https://example.invalid/testing/fixture.git", commit_sha = string.rep("a", 40) },
    working_directory = ".",
    commands = { start = { "fixture", "start" }, cleanup = { "fixture", "cleanup" } },
    application_listener_mode = project_profile.listener_mode,
    readiness_checks = { { type = "http", url = "http://127.0.0.1:4173/health", expected_status = 200 } },
    allowed_origins = { "http://127.0.0.1:4173" },
    mutation_policy = fixture_scoped and { mode = "fixture-scoped", allowed_operations = { "create" }, cleanup_required = true } or { mode = "read-only" },
    timeouts = {
      install_seconds = 1, build_seconds = 1, migrate_seconds = 1, seed_seconds = 1,
      start_seconds = 10, readiness_seconds = 10, cleanup_seconds = 10, total_seconds = 60,
      receipt_ttl_seconds = 10,
    },
    resource_budgets = { cpu_millis = 100, memory_mb = 64, disk_mb = 64, processes = 1, network_requests = 0, output_bytes = 1024 },
  }
end

local function expect_start_failure(mutator)
  local value = request()
  mutator(value)
  t.raises(function() contract.validate_start(value) end)
end

local function readiness_correlation()
  return {
    schema = contract.schemas.readiness_correlation,
    attempt_id = "attempt",
    operation_id = "op",
    operation_state_ref = { kind = "artifact", ref = ".testing/runs/op/operation-state.json" },
    readiness_attempt_ref = { kind = "artifact", ref = ".testing/runs/op/readiness-attempts/attempt.json" },
    readiness_attempt_sha256 = string.rep("a", 64),
    base_url = "http://127.0.0.1:4173/health",
    sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
    trace_id = "trace",
    dedup_key = "dedup",
  }
end

local function browser_result()
  return {
    schema = "browser-readiness.result.v1",
    status = "ready",
    sessions = {
      { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
      { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } }, cdp_url = "http://127.0.0.1:9222" },
    },
    source_ref = { kind = "artifact", ref = ".testing/runs/op/operation-state.json" },
    request_context = { dry_run = false },
    correlation = readiness_correlation(),
  }
end

local function ready_receipt()
  return {
    schema = contract.schemas.receipt,
    operation_id = "op",
    status = "ready",
    profile_revision = "profile-1",
    profile_sha256 = string.rep("b", 64),
    repository = { url = "https://example.invalid/testing/fixture.git", commit_sha = string.rep("a", 40) },
    workspace_ref = { kind = "workspace", ref = "op-workspace" },
    base_url = "http://127.0.0.1:4173/health",
    runtime_ports = { { name = "application", port = 4173 } },
    sessions = { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
    browser_readiness = browser_result(),
    artifact_root = ".testing/runs/op",
    diagnostic_refs = {},
    cleanup_ref = { kind = "environment-cleanup", ref = "op" },
    cleanup_status = "pending",
    trace_id = "trace",
    dedup_key = "dedup",
  }
end

local function cleanup_receipt()
  return {
    schema = contract.schemas.cleanup_receipt,
    operation_id = "contract-fixture",
    status = "complete",
    attempted_resources = {
      {
        resource_id = "workspace",
        resource_kind = "workspace",
        status = "cleaned",
        diagnostic_ref = { kind = "artifact", ref = ".testing/runs/contract-fixture/diagnostics/cleanup-workspace.json" },
      },
    },
    verified_removals = { "workspace" },
    remaining_resources = {},
    artifact_root = ".testing/runs/contract-fixture",
    trace_id = "trace-contract-fixture",
    dedup_key = "dedup-contract-fixture",
  }
end

return {
  test_exported_pointer_copy_is_closed = function()
    local copied = contract.copy_ref({ kind = "artifact", ref = ".testing/runs/x.json", ignored = true })
    t.eq(copied.kind, "artifact")
    t.eq(copied.ref, ".testing/runs/x.json")
    t.eq(copied.ignored, nil)
    local value = request()
    value.profile_ref = { kind = "host-profile" }
    t.raises(function() contract.validate_start(value) end)
  end,

  test_start_validation_negative_matrix = function()
    local cases = {
      function(v) v.extra = true end,
      function(v) v.schema = "other" end,
      function(v) v.operation_id = "bad id" end,
      function(v) v.repository.url = "http://example.invalid/repo" end,
      function(v) v.repository.commit_sha = "abc" end,
      function(v) v.profile_ref = "bad" end,
      function(v) v.profile_ref.ref = "token=value" end,
      function(v) v.validation_receipt_ref.ref = "outside.json" end,
      function(v) v.artifact_root = "outside" end,
      function(v) v.operation_state_ref.ref = ".testing/runs/other/state.json" end,
      function(v) v.base_url = "https://example.invalid/health" end,
      function(v) v.runtime_ports = {} end,
      function(v) v.runtime_ports[2] = { name = "duplicate", port = 4173 } end,
      function(v) v.runtime_ports[2] = { name = "application", port = 4311 } end,
      function(v) v.runtime_ports[1].port = 70000 end,
      function(v) v.sessions = {} end,
      function(v) v.sessions[1].role = "bad role" end,
      function(v) v.sessions[1] = { role = "missing" } end,
      function(v) v.sessions[1] = { role = "env", cdp_endpoint_env = "bad-env" } end,
      function(v) v.sessions[1].cdp_url = "http://example.invalid:9222" end,
      function(v) v.sessions[1].extra = "body" end,
      function(v) v.trace_id = "bad trace" end,
    }
    for _, mutate in ipairs(cases) do expect_start_failure(mutate) end
    t.raises(function() contract.validate_start(nil) end)
  end,

  test_profile_binding_and_start_binding_are_closed = function()
    local value = request()
    contract.validate_profile_binding(value, profile(false))
    local first = contract.start_binding(value)
    local second = contract.start_binding(copy(value))
    t.eq(contract.same_start_binding(first, second), true)
    second.request.sessions[1].role = "changed"
    t.eq(contract.same_start_binding(first, second), false)
    local foreign = profile(false)
    foreign.repository.commit_sha = string.rep("b", 40)
    t.raises(function() contract.validate_profile_binding(value, foreign) end)
    local bad_base = copy(value)
    bad_base.base_url = "http://127.0.0.1:4173/other"
    t.raises(function() contract.validate_profile_binding(bad_base, profile(false)) end)
  end,

  test_supervised_port_subsets_are_derived_from_readiness_and_reject_ambiguity = function()
    local value = profile(false)
    value.dependent_services = { {
      name = "state-service",
      listener_mode = project_profile.listener_mode,
      start_argv = { "fixture", "service" },
      cleanup_argv = { "fixture", "service-cleanup" },
      readiness_checks = { { type = "http", url = "http://127.0.0.1:4311/ready", expected_status = 200 } },
    } }
    local assignments = contract.supervised_port_assignments(value, {
      { name = "application", port = 4173 },
      { name = "state-service", port = 4311 },
    })
    t.eq(#assignments.application, 1)
    t.eq(assignments.application[1].port, 4173)
    t.eq(#assignments.services[1], 1)
    t.eq(assignments.services[1][1].port, 4311)

    value.readiness_checks[2] = { type = "tcp", host = "127.0.0.1", port = 4311 }
    t.raises(function()
      contract.supervised_port_assignments(value, {
        { name = "application", port = 4173 },
        { name = "state-service", port = 4311 },
      })
    end)
  end,

  test_finalize_interrupt_and_result_negative_matrix = function()
    local finalize = {
      schema = contract.schemas.finalize, operation_id = "op",
      cleanup_ref = { kind = "cleanup", ref = "op" },
      operation_state_ref = { kind = "artifact", ref = ".testing/runs/op/operation-state.json" },
      trace_id = "trace", dedup_key = "dedup",
    }
    contract.validate_finalize(finalize)
    local interrupt = copy(finalize)
    interrupt.schema = contract.schemas.interrupt
    interrupt.interruption = "cancelled"
    contract.validate_interrupt(interrupt)
    interrupt.interruption = "unknown"
    t.raises(function() contract.validate_interrupt(interrupt) end)

    local result = {
      schema = contract.schemas.result, operation_id = "op", status = "ready",
      environment_receipt_ref = { kind = "artifact", ref = ".testing/runs/op/environment-receipt-ready.json" },
      cleanup_ref = { kind = "cleanup", ref = "op" }, diagnostic_refs = {}, cleanup_status = "pending",
      source_ref = { kind = "artifact", ref = ".testing/runs/op/operation-state.json" },
      trace_id = "trace", dedup_key = "dedup",
    }
    contract.validate_result(result)
    for _, mutate in ipairs({
      function(v) v.status = "unknown" end,
      function(v) v.environment_receipt_ref.ref = ".testing/runs/op/environment-receipt-finalized.json" end,
      function(v) v.cleanup_status = "unknown" end,
      function(v) v.diagnostic_refs = {}; for i = 1, contract.max_diagnostic_refs + 1 do v.diagnostic_refs[i] = { kind = "artifact", ref = ".testing/runs/op/d" .. i .. ".json" } end end,
    }) do local changed = copy(result); mutate(changed); t.raises(function() contract.validate_result(changed) end) end

    local terminal = copy(result)
    terminal.status = "finalized"
    terminal.environment_receipt_ref.ref = ".testing/runs/op/environment-receipt-finalized.json"
    terminal.cleanup_status = "complete"
    terminal.cleanup_receipt_ref = { kind = "artifact", ref = ".testing/runs/op/cleanup-receipt-complete.json" }
    contract.validate_result(terminal)
    terminal.cleanup_receipt_ref.ref = ".testing/runs/op/cleanup-receipt-incomplete.json"
    t.raises(function() contract.validate_result(terminal) end)

    local premature = copy(result)
    premature.cleanup_receipt_ref = { kind = "artifact", ref = ".testing/runs/op/cleanup-receipt-pending.json" }
    t.raises(function() contract.validate_result(premature) end)
  end,

  test_readiness_browser_result_and_ready_result_failure_matrix = function()
    local bad_correlation = readiness_correlation()
    bad_correlation.schema = "other"
    t.raises(function() contract.validate_readiness_correlation(bad_correlation) end)
    bad_correlation = readiness_correlation()
    bad_correlation.readiness_attempt_sha256 = string.rep("A", 64)
    t.raises(function() contract.validate_readiness_correlation(bad_correlation) end)

    local browser_mutations = {
      function(v) v.sessions[1].checks[1].status = "planned" end,
      function(v) v.sessions[1].checks[1].reason = string.rep("x", 257) end,
      function(v) v.sessions[1].checks[1].reason = "token=value" end,
      function(v) v.status = "planned" end,
      function(v) v.request_context.dry_run = true end,
      function(v) v.sessions = { [2] = v.sessions[1] } end,
      function(v) v.sessions[1].status = "planned" end,
      function(v) v.sessions[1].status = "blocked" end,
      function(v) v.sessions[1].checks[1].status = "blocked" end,
      function(v) v.sessions[2].cdp_url = "http://127.0.0.1:9222/devtools/token=value" end,
      function(v) v.correlation.sessions[1].cdp_url = "http://127.0.0.1:9222/devtools/password=value" end,
    }
    for _, mutate in ipairs(browser_mutations) do
      local value = browser_result()
      mutate(value)
      t.raises(function() contract.sanitize_browser_readiness_result(value) end)
    end

    local non_pointer_result = {
      schema = contract.schemas.result,
      operation_id = "op",
      status = "ready",
      base_url = "http://127.0.0.1:4173/health",
      environment_receipt_ref = { kind = "artifact", ref = ".testing/runs/op/environment-receipt-ready.json" },
      cleanup_ref = { kind = "cleanup", ref = "op" },
      diagnostic_refs = {},
      cleanup_status = "pending",
      trace_id = "trace",
      dedup_key = "dedup",
    }
    t.raises(function() contract.validate_result(non_pointer_result) end)
  end,

  test_ready_receipt_v2_binds_canonical_repository_and_browser_proof = function()
    local value = ready_receipt()
    contract.validate_receipt(value)
    t.eq(value.schema, "environment-factory.receipt.v2")
    t.eq(value.repository.commit_sha, string.rep("a", 40))
    t.eq(value.repository.resolved_commit, nil)
    t.eq(value.browser_readiness.status, "ready")
    for _, mutate in ipairs({
      function(v) v.repository.resolved_commit = v.repository.commit_sha end,
      function(v) v.repository.commit_sha = nil end,
      function(v) v.browser_readiness = nil end,
      function(v) v.browser_readiness.correlation.operation_id = "foreign" end,
      function(v) v.cleanup_receipt_ref = { kind = "artifact", ref = ".testing/runs/op/cleanup-receipt-pending.json" } end,
      function(v) v.profile_sha256 = string.rep("A", 64) end,
      function(v) v.artifact_root = "outside" end,
      function(v) v.diagnostic_refs = { [2] = { kind = "artifact", ref = ".testing/runs/op/diagnostic.json" } } end,
      function(v) v.cleanup_status = "unknown" end,
      function(v) v.extra = true end,
    }) do
      local malformed = ready_receipt()
      mutate(malformed)
      t.raises(function() contract.validate_receipt(malformed) end)
    end
    local terminal = ready_receipt()
    terminal.status = "finalized"
    terminal.cleanup_status = "complete"
    terminal.cleanup_receipt_ref = {
      kind = "artifact", ref = ".testing/runs/op/cleanup-receipt-incomplete.json",
    }
    t.raises(function() contract.validate_receipt(terminal) end)
  end,

  test_runtime_outcome_validation_matrix = function()
    contract.validate_runtime_outcome({ status = "passed" }, "fixture")
    contract.validate_runtime_outcome({ status = "running", early_exit = false, frozen_dependencies_enforced = true }, "fixture")
    for _, value in ipairs({
      { status = "unknown" },
      { status = "passed", stdout = "body" },
      { status = "running", early_exit = "no" },
      { status = "passed", frozen_dependencies_enforced = "yes" },
      { status = "passed", diagnostic_ref = { kind = "artifact", ref = "outside" } },
      { status = "passed", cleanup_ref = { kind = "cleanup", ref = "token=value" } },
      { status = "passed", runtime_ports = {} },
    }) do t.raises(function() contract.validate_runtime_outcome(value, "fixture") end) end
  end,

  test_cleanup_receipt_contract_is_typed_bounded_and_pointer_only = function()
    contract.validate_cleanup_receipt(cleanup_receipt())
    for _, mutate in ipairs({
      function(v) v.schema = "other" end,
      function(v) v.status = "unknown" end,
      function(v) v.attempted_resources = {} end,
      function(v) v.attempted_resources[1].resource_id = "bad id" end,
      function(v) v.attempted_resources[1].status = "unknown" end,
      function(v) v.attempted_resources[1].diagnostic_ref.ref = "outside.json" end,
      function(v) v.verified_removals = { "foreign" } end,
      function(v) v.verified_removals = { [2] = "workspace" } end,
      function(v) v.remaining_resources = { [2] = {
        resource_id = "workspace", resource_kind = "workspace",
        cleanup_ref = { kind = "resource-cleanup", ref = "workspace" },
      } } end,
      function(v) v.status = "incomplete"; v.attempted_resources[1].status = "remaining"; v.verified_removals = {} end,
      function(v) v.status = "complete"; v.attempted_resources[1].status = "remaining"; v.verified_removals = {}; v.remaining_resources = { {
        resource_id = "workspace", resource_kind = "workspace",
        cleanup_ref = { kind = "resource-cleanup", ref = "workspace" },
      } } end,
      function(v) v.artifact_root = "outside" end,
      function(v) v.remaining_resources = { {
        resource_id = "workspace", resource_kind = "workspace",
        cleanup_ref = { kind = "resource-cleanup", ref = "token=value" },
      } } end,
      function(v) v.secret = "inline" end,
    }) do
      local malformed = cleanup_receipt()
      mutate(malformed)
      t.raises(function() contract.validate_cleanup_receipt(malformed) end)
    end
  end,
}
