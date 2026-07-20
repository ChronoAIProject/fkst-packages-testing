local M = {}

local contract = require("contract.environment_factory")
local project_profile = require("contract.project_profile")
local ports_module = require("ports")
local runtime_outcomes = require("runtime_outcomes")
local testing_terminal = require("testing_terminal")

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[copy(key)] = copy(item) end
  return out
end

local function copy_list(value)
  local out = {}
  for _, item in ipairs(value or {}) do table.insert(out, copy(item)) end
  return out
end

local function same_ref(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.kind == right.kind and left.ref == right.ref
end

local function effect_id(state, suffix)
  return state.dedup_key .. "/environment-factory/" .. suffix
end

local function receipt_ref(request, status)
  return {
    kind = "artifact",
    ref = request.artifact_root .. "/environment-receipt-" .. status .. ".json",
  }
end

local function cleanup_receipt_ref(state, status)
  return {
    kind = "artifact",
    ref = state.artifact_root .. "/cleanup-receipt-" .. status .. ".json",
  }
end

local function public_cleanup_ref(request)
  return { kind = "environment-cleanup", ref = request.operation_id }
end

local function add_diagnostic(state, ref)
  if ref == nil then return end
  contract.validate_artifact_ref(ref, "diagnostic_ref")
  for _, existing in ipairs(state.diagnostic_refs) do
    if same_ref(existing, ref) then return end
  end
  if #state.diagnostic_refs < contract.max_diagnostic_refs then
    table.insert(state.diagnostic_refs, copy(ref))
  end
end

local function save_state(ports, state)
  local expected = state.storage_revision or 0
  local persisted = copy(state)
  persisted.storage_revision = nil
  local outcome = ports.save_state(state.operation_state_ref, persisted, expected)
  if outcome == true then
    state.storage_revision = expected + 1
    return
  end
  if type(outcome) == "table" and outcome.saved == true
    and type(outcome.revision) == "number" and outcome.revision == expected + 1 then
    state.storage_revision = outcome.revision
    return
  end
  if type(outcome) == "table" and outcome.stale == true then
    error("environment-factory: state-save-conflict: stale storage revision")
  end
  error("environment-factory: state-save-failed: runtime did not persist authenticated state")
end

local function try_save_state(ports, state)
  return pcall(save_state, ports, state)
end

local function authenticated_state(envelope)
  return runtime_outcomes.authenticated_state(envelope)
end

local function validate_loaded_state(request, state)
  if type(state) ~= "table" or state.schema ~= contract.schemas.state then
    error("environment-factory: malformed-state: invalid operation state")
  end
  local binding = contract.start_binding(request)
  if not contract.same_start_binding(state.request_binding, binding) then
    error("environment-factory: foreign-state: immutable start request binding mismatch")
  end
  if state.operation_id ~= request.operation_id
    or state.trace_id ~= request.trace_id
    or state.dedup_key ~= request.dedup_key
    or not same_ref(state.operation_state_ref, request.operation_state_ref) then
    error("environment-factory: foreign-state: operation identity mismatch")
  end
  return state
end

local function load_bundle(request, ports)
  local bundle = ports.load_authorization_bundle(request)
  if type(bundle) ~= "table" or type(bundle.context) ~= "table" then
    error("environment-factory: malformed-authorization-bundle: bundle and context are required")
  end
  contract.validate_profile_binding(request, bundle.profile)
  if type(bundle.receipt) ~= "table" or bundle.receipt.schema ~= project_profile.schemas.validation_receipt then
    error("environment-factory: malformed-authorization-bundle: validation receipt is required")
  end
  if bundle.receipt.trace_id ~= request.trace_id or bundle.receipt.dedup_key ~= request.dedup_key
    or not same_ref(bundle.receipt.approval_ref, request.approval_ref) then
    error("environment-factory: authorization-scope-mismatch: receipt identity differs from request")
  end
  return bundle
end

local function supervised_listener_groups(profile, runtime_ports)
  local assignments = contract.supervised_port_assignments(profile, runtime_ports)
  local groups = {}
  for _, group in ipairs(assignments.services) do table.insert(groups, copy_list(group)) end
  table.insert(groups, copy_list(assignments.application))
  return groups
end

local function append_resource(state, resource)
  for _, existing in ipairs(state.resources) do
    if existing.id == resource.id then
      if not same_ref(existing.cleanup_ref, resource.cleanup_ref) then
        error("environment-factory: resource-identity-mismatch: " .. resource.id)
      end
      return existing
    end
  end
  table.insert(state.resources, resource)
  return resource
end

local function find_resource(state, id)
  for _, resource in ipairs(state.resources) do
    if resource.id == id then return resource end
  end
  return nil
end

local function checkpoint_runtime_cleanup(state, ports, outcome, resource)
  if type(outcome) ~= "table" or type(outcome.cleanup_ref) ~= "table" then return end
  local cleanup_ref = { kind = outcome.cleanup_ref.kind, ref = outcome.cleanup_ref.ref }
  contract.validate_ref(cleanup_ref, resource.id .. ".cleanup_ref")
  resource.cleanup_ref = cleanup_ref
  append_resource(state, resource)
  save_state(ports, state)
end

local function initial_state(request, bundle, claim)
  local state = {
    schema = contract.schemas.state,
    start_request = copy(request),
    request_binding = contract.start_binding(request),
    operation_id = request.operation_id,
    operation_state_ref = copy(request.operation_state_ref),
    artifact_root = request.artifact_root,
    cleanup_ref = public_cleanup_ref(request),
    repository = copy(request.repository),
    profile_revision = claim.profile_snapshot.revision,
    profile_sha256 = bundle.receipt.profile_sha256,
    profile_snapshot = claim.profile_snapshot,
    base_url = request.base_url,
    runtime_ports = copy_list(request.runtime_ports),
    sessions = copy_list(request.sessions),
    testing = copy(request.testing),
    trace_id = request.trace_id,
    dedup_key = request.dedup_key,
    deadline_epoch_seconds = claim.deadline_epoch_seconds,
    total_seconds = claim.profile_snapshot.timeouts.total_seconds,
    status = "provisioning",
    cleanup_status = "pending",
    diagnostic_refs = {},
    completed = { port_claim = true },
    receipt_refs = {},
    cleanup_receipt_refs = {},
    resources = { {
      id = "ports",
      kind = "ports",
      cleanup_ref = copy(claim.cleanup_ref),
      timeout_seconds = claim.profile_snapshot.timeouts.cleanup_seconds,
    } },
  }
  add_diagnostic(state, claim.diagnostic_ref)
  return state
end

local function remaining_budget(state, ports)
  local value = ports.remaining_budget({
    operation_id = state.operation_id,
    artifact_root = state.artifact_root,
    deadline_epoch_seconds = state.deadline_epoch_seconds,
    total_seconds = state.total_seconds,
  })
  if type(value) ~= "number" or value ~= math.floor(value) or value < 0 or value > state.total_seconds then
    error("environment-factory: malformed-budget: remaining budget must be a bounded integer")
  end
  return value
end

local function effect_budget(state, ports, phase_timeout, cleanup)
  local remaining
  if cleanup then
    local ok, value = pcall(remaining_budget, state, ports)
    remaining = ok and value or 0
  else
    remaining = remaining_budget(state, ports)
    if remaining < 1 then error("environment-factory: lifecycle-deadline: total lifecycle deadline expired") end
  end
  return {
    resource_budgets = copy(state.profile_snapshot.resource_budgets),
    output_bytes = state.profile_snapshot.resource_budgets.output_bytes,
    phase_timeout_seconds = phase_timeout,
    timeout_seconds = cleanup and phase_timeout or math.min(phase_timeout, remaining),
    deadline_epoch_seconds = state.deadline_epoch_seconds,
    remaining_seconds = remaining,
  }
end

local function add_budget(request, budget)
  for key, value in pairs(budget) do request[key] = value end
  return request
end

local function checkpoint_claim_acquisition(request, bundle, outcome, remember, ports)
  if type(outcome) ~= "table" or type(outcome.cleanup_ref) ~= "table" then return nil end
  local cleanup_ref = { kind = outcome.cleanup_ref.kind, ref = outcome.cleanup_ref.ref }
  local ok = pcall(contract.validate_ref, cleanup_ref, "port-claim.cleanup_ref")
  if not ok then return nil end
  local deadline = outcome.deadline_epoch_seconds
  if type(deadline) ~= "number" or deadline ~= math.floor(deadline) or deadline < 1 then deadline = 1 end
  local recovery_claim = {
    profile_snapshot = bundle.profile,
    cleanup_ref = cleanup_ref,
    deadline_epoch_seconds = deadline,
  }
  local state = initial_state(request, bundle, recovery_claim)
  state.completed.port_claim = outcome.status == "passed"
  if type(outcome.diagnostic_ref) == "table" then
    pcall(add_diagnostic, state, outcome.diagnostic_ref)
  end
  remember(state)
  save_state(ports, state)
  return state
end

local function recover_authorized_state(request, ports, existing, remember)
  local bundle = load_bundle(request, ports)
  local claim = ports.authorize_claim_ports({
    effect_id = request.dedup_key .. "/environment-factory/port-claim",
    operation_id = request.operation_id,
    artifact_root = request.artifact_root,
    runtime_ports = copy_list(request.runtime_ports),
    listener_groups = supervised_listener_groups(bundle.profile, request.runtime_ports),
    request_binding = contract.start_binding(request),
    authorize = function()
      return project_profile.authorize_execution(bundle.profile, bundle.approval, bundle.receipt, bundle.context)
    end,
  })
  local state = existing
  if state == nil then state = checkpoint_claim_acquisition(request, bundle, claim, remember, ports) end
  claim = runtime_outcomes.validate_claim(request, claim)

  state = state or initial_state(request, bundle, claim)
  if existing ~= nil then
    validate_loaded_state(request, state)
    if state.deadline_epoch_seconds ~= claim.deadline_epoch_seconds then
      error("environment-factory: foreign-state: lifecycle deadline differs from trusted effect ledger")
    end
    append_resource(state, {
      id = "ports",
      kind = "ports",
      cleanup_ref = copy(claim.cleanup_ref),
      timeout_seconds = claim.profile_snapshot.timeouts.cleanup_seconds,
    })
    state.profile_snapshot = claim.profile_snapshot
    state.profile_revision = claim.profile_snapshot.revision
    state.profile_sha256 = bundle.receipt.profile_sha256
  end
  add_diagnostic(state, claim.diagnostic_ref)
  remember(state)
  save_state(ports, state)

  local checkout = ports.checkout(add_budget({
    effect_id = effect_id(state, "checkout"),
    operation_id = state.operation_id,
    repository = copy(state.profile_snapshot.repository),
    artifact_root = state.artifact_root,
  }, effect_budget(state, ports, state.profile_snapshot.timeouts.start_seconds, false)))
  local previous_workspace_ref = state.workspace_ref and copy(state.workspace_ref) or nil
  if type(checkout) == "table" and type(checkout.workspace_ref) == "table" and type(checkout.cleanup_ref) == "table" then
    local workspace_ref = { kind = checkout.workspace_ref.kind, ref = checkout.workspace_ref.ref }
    local cleanup_ref = { kind = checkout.cleanup_ref.kind, ref = checkout.cleanup_ref.ref }
    local refs_ok = pcall(function()
      contract.validate_ref(workspace_ref, "checkout.workspace_ref")
      contract.validate_ref(cleanup_ref, "checkout.cleanup_ref")
    end)
    if refs_ok then
      if previous_workspace_ref ~= nil and not same_ref(previous_workspace_ref, workspace_ref) then
        error("environment-factory: foreign-state: checkout workspace differs from trusted effect ledger")
      end
      append_resource(state, {
        id = "workspace",
        kind = "workspace",
        cleanup_ref = cleanup_ref,
        timeout_seconds = state.profile_snapshot.timeouts.cleanup_seconds,
      })
      state.workspace_ref = workspace_ref
      state.resolved_commit = checkout.resolved_commit
      remember(state)
      save_state(ports, state)
    end
  end
  checkout = runtime_outcomes.validate_checkout(checkout)
  add_diagnostic(state, checkout.diagnostic_ref)
  if checkout.status ~= "passed" then error("environment-factory: checkout-failed: runtime reported partial checkout failure") end
  if checkout.resolved_commit ~= request.repository.commit_sha then
    error("environment-factory: source-mismatch: resolved commit differs from approval")
  end
  state.completed.checkout = true
  remember(state)
  save_state(ports, state)
  return state
end

local function run_oneshot(state, ports, phase)
  local argv = state.profile_snapshot.commands[phase]
  if argv == nil or state.completed["phase-" .. phase] then return end
  local request = add_budget({
    effect_id = effect_id(state, "phase/" .. phase),
    operation_id = state.operation_id,
    artifact_root = state.artifact_root,
    workspace_ref = copy(state.workspace_ref),
    working_directory = state.profile_snapshot.working_directory,
    argv = argv,
    mode = "oneshot",
  }, effect_budget(state, ports, state.profile_snapshot.timeouts[phase .. "_seconds"], false))
  if phase == "install" then request.requires_frozen_dependencies = true end
  local outcome = ports.run_argv(request)
  runtime_outcomes.validate_effect(outcome, "phase-" .. phase, {
    status = true,
    diagnostic_ref = true,
    frozen_dependencies_enforced = true,
  })
  add_diagnostic(state, outcome.diagnostic_ref)
  if outcome.status ~= "passed" then error("environment-factory: phase-failed: " .. phase) end
  if phase == "install" and outcome.frozen_dependencies_enforced ~= true then
    error("environment-factory: frozen-dependencies-unavailable: install runtime cannot enforce frozen dependencies")
  end
  state.completed["phase-" .. phase] = true
  save_state(ports, state)
end

local function start_service(state, ports, service, index, runtime_ports)
  local key = "service-" .. index .. "-start"
  local resource_id = "service-" .. index
  if state.completed[key] then
    local resource = find_resource(state, resource_id)
    if resource == nil then
      error("environment-factory: missing-cleanup-ref: completed service " .. index)
    end
    return copy(resource.cleanup_ref)
  end
  local outcome = ports.run_argv(add_budget({
    effect_id = effect_id(state, "service/" .. index .. "/start"),
    operation_id = state.operation_id,
    artifact_root = state.artifact_root,
    workspace_ref = copy(state.workspace_ref),
    working_directory = state.profile_snapshot.working_directory,
    argv = service.start_argv,
    mode = "supervised",
    listener_mode = service.listener_mode,
    runtime_ports = copy_list(runtime_ports),
  }, effect_budget(state, ports, state.profile_snapshot.timeouts.start_seconds, false)))
  checkpoint_runtime_cleanup(state, ports, outcome, {
    id = resource_id,
    kind = "service",
    cleanup_argv = service.cleanup_argv,
    timeout_seconds = state.profile_snapshot.timeouts.cleanup_seconds,
  })
  runtime_outcomes.validate_effect(outcome, key, {
    status = true,
    diagnostic_ref = true,
    cleanup_ref = true,
    early_exit = true,
    runtime_ports = true,
  })
  add_diagnostic(state, outcome.diagnostic_ref)
  if outcome.status ~= "running" or outcome.early_exit == true then
    error("environment-factory: service-start-failed: " .. index)
  end
  if outcome.cleanup_ref == nil then error("environment-factory: missing-cleanup-ref: service " .. index) end
  if not runtime_outcomes.exact_runtime_ports(runtime_ports, outcome.runtime_ports) then
    error("environment-factory: missing-runtime-ports: service " .. index)
  end
  state.completed[key] = true
  save_state(ports, state)
  return copy(outcome.cleanup_ref)
end

local function wait_checks(state, ports, checks, suffix, runtime_ports, process_cleanup_ref)
  local key = "readiness-" .. suffix
  if state.completed[key] then return end
  local outcome = ports.wait_readiness(add_budget({
    effect_id = effect_id(state, "readiness/" .. suffix),
    operation_id = state.operation_id,
    artifact_root = state.artifact_root,
    workspace_ref = copy(state.workspace_ref),
    working_directory = state.profile_snapshot.working_directory,
    checks = checks,
    runtime_ports = copy_list(runtime_ports),
    process_cleanup_ref = copy(process_cleanup_ref),
  }, effect_budget(state, ports, state.profile_snapshot.timeouts.readiness_seconds, false)))
  runtime_outcomes.validate_effect(outcome, key, { status = true, diagnostic_ref = true })
  add_diagnostic(state, outcome.diagnostic_ref)
  if outcome.status ~= "ready" then error("environment-factory: readiness-failed: " .. suffix) end
  state.completed[key] = true
  save_state(ports, state)
end

local function start_application(state, ports, runtime_ports)
  if state.completed["application-start"] then
    local resource = find_resource(state, "application")
    if resource == nil then
      error("environment-factory: missing-cleanup-ref: completed application")
    end
    return copy(resource.cleanup_ref)
  end
  local outcome = ports.run_argv(add_budget({
    effect_id = effect_id(state, "application/start"),
    operation_id = state.operation_id,
    artifact_root = state.artifact_root,
    workspace_ref = copy(state.workspace_ref),
    working_directory = state.profile_snapshot.working_directory,
    argv = state.profile_snapshot.commands.start,
    mode = "supervised",
    listener_mode = state.profile_snapshot.application_listener_mode,
    runtime_ports = copy_list(runtime_ports),
  }, effect_budget(state, ports, state.profile_snapshot.timeouts.start_seconds, false)))
  checkpoint_runtime_cleanup(state, ports, outcome, {
    id = "application",
    kind = "application",
    cleanup_argv = state.profile_snapshot.commands.cleanup,
    timeout_seconds = state.profile_snapshot.timeouts.cleanup_seconds,
  })
  runtime_outcomes.validate_effect(outcome, "application-start", {
    status = true,
    diagnostic_ref = true,
    cleanup_ref = true,
    early_exit = true,
    runtime_ports = true,
  })
  add_diagnostic(state, outcome.diagnostic_ref)
  if outcome.status ~= "running" or outcome.early_exit == true then
    error("environment-factory: application-start-failed: supervised process exited or did not start")
  end
  if outcome.cleanup_ref == nil then error("environment-factory: missing-cleanup-ref: application start") end
  if not runtime_outcomes.exact_runtime_ports(runtime_ports, outcome.runtime_ports) then
    error("environment-factory: missing-runtime-ports: application")
  end
  state.completed["application-start"] = true
  save_state(ports, state)
  return copy(outcome.cleanup_ref)
end

local function cleanup_resources(state, ports)
  local complete = true
  for index = #state.resources, 1, -1 do
    local resource = state.resources[index]
    if resource.cleaned ~= true then
      local request = add_budget({
        effect_id = effect_id(state, "cleanup/" .. resource.id),
        operation_id = state.operation_id,
        artifact_root = state.artifact_root,
        cleanup_ref = copy(resource.cleanup_ref),
        argv = resource.cleanup_argv,
        workspace_ref = copy(state.workspace_ref),
        working_directory = state.profile_snapshot.working_directory,
      }, effect_budget(state, ports, resource.timeout_seconds, true))
      local ok, outcome = pcall(ports.cleanup, request)
      if ok then
        ok = pcall(runtime_outcomes.validate_effect, outcome, "cleanup-" .. resource.id, {
          status = true,
          diagnostic_ref = true,
        })
      end
      complete = complete and ok
      if ok then
        add_diagnostic(state, outcome.diagnostic_ref)
        resource.cleanup_diagnostic_ref = copy(outcome.diagnostic_ref)
        if outcome.status == "cleaned" then resource.cleaned = true else complete = false end
      end
      if not try_save_state(ports, state) then complete = false end
    end
  end
  state.cleanup_status = complete and "complete" or "incomplete"
  return complete
end

local function cleanup_receipt(state)
  local attempted, verified, remaining = {}, {}, {}
  for _, resource in ipairs(state.resources) do
    local status = resource.cleaned == true and "cleaned" or "remaining"
    local item = {
      resource_id = resource.id,
      resource_kind = resource.kind,
      status = status,
    }
    if resource.cleanup_diagnostic_ref ~= nil then
      item.diagnostic_ref = copy(resource.cleanup_diagnostic_ref)
    end
    table.insert(attempted, item)
    if status == "cleaned" then
      table.insert(verified, resource.id)
    else
      table.insert(remaining, {
        resource_id = resource.id,
        resource_kind = resource.kind,
        cleanup_ref = copy(resource.cleanup_ref),
      })
    end
  end
  return contract.validate_cleanup_receipt({
    schema = contract.schemas.cleanup_receipt,
    operation_id = state.operation_id,
    status = state.cleanup_status,
    attempted_resources = attempted,
    verified_removals = verified,
    remaining_resources = remaining,
    artifact_root = state.artifact_root,
    trace_id = state.trace_id,
    dedup_key = state.dedup_key,
  })
end

local function write_cleanup_receipt(state, ports)
  local ref = cleanup_receipt_ref(state, state.cleanup_status)
  local outcome = ports.write_receipt(add_budget({
    effect_id = effect_id(state, "cleanup-receipt/" .. state.cleanup_status),
    operation_id = state.operation_id,
    artifact_root = state.artifact_root,
    receipt_ref = copy(ref),
    receipt = cleanup_receipt(state),
  }, effect_budget(state, ports, state.profile_snapshot.timeouts.cleanup_seconds, true)))
  runtime_outcomes.validate_effect(outcome, "write-cleanup-receipt", {
    status = true,
    diagnostic_ref = true,
  })
  add_diagnostic(state, outcome.diagnostic_ref)
  if outcome.status ~= "passed" then
    error("environment-factory: cleanup-receipt-write-failed: runtime did not persist the cleanup receipt")
  end
  state.cleanup_receipt_refs = state.cleanup_receipt_refs or {}
  state.cleanup_receipt_refs[state.cleanup_status] = copy(ref)
  save_state(ports, state)
  return ref
end

local function persist_cleanup_receipt(state, ports)
  state.public_result = nil
  state.cleanup_receipt_ref = nil
  local ok, ref = pcall(write_cleanup_receipt, state, ports)
  if ok then
    state.cleanup_receipt_ref = ref
    return ref
  end
  state.status = "blocked"
  state.failure_class = "cleanup-receipt-write-failed"
  state.cleanup_status = "incomplete"
  try_save_state(ports, state)
  error("environment-factory: cleanup-receipt-unavailable: cleanup receipt persistence failed")
end

local function failure_class(value)
  local text = tostring(value or "blocked")
  return (text:match("environment%-factory:%s*([%w%-]+)") or "provisioning-failed"):sub(1, 180)
end

local function receipt(state, status, classification)
  return {
    schema = contract.schemas.receipt,
    operation_id = state.operation_id,
    status = status,
    failure_class = classification,
    profile_revision = state.profile_revision,
    profile_sha256 = state.profile_sha256,
    repository = { url = state.repository.url, resolved_commit = state.resolved_commit },
    workspace_ref = copy(state.workspace_ref),
    base_url = state.base_url,
    runtime_ports = copy_list(state.runtime_ports),
    sessions = copy_list(state.sessions),
    artifact_root = state.artifact_root,
    diagnostic_refs = copy_list(state.diagnostic_refs),
    cleanup_ref = copy(state.cleanup_ref),
    cleanup_receipt_ref = state.cleanup_receipt_ref and copy(state.cleanup_receipt_ref) or nil,
    cleanup_status = state.cleanup_status,
    trace_id = state.trace_id,
    dedup_key = state.dedup_key,
  }
end

local function result(state, status, classification, persisted_ref)
  if persisted_ref == nil then error("environment-factory: receipt-unavailable: result requires a persisted receipt") end
  local value = {
    schema = contract.schemas.result,
    operation_id = state.operation_id,
    status = status,
    failure_class = classification,
    environment_receipt_ref = copy(persisted_ref),
    cleanup_ref = copy(state.cleanup_ref),
    diagnostic_refs = copy_list(state.diagnostic_refs),
    cleanup_status = state.cleanup_status,
    trace_id = state.trace_id,
    dedup_key = state.dedup_key,
  }
  if status ~= "ready" then value.cleanup_receipt_ref = copy(state.cleanup_receipt_ref) end
  if status == "ready" then
    value.base_url = state.base_url
    value.sessions = copy_list(state.sessions)
    value.readiness_correlation = copy(state.readiness_correlation)
  end
  return contract.validate_result(value)
end

local function write_receipt(state, ports, status, classification)
  local ref = receipt_ref(state.start_request, status)
  local outcome = ports.write_receipt(add_budget({
    effect_id = effect_id(state, "receipt/" .. status),
    operation_id = state.operation_id,
    receipt_ref = copy(ref),
    receipt = receipt(state, status, classification),
  }, effect_budget(state, ports, state.profile_snapshot.timeouts.cleanup_seconds, true)))
  runtime_outcomes.validate_effect(outcome, "write-receipt", { status = true, diagnostic_ref = true })
  add_diagnostic(state, outcome.diagnostic_ref)
  if outcome.status ~= "passed" then
    error("environment-factory: receipt-write-failed: runtime did not persist the receipt")
  end
  state.receipt_refs[status] = copy(ref)
  save_state(ports, state)
  return ref
end

local function mark_blocked(state, ports, err)
  local classification = failure_class(err)
  local complete = cleanup_resources(state, ports)
  state.status = "blocked"
  state.failure_class = classification
  state.cleanup_status = complete and "complete" or "incomplete"
  persist_cleanup_receipt(state, ports)
  local ok, persisted = pcall(write_receipt, state, ports, "blocked", classification)
  if not ok then
    state.public_result = nil
    state.receipt_refs.blocked = nil
    state.failure_class = "receipt-write-failed"
    save_state(ports, state)
    error("environment-factory: receipt-unavailable: blocked receipt persistence failed")
  end
  state.public_result = result(state, "blocked", state.failure_class, persisted)
  save_state(ports, state)
  return state.public_result
end

local function create_readiness_correlation(state, ports)
  if state.readiness_correlation ~= nil then
    contract.validate_readiness_correlation(state.readiness_correlation)
    return state.readiness_correlation
  end
  local outcome = ports.create_readiness_attempt(add_budget({
    effect_id = effect_id(state, "browser-readiness/attempt"),
    operation_id = state.operation_id,
    artifact_root = state.artifact_root,
    environment_receipt_ref = copy(state.receipt_refs.ready),
    operation_state_ref = copy(state.operation_state_ref),
  }, effect_budget(state, ports, state.profile_snapshot.timeouts.readiness_seconds, false)))
  runtime_outcomes.validate_effect(outcome, "create-readiness-attempt", {
    status = true,
    attempt_id = true,
    diagnostic_ref = true,
  })
  add_diagnostic(state, outcome.diagnostic_ref)
  if outcome.status ~= "passed" or type(outcome.attempt_id) ~= "string" then
    error("environment-factory: readiness-attempt-failed: runtime did not persist an attempt")
  end
  local correlation = {
    schema = contract.schemas.readiness_correlation,
    attempt_id = outcome.attempt_id,
    operation_id = state.operation_id,
    operation_state_ref = copy(state.operation_state_ref),
    environment_receipt_ref = copy(state.receipt_refs.ready),
    base_url = state.base_url,
    sessions = copy_list(state.sessions),
    trace_id = state.trace_id,
    dedup_key = state.dedup_key,
  }
  contract.validate_readiness_correlation(correlation)
  state.readiness_correlation = correlation
  save_state(ports, state)
  return correlation
end

local function provision(state, ports)
  local assignments = contract.supervised_port_assignments(state.profile_snapshot, state.runtime_ports)
  run_oneshot(state, ports, "install")
  run_oneshot(state, ports, "build")
  for index, service in ipairs(state.profile_snapshot.dependent_services or {}) do
    local cleanup_ref = start_service(state, ports, service, index, assignments.services[index])
    wait_checks(state, ports, service.readiness_checks, "service-" .. index,
      assignments.services[index], cleanup_ref)
  end
  run_oneshot(state, ports, "migrate")
  run_oneshot(state, ports, "seed")
  local application_cleanup_ref = start_application(state, ports, assignments.application)
  wait_checks(state, ports, state.profile_snapshot.readiness_checks, "application",
    assignments.application, application_cleanup_ref)
  state.status = "ready"
  state.cleanup_status = "pending"
  local persisted = write_receipt(state, ports, "ready")
  create_readiness_correlation(state, ports)
  state.public_result = result(state, "ready", nil, persisted)
  save_state(ports, state)
  return state.public_result
end

local function load_existing(request, ports)
  local envelope = ports.load_state(request.operation_state_ref)
  if envelope == nil then return nil end
  return validate_loaded_state(request, authenticated_state(envelope))
end

function M.start(request, supplied_ports)
  request = contract.validate_start(request)
  local ports = ports_module.resolve(supplied_ports)
  local state
  local ok, value = pcall(function()
    local existing = load_existing(request, ports)
    state = recover_authorized_state(request, ports, existing, function(current) state = current end)
    if state.public_result ~= nil then return contract.validate_result(state.public_result) end
    return provision(state, ports)
  end)
  if ok then return value end
  local classification = failure_class(value)
  if classification == "foreign-state" or classification == "authorization-scope-mismatch"
    or classification == "resource-identity-mismatch" then
    error(value, 0)
  end
  if state ~= nil and #state.resources > 0 then return mark_blocked(state, ports, value) end
  error(value, 0)
end

function M.browser_readiness_check(ready_result, state)
  contract.validate_result(ready_result)
  if ready_result.status ~= "ready" then
    error("environment-factory: environment-not-ready: readiness handoff requires ready status")
  end
  contract.validate_readiness_correlation(ready_result.readiness_correlation)
  if not same_ref(ready_result.readiness_correlation.operation_state_ref, state.operation_state_ref) then
    error("environment-factory: readiness-correlation-mismatch: state pointer differs")
  end
  return {
    schema = "browser-readiness.check.v1",
    base_url = ready_result.base_url,
    sessions = copy_list(ready_result.sessions),
    request_context = { dry_run = false },
    source_ref = copy(state.operation_state_ref),
    correlation = copy(ready_result.readiness_correlation),
  }
end

local function module_start(state, readiness_result)
  return {
    schema = "testing-pipeline.module-start.v1",
    module = state.testing.module,
    backend = "fkst-native",
    dry_run = false,
    preflight_result = readiness_result,
    ui_loop = {
      base_url = state.base_url,
      allowed_origins = copy_list(state.profile_snapshot.allowed_origins),
      browser_readiness_ref = state.receipt_refs.ready.ref,
      cdp_readiness_ref = state.receipt_refs.ready.ref,
      mutation_policy = state.testing.mutation_policy,
    },
    artifact_root = state.testing.artifact_root,
    source_ref = copy(state.receipt_refs.ready),
    trace_id = state.trace_id,
    dedup_key = state.dedup_key,
  }
end

local function recover_from_state_ref(state_ref, ports)
  local envelope = ports.load_state(state_ref)
  if envelope == nil then error("environment-factory: missing-state: operation state is required") end
  local stored = authenticated_state(envelope)
  local request = contract.validate_start(stored.start_request)
  if not same_ref(request.operation_state_ref, state_ref) then
    error("environment-factory: foreign-state: state pointer differs from bound request")
  end
  local recovered
  recovered = recover_authorized_state(request, ports, validate_loaded_state(request, stored), function(value) recovered = value end)
  return recovered
end

function M.handle_browser_readiness(readiness_result, supplied_ports)
  local sanitized = contract.sanitize_browser_readiness_result(readiness_result)
  local ports = ports_module.resolve(supplied_ports)
  local state = recover_from_state_ref(sanitized.source_ref, ports)
  if state.status ~= "ready" or state.receipt_refs.ready == nil or state.readiness_correlation == nil then
    error("environment-factory: foreign-browser-readiness-result: no matching ready environment state")
  end
  if not contract.same_value(sanitized.correlation, state.readiness_correlation)
    or not same_ref(sanitized.source_ref, state.operation_state_ref) then
    error("environment-factory: readiness-correlation-mismatch: stale or forged browser readiness attempt")
  end
  if sanitized.status ~= "ready" then
    return { result = mark_blocked(state, ports, "environment-factory: browser-readiness-failed: browser gate blocked") }
  end
  if state.testing_outbox ~= nil then
    if state.testing_outbox.status == "acknowledged" then return { acknowledged = true } end
    if state.testing_outbox.status == "pending" then
      return { module_start = copy(state.testing_outbox.payload), redelivery = true }
    end
    error("environment-factory: malformed-outbox: unknown testing outbox status")
  end
  local payload = module_start(state, sanitized)
  state.testing_outbox = { status = "pending", payload = copy(payload) }
  save_state(ports, state)
  return { module_start = copy(payload), redelivery = false }
end

function M.acknowledge_testing_terminal(payload, supplied_ports)
  payload = testing_terminal.validate(payload)
  local suffix = "/environment-receipt-ready.json"
  if payload.source_ref.ref:sub(-#suffix) ~= suffix then
    error("environment-factory: foreign-testing-terminal: source is not an environment ready receipt")
  end
  local state_ref = {
    kind = "artifact",
    ref = payload.source_ref.ref:sub(1, #payload.source_ref.ref - #suffix) .. "/operation-state.json",
  }
  local ports = ports_module.resolve(supplied_ports)
  local state = recover_from_state_ref(state_ref, ports)
  if state.testing_outbox == nil or state.testing_outbox.status ~= "pending" then
    return { acknowledged = state.testing_outbox ~= nil and state.testing_outbox.status == "acknowledged" }
  end
  local pending = state.testing_outbox.payload
  if not same_ref(payload.source_ref, pending.source_ref)
    or payload.trace_id ~= pending.trace_id
    or payload.dedup_key ~= pending.dedup_key
    or payload.job ~= "module-test-loop"
    or payload.artifact_root ~= pending.artifact_root then
    error("environment-factory: foreign-testing-terminal: terminal identity differs from pending outbox")
  end
  state.testing_outbox.status = "acknowledged"
  state.testing_outbox.terminal_status = payload.status
  save_state(ports, state)
  return { acknowledged = true }
end

local function validate_termination_identity(request, state)
  if state.operation_id ~= request.operation_id or state.trace_id ~= request.trace_id
    or state.dedup_key ~= request.dedup_key or not same_ref(state.cleanup_ref, request.cleanup_ref) then
    error("environment-factory: foreign-termination-request: cleanup identity differs from state")
  end
end

local function terminate(request, status, ports)
  local state = recover_from_state_ref(request.operation_state_ref, ports)
  validate_termination_identity(request, state)
  if state.status == status and state.public_result ~= nil then return contract.validate_result(state.public_result) end
  local complete = cleanup_resources(state, ports)
  state.status = complete and status or "blocked"
  state.failure_class = complete and nil or "cleanup-incomplete"
  persist_cleanup_receipt(state, ports)
  local persisted = write_receipt(state, ports, state.status, state.failure_class)
  state.public_result = result(state, state.status, state.failure_class, persisted)
  save_state(ports, state)
  return state.public_result
end

function M.finalize(request, supplied_ports)
  request = contract.validate_finalize(request)
  return terminate(request, "finalized", ports_module.resolve(supplied_ports))
end

function M.interrupt(request, supplied_ports)
  request = contract.validate_interrupt(request)
  return terminate(request, request.interruption, ports_module.resolve(supplied_ports))
end

return M
