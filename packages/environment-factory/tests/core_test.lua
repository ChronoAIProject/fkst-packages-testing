local core = require("core")
local conformance = require("conformance")
local environment_contract = require("contract.environment_factory")
local project_profile = require("contract.project_profile")
local t = fkst.test

local commit_sha = string.rep("a", 40)

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

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

local function profile(options)
  local opts = options or {}
  local services = {}
  for index = 1, (opts.service_count or 1) do
    table.insert(services, {
      name = "fixture-service-" .. index,
      listener_mode = project_profile.listener_mode,
      start_argv = { "fixture-service", "start", "--port", tostring(6300 + index) },
      cleanup_argv = { "fixture-service", "stop", "--port", tostring(6300 + index) },
      readiness_checks = { { type = "tcp", host = "127.0.0.1", port = 6300 + index } },
    })
  end
  return {
    schema = project_profile.schemas.profile,
    revision = "environment-fixture-1",
    repository = { url = "https://example.invalid/testing/environment-fixture.git", commit_sha = commit_sha },
    working_directory = ".",
    commands = {
      install = { "fixture-package-manager", "install" },
      build = { "fixture-runtime", "build" },
      migrate = { "fixture-runtime", "migrate" },
      seed = { "fixture-runtime", "seed" },
      start = { "fixture-runtime", "serve", "--port", "4173" },
      cleanup = { "fixture-runtime", "stop", "--port", "4173" },
    },
    application_listener_mode = project_profile.listener_mode,
    dependent_services = services,
    readiness_checks = {
      { type = "http", url = "http://127.0.0.1:4173/health", expected_status = 200 },
      { type = "argv", argv = { "fixture-runtime", "verify" } },
    },
    allowed_origins = { "http://127.0.0.1:4173" },
    secret_refs = {
      { name = "FIXTURE_DATA_SOURCE", type = "secret-reference", source_ref = { kind = "host-secret", ref = "fixtures/environment/data-source" } },
    },
    mutation_policy = opts.fixture_scoped and {
      mode = "fixture-scoped", allowed_operations = { "create", "update", "delete" }, cleanup_required = true,
    } or { mode = "read-only" },
    timeouts = {
      install_seconds = 10, build_seconds = 10, migrate_seconds = 10, seed_seconds = 10,
      start_seconds = 10, readiness_seconds = 10, cleanup_seconds = 10, total_seconds = 120,
      receipt_ttl_seconds = 60,
    },
    resource_budgets = {
      cpu_millis = 1000, memory_mb = 512, disk_mb = 1024, processes = 32,
      network_requests = 100, output_bytes = 65536,
    },
  }
end

local function approval(value, operation_id)
  return {
    schema = project_profile.schemas.approval,
    approval_id = operation_id .. "-approval",
    canonicalization = project_profile.canonicalization,
    profile_sha256 = project_profile.profile_sha256(value, fake_sha256),
    repository = copy(value.repository),
    authority = { kind = "host-policy", ref = "fixtures/environment-profile" },
    policy_revision = "fixture-policy-1",
    evidence_ref = { kind = "signed-attestation", ref = "fixtures/" .. operation_id .. "-approval" },
    issued_at = "2026-07-16T00:00:00Z", expires_at = "2026-07-16T01:00:00Z", max_uses = 1,
    trace_id = "trace-" .. operation_id, dedup_key = operation_id,
  }
end

local function authority(reject)
  return {
    source_ref = { kind = "host-policy", ref = "fixtures/environment-profile" },
    policy_revision = "fixture-policy-1",
    verify = function(request)
      if reject then return { authenticated = false } end
      return {
        authenticated = true, approval_sha256 = request.approval_sha256,
        authority = copy(request.approval.authority), policy_revision = request.approval.policy_revision,
        evidence_ref = copy(request.approval.evidence_ref),
      }
    end,
  }
end

local function fixture(options)
  local opts = options or {}
  local operation_id = opts.operation_id or "environment-fixture-1"
  local value = profile(opts)
  local artifact = approval(value, operation_id)
  local approval_ref = { kind = "host-artifact", ref = ".testing/approvals/" .. operation_id .. ".json" }
  local receipt_context = {
    now = "2026-07-16T00:00:30Z", sha256 = fake_sha256,
    trusted_authorities = { authority(false) }, approval_ref = approval_ref,
  }
  local validation_receipt = project_profile.issue_validation_receipt(value, artifact, receipt_context)
  local claims = 0
  local context = copy(receipt_context)
  context.trusted_authorities = { authority(opts.reject_authority) }
  context.sha256 = fake_sha256
  context.replay_guard = function()
    claims = claims + 1
    if claims > 1 then return { claimed = false, claim_id = "claim-replayed" } end
    return { claimed = true, claim_id = "claim-" .. operation_id }
  end
  local root = ".testing/runs/" .. operation_id
  local runtime_ports = { { name = "application", port = 4173 } }
  for index = 1, #value.dependent_services do table.insert(runtime_ports, { name = "service-" .. index, port = 6300 + index }) end
  local request = {
    schema = environment_contract.schemas.start, operation_id = operation_id, repository = copy(value.repository),
    profile_ref = { kind = "host-profile", ref = "fixtures/" .. operation_id .. "-profile" },
    approval_ref = approval_ref,
    validation_receipt_ref = { kind = "artifact", ref = ".testing/approvals/" .. operation_id .. ".receipt.json" },
    operation_state_ref = { kind = "artifact", ref = root .. "/operation-state.json" },
    artifact_root = root, base_url = "http://127.0.0.1:4173/health", runtime_ports = runtime_ports,
    sessions = opts.sessions or { { role = "browser", cdp_url = "http://127.0.0.1:9222" } },
    testing = { module = "fixture-module", artifact_root = root .. "/testing", mutation_policy = opts.testing_mutation or "read-only" },
    trace_id = artifact.trace_id, dedup_key = artifact.dedup_key,
  }
  return { profile = value, approval = artifact, receipt = validation_receipt, context = context, request = request, claims = function() return claims end }
end

local function fake_runtime(fx, options, shared)
  local opts = options or {}
  local shared_state = shared or { port_owners = {} }
  local states, state_auth, state_revisions, calls, effect_cache, cleanup_order, receipts = {}, {}, {}, {}, {}, {}, {}
  local target_effects, active, executed_argv, supervised_ports, readiness_owners, save_calls = 0, {}, {}, {}, {}, 0
  local function record(value) table.insert(calls, value) end
  local function cached(effect, produce)
    if effect_cache[effect] == nil then effect_cache[effect] = copy(produce()) end
    return copy(effect_cache[effect])
  end
  local function assert_budget(request)
    t.eq(request.resource_budgets.output_bytes, fx.profile.resource_budgets.output_bytes)
    t.eq(request.output_bytes, fx.profile.resource_budgets.output_bytes)
    t.eq(request.deadline_epoch_seconds, 2000000000)
    local expected_remaining = opts.remaining_seconds or 120
    if opts.invalid_remaining_budget and request.effect_id:find("/cleanup/", 1, true) ~= nil then
      expected_remaining = 0
    end
    t.eq(request.remaining_seconds, expected_remaining)
    t.is_true(request.phase_timeout_seconds >= 1)
    t.is_true(request.timeout_seconds >= 1)
  end
  local function effect_label(request)
    return request.effect_id:match("/phase/([^/]+)$")
      or (request.effect_id:match("/service/%d+/start$") and "service-start")
      or (request.effect_id:match("/application/start$") and "application-start") or "unknown"
  end
  local ports = {
    load_state = function(ref)
      if states[ref.ref] == nil then return nil end
      return {
        authenticated = state_auth[ref.ref] ~= false,
        state = copy(states[ref.ref]),
        revision = state_revisions[ref.ref],
      }
    end,
    save_state = function(ref, value, expected_revision)
      save_calls = save_calls + 1
      if opts.fail_save == true or (type(opts.fail_save_after) == "number" and save_calls > opts.fail_save_after) then
        return false
      end
      local current = state_revisions[ref.ref] or 0
      if expected_revision ~= current then return { saved = false, stale = true, revision = current } end
      states[ref.ref] = copy(value)
      state_revisions[ref.ref] = current + 1
      if state_auth[ref.ref] == nil then state_auth[ref.ref] = true end
      if opts.save_returns_true then return true end
      return { saved = true, revision = state_revisions[ref.ref] }
    end,
    load_authorization_bundle = function()
      if opts.bundle_mode == "missing" then return nil end
      local receipt = copy(fx.receipt)
      if opts.bundle_mode == "bad-receipt" then receipt.schema = "other" end
      if opts.bundle_mode == "scope" then receipt.trace_id = "foreign" end
      return { profile = fx.profile, approval = fx.approval, receipt = receipt, context = fx.context }
    end,
    authorize_claim_ports = function(request)
      return cached(request.effect_id, function()
        record("authorize")
        local snapshot = request.authorize()
        record("claim-ports")
        target_effects = target_effects + 1
        for _, item in ipairs(request.runtime_ports) do
          local owner = shared_state.port_owners[item.port]
          if owner ~= nil and owner ~= request.operation_id then return { status = "blocked" } end
        end
        for _, item in ipairs(request.runtime_ports) do shared_state.port_owners[item.port] = request.operation_id end
        active.ports = true
        local outcome = {
          status = "passed", profile_snapshot = snapshot,
          cleanup_ref = { kind = "resource-cleanup", ref = request.operation_id .. "-ports" },
          runtime_ports = opts.claim_wrong_ports and { { name = "wrong", port = 4999 } } or copy(request.runtime_ports),
          deadline_epoch_seconds = opts.claim_bad_deadline and "bad" or 2000000000,
          request_binding = copy(request.request_binding),
          diagnostic_ref = { kind = "artifact", ref = fx.request.artifact_root .. "/diagnostics/port-claim.json" },
        }
        if opts.claim_extra_field then outcome.extra = true end
        if opts.claim_bad_deadline then
          for _, item in ipairs(request.runtime_ports) do
            if shared_state.port_owners[item.port] == request.operation_id then shared_state.port_owners[item.port] = nil end
          end
          active.ports = nil
        end
        return outcome
      end)
    end,
    checkout = function(request)
      assert_budget(request)
      return cached(request.effect_id, function()
        record("checkout"); target_effects = target_effects + 1
        if opts.checkout_invalid_status then return { status = "unknown" } end
        if opts.checkout_missing_metadata then return { status = "passed" } end
        active.workspace = true
        local outcome = {
          status = opts.checkout_partial and "blocked" or "passed",
          resolved_commit = opts.checkout_short_commit and "abc" or opts.resolved_commit or fx.profile.repository.commit_sha,
          workspace_ref = { kind = "workspace", ref = fx.request.operation_id .. "-workspace" },
          cleanup_ref = { kind = "resource-cleanup", ref = fx.request.operation_id .. "-workspace" },
          diagnostic_ref = { kind = "artifact", ref = fx.request.artifact_root .. "/diagnostics/checkout.json" },
        }
        if opts.checkout_extra_field then outcome.extra = true end
        return outcome
      end)
    end,
    remaining_budget = function()
      if opts.invalid_remaining_budget then return "bad" end
      return opts.remaining_seconds or 120
    end,
    create_readiness_attempt = function(request)
      assert_budget(request)
      return cached(request.effect_id, function()
        record("readiness-attempt")
        return {
          status = opts.fail_readiness_attempt and "blocked" or "passed",
          attempt_id = opts.fail_readiness_attempt and nil or fx.request.operation_id .. "-readiness-1",
          diagnostic_ref = { kind = "artifact", ref = fx.request.artifact_root .. "/diagnostics/readiness-attempt.json" },
        }
      end)
    end,
    run_argv = function(request)
      assert_budget(request)
      return cached(request.effect_id, function()
        local label = effect_label(request)
        table.insert(executed_argv, copy(request.argv)); record(label); target_effects = target_effects + 1
        if opts.fail_phase == label then
          return { status = "blocked", diagnostic_ref = { kind = "artifact", ref = fx.request.artifact_root .. "/diagnostics/" .. label .. ".json" } }
        end
        if request.mode == "supervised" then
          table.insert(supervised_ports, copy(request.runtime_ports))
          local ref = request.operation_id .. "-" .. label .. "-" .. tostring(#executed_argv)
          active[ref] = true
          local outcome = {
            status = "running", early_exit = opts.early_exit == label,
            runtime_ports = (opts.missing_runtime_ports == true or opts.missing_runtime_ports == label)
              and (label == "service-start" and { { name = "application", port = 4173 } }
                or { { name = "service-1", port = 6301 } })
              or copy(request.runtime_ports),
            cleanup_ref = { kind = "resource-cleanup", ref = ref },
            diagnostic_ref = { kind = "artifact", ref = fx.request.artifact_root .. "/diagnostics/" .. label .. "-" .. #executed_argv .. ".json" },
          }
          if opts.wrong_runtime_port_name == label then outcome.runtime_ports[1].name = "foreign-name" end
          if opts.supervised_extra_field == label then outcome.extra = true end
          return outcome
        end
        local outcome = { status = "passed", diagnostic_ref = { kind = "artifact", ref = fx.request.artifact_root .. "/diagnostics/" .. label .. ".json" } }
        if request.requires_frozen_dependencies == true then outcome.frozen_dependencies_enforced = opts.no_frozen_dependencies ~= true end
        return outcome
      end)
    end,
    wait_readiness = function(request)
      assert_budget(request)
      return cached(request.effect_id, function()
        table.insert(readiness_owners, {
          cleanup_ref = copy(request.process_cleanup_ref),
          runtime_ports = copy(request.runtime_ports),
        })
        local label = request.effect_id:match("/readiness/(.+)$")
        record("readiness-" .. label); target_effects = target_effects + 1
        return { status = opts.fail_readiness == label and "blocked" or "ready", diagnostic_ref = { kind = "artifact", ref = fx.request.artifact_root .. "/diagnostics/readiness-" .. label .. ".json" } }
      end)
    end,
    cleanup = function(request)
      assert_budget(request)
      return cached(request.effect_id, function()
        local id = request.effect_id:match("/cleanup/(.+)$")
        table.insert(cleanup_order, id); target_effects = target_effects + 1
        if id == "ports" then
          for _, item in ipairs(fx.request.runtime_ports) do if shared_state.port_owners[item.port] == fx.request.operation_id then shared_state.port_owners[item.port] = nil end end
          active.ports = nil
        elseif id == "workspace" then active.workspace = nil
        else
          for ref, _ in pairs(active) do if ref:find(id == "application" and "application-start" or "service-start", 1, true) then active[ref] = nil end end
        end
        return { status = opts.fail_cleanup == id and "blocked" or "cleaned", diagnostic_ref = { kind = "artifact", ref = fx.request.artifact_root .. "/diagnostics/cleanup-" .. id .. ".json" } }
      end)
    end,
    write_receipt = function(request)
      assert_budget(request)
      return cached(request.effect_id, function()
        record("receipt-" .. request.receipt.status)
        if opts.fail_receipts == true or (type(opts.fail_receipts) == "table" and opts.fail_receipts[request.receipt.status]) then return { status = "blocked" } end
        receipts[request.receipt_ref.ref] = copy(request.receipt)
        return { status = "passed" }
      end)
    end,
  }
  return ports, {
    calls = calls, cleanup_order = cleanup_order, receipts = receipts,
    target_effects = function() return target_effects end,
    state = function(ref) return copy(states[(ref or fx.request.operation_state_ref).ref]) end,
    set_state = function(value, authenticated)
      local ref = fx.request.operation_state_ref.ref
      states[ref] = copy(value)
      state_auth[ref] = authenticated ~= false
      if state_revisions[ref] == nil then state_revisions[ref] = 1 end
    end,
    corrupt_state = function(mutator) local value = copy(states[fx.request.operation_state_ref.ref]); mutator(value); states[fx.request.operation_state_ref.ref] = value; state_auth[fx.request.operation_state_ref.ref] = false end,
    active_count = function() local count = 0; for _, value in pairs(active) do if value then count = count + 1 end end; return count end,
    executed_argv = executed_argv, supervised_ports = supervised_ports,
    readiness_owners = readiness_owners, shared = shared_state,
  }
end

local function ready_browser_event(fx, ready)
  return {
    schema = "browser-readiness.result.v1",
    status = "ready",
    sessions = {
      { role = "base_url", status = "ready", checks = { { name = "local_http", status = "ready" } } },
      { role = "browser", status = "ready", checks = { { name = "cdp_url", status = "ready" } }, cdp_url = "http://127.0.0.1:9222" },
    },
    source_ref = copy(fx.request.operation_state_ref),
    request_context = { dry_run = false },
    correlation = copy(ready.readiness_correlation),
  }
end

local function finalize_request(fx, ready)
  return { schema = environment_contract.schemas.finalize, operation_id = fx.request.operation_id, cleanup_ref = copy(ready.cleanup_ref), operation_state_ref = copy(fx.request.operation_state_ref), trace_id = fx.request.trace_id, dedup_key = fx.request.dedup_key }
end

local function interrupt_request(fx, ready, interruption)
  return { schema = environment_contract.schemas.interrupt, operation_id = fx.request.operation_id, cleanup_ref = copy(ready.cleanup_ref), operation_state_ref = copy(fx.request.operation_state_ref), interruption = interruption, trace_id = fx.request.trace_id, dedup_key = fx.request.dedup_key }
end

local function public_text(value)
  local parts = {}
  local function walk(item)
    if type(item) == "string" then table.insert(parts, item)
    elseif type(item) == "table" then for key, nested in pairs(item) do walk(key); walk(nested) end end
  end
  walk(value)
  return table.concat(parts, "\n")
end

return {
  test_controlled_fixture_reaches_ready_handoff_and_distinct_final_receipt = function()
    local fx = fixture(); local ports, observed = fake_runtime(fx)
    local ready = core.start(fx.request, ports)
    t.eq(ready.status, "ready")
    t.eq(ready.environment_receipt_ref.ref, fx.request.artifact_root .. "/environment-receipt-ready.json")
    local ready_receipt = copy(observed.receipts[ready.environment_receipt_ref.ref])
    local handoff = core.handle_browser_readiness(ready_browser_event(fx, ready), ports)
    t.eq(handoff.module_start.schema, "testing-pipeline.module-start.v1")
    local finalized = core.finalize(finalize_request(fx, ready), ports)
    t.eq(finalized.status, "finalized")
    t.eq(finalized.environment_receipt_ref.ref, fx.request.artifact_root .. "/environment-receipt-finalized.json")
    t.eq(finalized.environment_receipt_ref.ref == ready.environment_receipt_ref.ref, false)
    t.eq(observed.receipts[ready.environment_receipt_ref.ref].status, ready_receipt.status)
    t.eq(table.concat(observed.cleanup_order, ","), "application,service-1,workspace,ports")
    t.eq(observed.active_count(), 0)
  end,

  test_services_and_application_receive_exact_owned_port_subsets = function()
    local fx = fixture(); local ports, observed = fake_runtime(fx)
    local ready = core.start(fx.request, ports)
    t.eq(ready.status, "ready")
    t.eq(#observed.supervised_ports, 2)
    t.eq(#observed.supervised_ports[1], 1)
    t.eq(observed.supervised_ports[1][1].port, 6301)
    t.eq(#observed.supervised_ports[2], 1)
    t.eq(observed.supervised_ports[2][1].port, 4173)
    t.eq(observed.readiness_owners[1].cleanup_ref.ref:find("service%-start") ~= nil, true)
    t.eq(observed.readiness_owners[1].runtime_ports[1].port, 6301)
    t.eq(observed.readiness_owners[2].cleanup_ref.ref:find("application%-start") ~= nil, true)
    t.eq(observed.readiness_owners[2].runtime_ports[1].port, 4173)
  end,

  test_replay_validates_every_closed_start_binding = function()
    local fx = fixture(); local ports, observed = fake_runtime(fx); core.start(fx.request, ports)
    local before = observed.target_effects()
    local mutations = {
      function(v) v.repository.commit_sha = string.rep("b", 40) end,
      function(v) v.profile_ref.ref = v.profile_ref.ref .. "-changed" end,
      function(v) v.approval_ref.ref = v.approval_ref.ref .. "-changed" end,
      function(v) v.validation_receipt_ref.ref = ".testing/approvals/changed.receipt.json" end,
      function(v) v.artifact_root = ".testing/runs/changed"; v.operation_state_ref.ref = v.artifact_root .. "/operation-state.json"; v.testing.artifact_root = v.artifact_root .. "/testing" end,
      function(v) v.base_url = "http://127.0.0.1:4173/other" end,
      function(v) v.runtime_ports[1].name = "changed" end,
      function(v) v.sessions[1].role = "changed" end,
      function(v) v.testing.module = "changed" end,
      function(v) v.testing.mutation_policy = "host-approved" end,
    }
    for index, mutate in ipairs(mutations) do
      local changed = copy(fx.request)
      mutate(changed)
      local ok, replay = pcall(core.start, changed, ports)
      if ok then
        t.eq(replay.status, "blocked", "closed start binding replay must fail closed index=" .. index)
        t.is_true(type(replay.failure_class) == "string")
      end
      t.eq(observed.target_effects(), before)
    end
  end,

  test_strict_pointers_reject_extra_and_credential_fields = function()
    local fx = fixture(); fx.request.profile_ref.metadata = { token = "hidden" }; t.raises(function() environment_contract.validate_start(fx.request) end)
    fx = fixture(); fx.request.profile_ref.ref = "https://user:password@example.invalid/profile"; t.raises(function() environment_contract.validate_start(fx.request) end)
    fx = fixture(); fx.request.operation_state_ref.extra = true; t.raises(function() environment_contract.validate_start(fx.request) end)
  end,

  test_receipt_write_failure_never_returns_dangling_pointer = function()
    local fx = fixture(); local ports, observed = fake_runtime(fx, { fail_receipts = true })
    t.raises(function() core.start(fx.request, ports) end)
    local state = observed.state(); t.eq(state.public_result, nil); t.eq(state.receipt_refs.blocked, nil); t.eq(next(observed.receipts), nil); t.eq(observed.active_count(), 0)
  end,

  test_state_save_failure_stops_execution_and_still_releases_acquired_ports = function()
    local fx = fixture({ operation_id = "state-save-failure" })
    local ports, observed = fake_runtime(fx, { fail_save = true })
    t.raises(function() core.start(fx.request, ports) end)
    t.eq(observed.active_count(), 0)
    t.eq(observed.shared.port_owners[4173], nil)
  end,

  test_authenticated_state_accepts_boolean_save_and_rejects_stale_revision = function()
    local accepted = fixture({ operation_id = "state-save-boolean" })
    local accepted_ports = fake_runtime(accepted, { save_returns_true = true })
    t.eq(core.start(accepted.request, accepted_ports).status, "ready")

    local stale = fixture({ operation_id = "state-save-stale" })
    local stale_ports = fake_runtime(stale)
    local original_save = stale_ports.save_state
    local save_calls = 0
    stale_ports.save_state = function(...)
      save_calls = save_calls + 1
      if save_calls == 1 then return { saved = false, stale = true, revision = 0 } end
      return original_save(...)
    end
    local blocked = core.start(stale.request, stale_ports)
    t.eq(blocked.status, "blocked")
    t.eq(blocked.failure_class, "state-save-conflict")
  end,

  test_completed_process_without_cleanup_handle_fails_closed = function()
    for _, missing_id in ipairs({ "service-1", "application" }) do
      local fx = fixture({ operation_id = "missing-cleanup-" .. missing_id })
      local ports, observed = fake_runtime(fx)
      core.start(fx.request, ports)
      local state = observed.state()
      state.public_result = nil
      for index = #state.resources, 1, -1 do
        if state.resources[index].id == missing_id then table.remove(state.resources, index) end
      end
      observed.set_state(state, true)
      local blocked = core.start(fx.request, ports)
      t.eq(blocked.status, "blocked")
      t.eq(blocked.failure_class, "missing-cleanup-ref")
    end
  end,

  test_diagnostics_are_deduplicated_and_capped_for_max_services = function()
    local fx = fixture({ service_count = 16 }); local ports = fake_runtime(fx); local ready = core.start(fx.request, ports)
    t.eq(#ready.diagnostic_refs, environment_contract.max_diagnostic_refs); environment_contract.validate_result(ready)
  end,

  test_browser_handoff_outbox_redelivers_identical_event_until_terminal_ack = function()
    local fx = fixture(); local ports = fake_runtime(fx); local ready = core.start(fx.request, ports)
    local event = ready_browser_event(fx, ready)
    local first = core.handle_browser_readiness(event, ports)
    local second = core.handle_browser_readiness(event, ports)
    t.is_true(first.module_start ~= nil)
    t.eq(second.redelivery, true)
    t.eq(environment_contract.same_value(first.module_start, second.module_start), true)
    t.eq(first.module_start.dedup_key, second.module_start.dedup_key)
    local acknowledged = core.acknowledge_testing_terminal({
      schema = "test-publication.publication-request.v1",
      publication_kind = "testing-summary",
      channel = "testing",
      severity = "success",
      subject = "Testing passed: " .. first.module_start.module,
      source_ref = copy(first.module_start.source_ref),
      trace_id = first.module_start.trace_id,
      dedup_key = first.module_start.dedup_key,
      status = "passed",
      job = "module-test-loop",
      artifact_root = first.module_start.artifact_root,
      metadata_path = first.module_start.artifact_root .. "/metadata.json",
    }, ports)
    t.eq(acknowledged.acknowledged, true)
    local third = core.handle_browser_readiness(event, ports)
    t.eq(third.acknowledged, true)
    t.eq(third.module_start, nil)
  end,

  test_plain_corrupted_state_cannot_inject_commands_resources_or_completed_flags = function()
    local fx = fixture(); local ports, observed = fake_runtime(fx); core.start(fx.request, ports)
    local before_effects, before_argv = observed.target_effects(), #observed.executed_argv
    observed.corrupt_state(function(state) state.profile_snapshot.commands.start = { "attacker-selected" }; state.resources = { { id = "application", cleanup_ref = { kind = "resource-cleanup", ref = "attacker" } } }; state.completed = { checkout = true, ["application-start"] = true } end)
    t.raises(function() core.start(fx.request, ports) end); t.eq(observed.target_effects(), before_effects); t.eq(#observed.executed_argv, before_argv)
  end,

  test_partial_checkout_failure_persists_handle_unwinds_and_writes_blocked_receipt = function()
    local fx = fixture(); local ports, observed = fake_runtime(fx, { checkout_partial = true }); local blocked = core.start(fx.request, ports)
    t.eq(blocked.status, "blocked"); t.eq(blocked.failure_class, "checkout-failed"); t.eq(blocked.environment_receipt_ref.ref, fx.request.artifact_root .. "/environment-receipt-blocked.json")
    t.eq(table.concat(observed.cleanup_order, ","), "workspace,ports"); t.eq(observed.active_count(), 0)
  end,

  test_serialized_port_lease_prevents_concurrent_exact_port_owners = function()
    local shared = { port_owners = {} }
    local first = fixture({ operation_id = "concurrent-first" }); local first_ports, first_observed = fake_runtime(first, nil, shared); local ready = core.start(first.request, first_ports)
    local second = fixture({ operation_id = "concurrent-second" }); local second_ports, second_observed = fake_runtime(second, nil, shared)
    t.raises(function() core.start(second.request, second_ports) end); t.eq(second_observed.target_effects(), 1); t.eq(second_observed.active_count(), 0)
    core.finalize(finalize_request(first, ready), first_ports); t.eq(first_observed.active_count(), 0)
    local third = fixture({ operation_id = "concurrent-third" }); local third_ports = fake_runtime(third, nil, shared); t.eq(core.start(third.request, third_ports).status, "ready")
  end,

  test_cancel_and_interrupt_use_same_reverse_cleanup_for_app_and_partial_service = function()
    local app = fixture({ operation_id = "cancel-app" }); local app_ports, app_observed = fake_runtime(app); local app_ready = core.start(app.request, app_ports)
    t.eq(core.interrupt(interrupt_request(app, app_ready, "cancelled"), app_ports).status, "cancelled"); t.eq(table.concat(app_observed.cleanup_order, ","), "application,service-1,workspace,ports")
    local partial = fixture({ operation_id = "interrupt-service" }); local partial_ports, partial_observed = fake_runtime(partial); local partial_ready = core.start(partial.request, partial_ports)
    local state = partial_observed.state(); table.remove(state.resources, #state.resources); state.status = "provisioning"; state.public_result = nil; state.receipt_refs.ready = nil; partial_observed.set_state(state, true)
    t.eq(core.interrupt(interrupt_request(partial, partial_ready, "interrupted"), partial_ports).status, "interrupted"); t.eq(table.concat(partial_observed.cleanup_order, ","), "service-1,workspace,ports")
  end,

  test_install_requires_explicit_frozen_dependency_enforcement = function()
    local fx = fixture(); local ports, observed = fake_runtime(fx, { no_frozen_dependencies = true }); local blocked = core.start(fx.request, ports)
    t.eq(blocked.status, "blocked"); t.eq(blocked.failure_class, "frozen-dependencies-unavailable"); t.eq(observed.active_count(), 0)
  end,

  test_sessions_match_browser_readiness_bootstrap_forms_and_reject_unsafe_fields = function()
    local fx = fixture({ sessions = {
      { role = "harness", browser_harness_command = "fixture-browser-harness" },
      { role = "harness-env", browser_harness_command_env = "FIXTURE_BROWSER_COMMAND" },
      { role = "cdp-env", cdp_endpoint_env = "FIXTURE_CDP_ENDPOINT" },
      { role = "cdp", cdp_url = "http://127.0.0.1:9222" },
    } }); local ports = fake_runtime(fx); local ready = core.start(fx.request, ports)
    t.eq(#ready.sessions, 4); t.is_true(public_text(ready):find("password", 1, true) == nil)
    local unsafe = copy(fx.request); unsafe.sessions[1].cookies = "inline"; t.raises(function() environment_contract.validate_start(unsafe) end)
    unsafe = copy(fx.request); unsafe.sessions[1].browser_harness_command = "fixture --token=value"; t.raises(function() environment_contract.validate_start(unsafe) end)
  end,

  test_read_only_profile_cannot_escalate_testing_mutation_policy = function()
    local fx = fixture({ testing_mutation = "host-approved" }); local ports, observed = fake_runtime(fx); t.raises(function() core.start(fx.request, ports) end); t.eq(observed.target_effects(), 0)
    local approved = fixture({ operation_id = "fixture-mutation", fixture_scoped = true, testing_mutation = "host-approved" }); local approved_ports = fake_runtime(approved); t.eq(core.start(approved.request, approved_ports).status, "ready")
  end,

  test_authorization_rejection_performs_zero_target_effects = function()
    local fx = fixture({ reject_authority = true }); local ports, observed = fake_runtime(fx); t.raises(function() core.start(fx.request, ports) end); t.eq(observed.target_effects(), 0)
  end,

  test_resolved_source_mismatch_unwinds_workspace_and_port_claim = function()
    local fx = fixture(); local ports, observed = fake_runtime(fx, { resolved_commit = string.rep("b", 40) }); local blocked = core.start(fx.request, ports)
    t.eq(blocked.status, "blocked"); t.eq(blocked.failure_class, "source-mismatch"); t.eq(table.concat(observed.cleanup_order, ","), "workspace,ports")
  end,

  test_runtime_contract_failure_matrix_fails_closed = function()
    for case_index, options in ipairs({
      { checkout_extra_field = true },
      { claim_wrong_ports = true },
      { claim_bad_deadline = true },
      { checkout_missing_metadata = true },
      { checkout_invalid_status = true },
      { checkout_short_commit = true },
      { invalid_remaining_budget = true },
      { claim_extra_field = true },
      { supervised_extra_field = "service-start" },
      { supervised_extra_field = "application-start" },
    }) do
      local fx = fixture({ operation_id = "runtime-contract-" .. tostring(case_index) })
      local ports, observed = fake_runtime(fx, options)
      local ok, result = pcall(core.start, fx.request, ports)
      if ok and result.status == "ready" then error("runtime contract case reached ready: " .. case_index) end
      t.eq(observed.active_count(), 0, "runtime contract case left active resources index=" .. case_index)
    end
  end,

  test_authorization_bundle_failure_matrix_prevents_effects = function()
    for _, mode in ipairs({ "missing", "bad-receipt", "scope" }) do
      local fx = fixture({ operation_id = "bundle-" .. mode })
      local ports, observed = fake_runtime(fx, { bundle_mode = mode })
      t.raises(function() core.start(fx.request, ports) end)
      t.eq(observed.target_effects(), 0)
    end
  end,

  test_authenticated_state_identity_failure_matrix = function()
    local mutations = {
      function(state) state.schema = "other" end,
      function(state) state.operation_id = "foreign" end,
      function(state) state.deadline_epoch_seconds = state.deadline_epoch_seconds + 1 end,
      function(state) state.workspace_ref = { kind = "workspace", ref = "foreign" } end,
      function(state) state.resources[1].cleanup_ref = { kind = "resource-cleanup", ref = "foreign" } end,
    }
    for index, mutate in ipairs(mutations) do
      local fx = fixture({ operation_id = "state-failure-" .. index })
      local ports, observed = fake_runtime(fx)
      core.start(fx.request, ports)
      local state = observed.state()
      mutate(state)
      observed.set_state(state, true)
      local ok, result = pcall(core.start, fx.request, ports)
      if ok and result.status == "ready" then error("state identity case reached ready: " .. index) end
    end
  end,

  test_service_and_application_supervision_failures_unwind = function()
    for index, options in ipairs({
      { early_exit = "service-start" },
      { missing_runtime_ports = "service-start" },
      { wrong_runtime_port_name = "service-start" },
      { early_exit = "application-start" },
      { missing_runtime_ports = "application-start" },
      { wrong_runtime_port_name = "application-start" },
    }) do
      local fx = fixture({ operation_id = "supervision-" .. index })
      local ports, observed = fake_runtime(fx, options)
      local blocked = core.start(fx.request, ports)
      t.eq(blocked.status, "blocked")
      t.eq(observed.active_count(), 0)
    end
  end,

  test_migrate_seed_and_readiness_failures_unwind_all_acquired_resources = function()
    local cases = {
      { fail_phase = "migrate", failure_class = "phase-failed" },
      { fail_phase = "seed", failure_class = "phase-failed" },
      { fail_readiness = "service-1", failure_class = "readiness-failed" },
      { fail_readiness = "application", failure_class = "readiness-failed" },
    }
    for index, options in ipairs(cases) do
      local fx = fixture({ operation_id = "provision-failure-" .. index })
      local ports, observed = fake_runtime(fx, options)
      local blocked = core.start(fx.request, ports)
      t.eq(blocked.status, "blocked")
      t.eq(blocked.failure_class, options.failure_class)
      t.eq(observed.active_count(), 0)
      t.eq(observed.shared.port_owners[4173], nil)
    end
  end,

  test_expired_total_deadline_blocks_before_checkout_and_releases_port_claim = function()
    local fx = fixture({ operation_id = "deadline-expired" })
    local ports, observed = fake_runtime(fx, { remaining_seconds = 0 })
    local blocked = core.start(fx.request, ports)
    t.eq(blocked.status, "blocked")
    t.eq(blocked.failure_class, "lifecycle-deadline")
    t.eq(table.concat(observed.calls, ","), "authorize,claim-ports,receipt-blocked")
    t.eq(table.concat(observed.cleanup_order, ","), "ports")
    t.eq(observed.shared.port_owners[4173], nil)
  end,

  test_readiness_attempt_failure_and_existing_correlation_replay = function()
    local failed = fixture({ operation_id = "readiness-attempt-failed" })
    local failed_ports, failed_observed = fake_runtime(failed, { fail_readiness_attempt = true })
    local blocked = core.start(failed.request, failed_ports)
    t.eq(blocked.status, "blocked")
    t.eq(blocked.failure_class, "readiness-attempt-failed")
    t.eq(failed_observed.active_count(), 0)

    local replay = fixture({ operation_id = "readiness-attempt-replay" })
    local replay_ports, replay_observed = fake_runtime(replay)
    local ready = core.start(replay.request, replay_ports)
    local state = replay_observed.state()
    state.public_result = nil
    replay_observed.set_state(state, true)
    local resumed = core.start(replay.request, replay_ports)
    t.eq(resumed.status, "ready")
    t.eq(resumed.readiness_correlation.attempt_id, ready.readiness_correlation.attempt_id)
  end,

  test_cleanup_failure_marks_terminal_result_incomplete = function()
    local fx = fixture({ operation_id = "cleanup-incomplete" })
    local ports = fake_runtime(fx, { fail_cleanup = "application" })
    local ready = core.start(fx.request, ports)
    local blocked = core.finalize(finalize_request(fx, ready), ports)
    t.eq(blocked.status, "blocked")
    t.eq(blocked.cleanup_status, "incomplete")
  end,

  test_browser_readiness_rejects_forged_stale_and_smuggled_results = function()
    local fx = fixture({ operation_id = "browser-correlation" })
    local ports, observed = fake_runtime(fx)
    local ready = core.start(fx.request, ports)
    local baseline = ready_browser_event(fx, ready)
    for _, mutate in ipairs({
      function(v) v.correlation.attempt_id = "stale-attempt" end,
      function(v) v.correlation.trace_id = "forged-trace" end,
      function(v) v.correlation.base_url = "http://127.0.0.1:4173/forged" end,
      function(v) v.correlation.sessions[1].role = "forged" end,
      function(v) v.stdout = "smuggled" end,
      function(v) v.sessions[1].commands = { "smuggled" } end,
      function(v) v.correlation.secret = "smuggled" end,
    }) do
      local forged = copy(baseline)
      mutate(forged)
      t.raises(function() core.handle_browser_readiness(forged, ports) end)
    end
    t.eq(observed.state().testing_outbox, nil)

    local accepted = copy(baseline)
    local first = core.handle_browser_readiness(accepted, ports)
    accepted.sessions[1].role = "mutated-after-accept"
    local replay = core.handle_browser_readiness(baseline, ports)
    t.eq(environment_contract.same_value(first.module_start, replay.module_start), true)
    t.eq(first.module_start.preflight_result.stdout, nil)
    t.eq(first.module_start.preflight_result.sessions[1].commands, nil)
  end,

  test_browser_readiness_helpers_and_failure_paths = function()
    local fx = fixture({ operation_id = "browser-helper" })
    local ports, observed = fake_runtime(fx)
    local ready = core.start(fx.request, ports)
    local check = core.browser_readiness_check(ready, { operation_state_ref = fx.request.operation_state_ref })
    t.eq(check.schema, "browser-readiness.check.v1")
    t.raises(function()
      core.browser_readiness_check(ready, {
        operation_state_ref = { kind = "artifact", ref = ".testing/runs/foreign/operation-state.json" },
      })
    end)
    local not_ready = copy(ready); not_ready.status = "blocked"; not_ready.environment_receipt_ref.ref = fx.request.artifact_root .. "/environment-receipt-blocked.json"; not_ready.base_url = nil; not_ready.sessions = nil
    t.raises(function() core.browser_readiness_check(not_ready, {}) end)
    t.raises(function() core.handle_browser_readiness({ schema = "other" }, ports) end)

    local blocked_event = ready_browser_event(fx, ready); blocked_event.status = "blocked"
    local action = core.handle_browser_readiness(blocked_event, ports)
    t.eq(action.result.status, "blocked")

    local foreign = fixture({ operation_id = "browser-foreign" })
    local foreign_ports, foreign_observed = fake_runtime(foreign)
    local foreign_ready = core.start(foreign.request, foreign_ports)
    local state = foreign_observed.state(); state.status = "blocked"; foreign_observed.set_state(state, true)
    t.raises(function() core.handle_browser_readiness(ready_browser_event(foreign, foreign_ready), foreign_ports) end)
  end,

  test_outbox_and_testing_terminal_failure_matrix = function()
    local fx = fixture({ operation_id = "terminal-failures" })
    local ports, observed = fake_runtime(fx)
    local ready = core.start(fx.request, ports)
    local terminal = {
      schema = "test-publication.publication-request.v1",
      publication_kind = "testing-summary",
      channel = "testing",
      severity = "success",
      subject = "Testing passed: " .. fx.request.testing.module,
      source_ref = copy(ready.environment_receipt_ref),
      trace_id = fx.request.trace_id,
      dedup_key = fx.request.dedup_key,
      status = "passed",
      job = "module-test-loop",
      artifact_root = fx.request.testing.artifact_root,
      metadata_path = fx.request.testing.artifact_root .. "/metadata.json",
    }

    for _, mutate in ipairs({
      function(v) v.extra = true end,
      function(v) v.schema = "other" end,
      function(v) v.publication_kind = nil end,
      function(v) v.channel = "foreign" end,
      function(v) v.severity = "unknown" end,
      function(v) v.subject = string.rep("x", 1025) end,
      function(v) v.status = "unknown" end,
      function(v) v.job = "" end,
      function(v) v.artifact_root = "unsafe"; v.metadata_path = "unsafe/metadata.json" end,
      function(v) v.metadata_path = v.artifact_root .. "/other.json" end,
      function(v) v.stage_report_path = v.artifact_root .. "/other.md" end,
      function(v) v.issue_drafts_path = v.artifact_root .. "/other.json" end,
      function(v) v.publication_dry_run = false end,
    }) do
      local malformed = copy(terminal); mutate(malformed)
      t.raises(function() core.acknowledge_testing_terminal(malformed, ports) end)
    end
    t.raises(function() core.acknowledge_testing_terminal(nil, ports) end)
    local foreign_source = copy(terminal); foreign_source.source_ref.ref = fx.request.artifact_root .. "/other.json"
    t.raises(function() core.acknowledge_testing_terminal(foreign_source, ports) end)

    local absent = core.acknowledge_testing_terminal(terminal, ports)
    t.eq(absent.acknowledged, false)

    local browser = ready_browser_event(fx, ready)
    core.handle_browser_readiness(browser, ports)
    local mismatched = copy(terminal); mismatched.job = "foreign-module"
    t.raises(function() core.acknowledge_testing_terminal(mismatched, ports) end)

    local state = observed.state()
    state.testing_outbox.status = "unknown"
    observed.set_state(state, true)
    t.raises(function() core.handle_browser_readiness(browser, ports) end)
  end,

  test_state_pointer_and_termination_identity_mismatches_fail = function()
    local fx = fixture({ operation_id = "identity-mismatch" })
    local ports, observed = fake_runtime(fx)
    local ready = core.start(fx.request, ports)
    local bad_finalize = finalize_request(fx, ready); bad_finalize.cleanup_ref.ref = "foreign"
    t.raises(function() core.finalize(bad_finalize, ports) end)

    local state = observed.state()
    state.start_request.operation_state_ref.ref = ".testing/runs/other/operation-state.json"
    state.start_request.artifact_root = ".testing/runs/other"
    state.start_request.testing.artifact_root = ".testing/runs/other/testing"
    state.request_binding = environment_contract.start_binding(state.start_request)
    state.operation_state_ref = copy(state.start_request.operation_state_ref)
    observed.set_state(state, true)
    t.raises(function() core.handle_browser_readiness(ready_browser_event(fx, ready), ports) end)
  end,

  test_saga_conformance_contract_executes = function()
    t.eq(#conformance.saga_conformance_errors(), 0)
  end,
}
