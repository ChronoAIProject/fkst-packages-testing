local json_codec = require("testing_runtime.json")

local R = {}

local default_runtime_cli = "packages/environment-factory/bin/environment-factory-runtime.js"
local pending_claims = {}
local active_listener_claims = {}

local function runtime_port_unavailable(name)
  return function()
    error("environment-factory: runtime-port-unavailable: " .. name)
  end
end

local function artifact_root_from_ref(ref)
  local path = type(ref) == "table" and ref.ref or nil
  if type(path) ~= "string" then return nil end
  return path:match("^(.+)/operation%-state%.json$")
    or path:match("^(.+)/environment%-receipt%-%w+%.json$")
end

local function request_root(payload)
  if type(payload.artifact_root) == "string" then return payload.artifact_root end
  local root = artifact_root_from_ref(payload.ref)
  if root ~= nil then return root end
  root = artifact_root_from_ref(payload.receipt_ref)
  if root ~= nil then return root end
  if type(payload.start) == "table" then return payload.start.artifact_root end
  return nil
end

local function safe_label(value)
  local label = tostring(value or "request"):gsub("[^A-Za-z0-9._-]", "-")
  if #label > 160 then label = label:sub(1, 160) end
  return label
end

local function bounded_text(value, limit)
  local text = tostring(value or ""):gsub("[%z\1-\31\127]", " "):gsub("%s+", " ")
  return text:sub(1, limit or 1024)
end

local function listener_capability()
  local capability = rawget(_G, "network_listener")
  if type(capability) ~= "table" or type(capability.claim_loopback) ~= "function" then
    error("environment-factory: listener-capability-unavailable: network_listener.claim_loopback is required")
  end
  return capability
end

local function copy_ports(value)
  local result = {}
  for _, item in ipairs(value or {}) do
    table.insert(result, { name = item.name, port = item.port })
  end
  return result
end

local function configured_runtime_cli(options)
  local global = rawget(_G, "environment_factory_runtime_cli")
  local value
  if global ~= nil then value = global
  elseif type(options) == "table" and options.runtime_cli ~= nil then value = options.runtime_cli
  elseif os.getenv("FKST_ENVIRONMENT_FACTORY_RUNTIME_CLI") ~= nil then
    value = os.getenv("FKST_ENVIRONMENT_FACTORY_RUNTIME_CLI")
  else value = default_runtime_cli end
  if type(value) ~= "string" or value == "" or #value > 4096 or value:find("[%z\1-\31\127]") ~= nil then
    error("environment-factory: runtime-cli-invalid: host runtime executable path is invalid")
  end
  return value
end

local function configured_runtime_ref(payload, root, options)
  local configured = rawget(_G, "environment_factory_runtime_config_ref")
  if configured == nil and type(options) == "table" then configured = options.runtime_config_ref end
  if configured == nil then
    local environment_ref = os.getenv("FKST_ENVIRONMENT_FACTORY_RUNTIME_CONFIG_REF")
    if environment_ref ~= nil then configured = { kind = "artifact", ref = environment_ref } end
  end
  if type(configured) == "function" then
    configured = configured({
      artifact_root = root,
      operation_id = payload.operation_id or (type(payload.start) == "table" and payload.start.operation_id),
    })
  end
  if type(configured) ~= "table" or configured.kind ~= "artifact" or type(configured.ref) ~= "string" then
    error("environment-factory: runtime-config-unavailable: host runtime config artifact capability is required")
  end
  if configured.ref == root or configured.ref:sub(1, #root + 1) == root .. "/" then
    error("environment-factory: runtime-config-inside-operation-root: host capability must be outside artifact_root")
  end
  return { kind = configured.kind, ref = configured.ref }
end

local function call_cli(name, payload, timeout, options, listener_options)
  if type(exec_argv) ~= "function" then return runtime_port_unavailable("exec_argv")() end
  if type(file) ~= "table" or type(file.write) ~= "function" or type(file.read) ~= "function" then
    return runtime_port_unavailable("file")()
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then return runtime_port_unavailable("json.decode")() end

  local root = request_root(payload)
  if type(root) ~= "string" then error("environment-factory: runtime-request-root-missing: " .. name) end
  local label = safe_label(payload.effect_id or payload.operation_id or name)
  local io_root = root .. "/runtime-io"
  local request_path = io_root .. "/" .. safe_label(name) .. "-" .. label .. "-request.json"
  local response_path = io_root .. "/" .. safe_label(name) .. "-" .. label .. "-response.json"
  payload.runtime_config_ref = configured_runtime_ref(payload, root, options)
  file.write(request_path, json_codec.encode(payload) .. "\n")
  local argv = { "node", configured_runtime_cli(options), "effect", "--name", name, "--request", request_path, "--response", response_path }
  local exec_request = { argv = argv, timeout = timeout or 30 }
  if listener_options ~= nil then
    exec_request.listener_mode = "fkst-inherited-listeners-v1"
    exec_request.inherited_listeners = listener_options
  end
  local result = exec_argv(exec_request)
  local exit_code = type(result) == "table" and tonumber(result.exit_code) or nil
  if exit_code ~= 0 then
    local message = "environment-factory: runtime-effect-failed: " .. name .. " exit=" .. tostring(exit_code or -1) .. " stderr=" .. bounded_text(type(result) == "table" and result.stderr or "", 1024)
    error(message)
  end
  local ok, response = pcall(function() return json.decode(file.read(response_path)) end)
  if not ok or type(response) ~= "table" or response.ok ~= true then
    error("environment-factory: runtime-effect-invalid: " .. name)
  end
  return response.result
end

local function refs_match(left, right)
  return type(left) == "table" and type(right) == "table"
    and left.kind == right.kind and left.ref == right.ref
end

local function trusted_authorities(raw)
  local authorities = {}
  for _, value in ipairs(raw or {}) do
    local configured = value
    table.insert(authorities, {
      source_ref = configured.source_ref,
      policy_revision = configured.policy_revision,
      verify = function(request)
        local approval = type(request) == "table" and request.approval or nil
        if type(approval) ~= "table"
          or configured.authenticated ~= true
          or type(configured.approval_sha256) ~= "string"
          or configured.approval_sha256 ~= request.approval_sha256
          or not refs_match(configured.source_ref, approval.authority)
          or configured.policy_revision ~= approval.policy_revision
          or not refs_match(configured.evidence_ref, approval.evidence_ref) then
          return { authenticated = false }
        end
        return {
          authenticated = true,
          approval_sha256 = configured.approval_sha256,
          authority = { kind = configured.source_ref.kind, ref = configured.source_ref.ref },
          policy_revision = configured.policy_revision,
          evidence_ref = { kind = configured.evidence_ref.kind, ref = configured.evidence_ref.ref },
        }
      end,
    })
  end
  return authorities
end

local function cli_timeout(effect_timeout)
  local value = tonumber(effect_timeout) or 30
  if value < 1 then value = 1 end
  return math.min(value + 3, 14403)
end

local function listener_key(item)
  return tostring(item.name) .. "\0" .. tostring(item.port)
end

local function listener_group_key(group)
  local parts = {}
  for _, item in ipairs(group or {}) do table.insert(parts, listener_key(item)) end
  return table.concat(parts, "\1")
end

local function group_partition(group, needed, owned)
  local needs, has_owner = 0, 0
  for _, item in ipairs(group) do
    if needed[listener_key(item)] then needs = needs + 1 end
    if owned[listener_key(item)] then has_owner = has_owner + 1 end
  end
  if needs > 0 and has_owner > 0 then
    error("environment-factory: listener-group-invalid: group ownership is partial")
  end
  return needs > 0
end

local function plan_listener_claim(invoke, request)
  local plan = invoke("plan-listener-claim", {
    artifact_root = request.artifact_root,
    operation_id = request.operation_id,
    runtime_ports = copy_ports(request.runtime_ports),
  }, 15)
  if type(plan) ~= "table" or plan.status ~= "planned"
    or type(plan.needs_claim) ~= "table" or type(plan.already_owned) ~= "table" then
    error("environment-factory: listener-claim-plan-invalid: runtime did not return a claim partition")
  end
  local expected, actual = {}, {}
  for _, item in ipairs(request.runtime_ports or {}) do expected[listener_key(item)] = true end
  for _, group in ipairs({ plan.needs_claim, plan.already_owned }) do
    for _, item in ipairs(group) do
      local key = listener_key(item)
      if expected[key] ~= true or actual[key] then
        error("environment-factory: listener-claim-plan-invalid: partition differs from runtime_ports")
      end
      actual[key] = true
    end
  end
  for key, _ in pairs(expected) do
    if actual[key] ~= true then error("environment-factory: listener-claim-plan-invalid: partition is incomplete") end
  end
  local grouped = {}
  for _, group in ipairs(request.listener_groups or {}) do
    if type(group) ~= "table" or #group == 0 then
      error("environment-factory: listener-group-invalid: listener groups must be non-empty")
    end
    for _, item in ipairs(group) do
      local key = listener_key(item)
      if expected[key] ~= true or grouped[key] then
        error("environment-factory: listener-group-invalid: groups differ from runtime_ports")
      end
      grouped[key] = true
    end
  end
  for key, _ in pairs(expected) do
    if grouped[key] ~= true then error("environment-factory: listener-group-invalid: groups are incomplete") end
  end
  return plan
end

local function release_claim(group)
  if type(group) == "table" and type(group.claim) == "table"
    and type(group.claim.release) == "function" then
    pcall(group.claim.release, group.claim)
  end
end

local function release_listener_claims(operation_id)
  local active = active_listener_claims[operation_id]
  if type(active) == "table" then
    for _, group in pairs(active.groups or {}) do release_claim(group) end
  end
  active_listener_claims[operation_id] = nil
  if type(collectgarbage) == "function" then collectgarbage("collect") end
end

local function release_listener_group(operation_id, key)
  local active = active_listener_claims[operation_id]
  local group = type(active) == "table" and active.groups[key] or nil
  release_claim(group)
  if type(active) == "table" then
    active.groups[key] = nil
    if next(active.groups) == nil then active_listener_claims[operation_id] = nil end
  end
end

local function required_group_keys(request, needed, owned)
  local keys = {}
  for _, group in ipairs(request.listener_groups or {}) do
    if group_partition(group, needed, owned) then keys[listener_group_key(group)] = true end
  end
  return keys
end

local function acquire_listener_claims(request, plan)
  local needed, owned = {}, {}
  for _, item in ipairs(plan.needs_claim) do needed[listener_key(item)] = true end
  for _, item in ipairs(plan.already_owned) do owned[listener_key(item)] = true end
  local required = required_group_keys(request, needed, owned)
  local existing = active_listener_claims[request.operation_id]
  if type(existing) == "table" then
    for key, _ in pairs(required) do
      if type(existing.groups[key]) ~= "table" then
        release_listener_claims(request.operation_id)
        error("environment-factory: listener-claim-active: cached claim set is incomplete")
      end
    end
    for key, _ in pairs(existing.groups) do
      if required[key] ~= true then
        release_listener_claims(request.operation_id)
        error("environment-factory: listener-claim-active: cached claim set differs from plan")
      end
    end
    return existing
  end

  local active = { groups = {} }
  local ok, failure = pcall(function()
    for _, group in ipairs(request.listener_groups or {}) do
      local key = listener_group_key(group)
      if required[key] then
        local names = {}
        for _, item in ipairs(group) do names[item.name] = true end
        local claim = listener_capability().claim_loopback({
          owner_key = request.operation_id,
          listeners = copy_ports(group),
        })
        if type(claim) ~= "table" or type(claim.release) ~= "function" then
          error("environment-factory: listener-claim-invalid: claim must support deterministic release")
        end
        active.groups[key] = { claim = claim, names = names }
      end
    end
  end)
  if not ok then
    active_listener_claims[request.operation_id] = active
    release_listener_claims(request.operation_id)
    error(failure, 0)
  end
  if next(active.groups) ~= nil then active_listener_claims[request.operation_id] = active end
  return active
end

function R.production(options)
  local ports = {}
  local function invoke(name, payload, timeout, listener_options)
    return call_cli(name, payload, timeout, options, listener_options)
  end

  ports.load_state = function(ref)
    local result = invoke("load-state", { ref = ref }, 15)
    if type(result) ~= "table" then return nil end
    return result
  end

  ports.save_state = function(ref, state, expected_revision)
    return invoke("save-state", {
      ref = ref,
      state = state,
      expected_revision = expected_revision,
    }, 15)
  end

  ports.load_authorization_bundle = function(start)
    local bundle = invoke("load-authorization-bundle", { start = start }, 15)
    if type(bundle) ~= "table" or type(bundle.context) ~= "table" then return bundle end
    local raw_context = bundle.context
    bundle.context = {
      now = raw_context.now,
      approval_ref = raw_context.approval_ref,
      trusted_authorities = trusted_authorities(raw_context.trusted_authorities),
      sha256 = function(value)
        local result = invoke("sha256", { artifact_root = start.artifact_root, value = value }, 15)
        return result.digest
      end,
      replay_guard = function(claim)
        local pending = pending_claims[start.operation_id]
        if type(pending) ~= "table" then
          error("environment-factory: runtime-claim-context-missing: authorization claim has no pending effect")
        end
        local request = pending.request
        acquire_listener_claims(request, pending.plan)
        local ok, outcome = pcall(invoke, "authorize-claim-ports", {
          artifact_root = start.artifact_root,
          effect_id = request.effect_id,
          operation_id = request.operation_id,
          runtime_ports = request.runtime_ports,
          request_binding = request.request_binding,
          lookup_binding = pending.lookup_binding,
          replay_claim = claim,
          profile_snapshot = bundle.profile,
          listener_claimed_ports = copy_ports(pending.plan.needs_claim),
          listener_already_owned_ports = copy_ports(pending.plan.already_owned),
        }, 30)
        if not ok then
          release_listener_claims(request.operation_id)
          error(outcome, 0)
        end
        local claim_id = type(outcome) == "table" and outcome.claim_id or nil
        if type(outcome) == "table" then outcome.claim_id = nil end
        pending.outcome = outcome
        if type(outcome) ~= "table" or outcome.status ~= "passed" then
          release_listener_claims(request.operation_id)
          return { claimed = false, claim_id = "environment-factory-claim-blocked" }
        end
        return { claimed = true, claim_id = claim_id }
      end,
    }
    return bundle
  end

  ports.authorize_claim_ports = function(request)
    local lookup_binding = {
      effect_id = request.effect_id,
      operation_id = request.operation_id,
      artifact_root = request.artifact_root,
      runtime_ports = request.runtime_ports,
      request_binding = request.request_binding,
    }
    local plan = plan_listener_claim(invoke, request)
    local cached = invoke("lookup-effect", {
      artifact_root = request.artifact_root,
      effect_id = request.effect_id,
      lookup_binding = lookup_binding,
    }, 15)
    if type(cached) == "table" and cached.found == true then
      acquire_listener_claims(request, plan)
      local ok, verified = pcall(invoke, "authorize-claim-ports", {
        artifact_root = request.artifact_root,
        effect_id = request.effect_id,
        operation_id = request.operation_id,
        runtime_ports = copy_ports(request.runtime_ports),
        request_binding = request.request_binding,
        lookup_binding = lookup_binding,
        replay_claim = {},
        profile_snapshot = cached.outcome.profile_snapshot,
        listener_claimed_ports = copy_ports(plan.needs_claim),
        listener_already_owned_ports = copy_ports(plan.already_owned),
      }, 30)
      if not ok or type(verified) ~= "table" or verified.status ~= "passed" then
        release_listener_claims(request.operation_id)
      end
      if not ok then error(verified, 0) end
      return verified
    end

    local pending = { request = request, lookup_binding = lookup_binding, plan = plan }
    pending_claims[request.operation_id] = pending
    local ok, snapshot = pcall(request.authorize)
    pending_claims[request.operation_id] = nil
    if not ok then
      release_listener_claims(request.operation_id)
      error(snapshot, 0)
    end
    if type(pending.outcome) ~= "table" then
      release_listener_claims(request.operation_id)
      error("environment-factory: runtime-claim-outcome-missing: replay guard did not produce a claim outcome")
    end
    pending.outcome.profile_snapshot = snapshot
    return pending.outcome
  end

  ports.checkout = function(request) return invoke("checkout", request, cli_timeout(request.timeout_seconds)) end
  ports.remaining_budget = function(request)
    local result = invoke("remaining-budget", request, 15)
    return result.remaining_seconds
  end
  ports.create_readiness_attempt = function(request)
    return invoke("create-readiness-attempt", request, cli_timeout(request.timeout_seconds))
  end
  ports.run_argv = function(request)
    if request.mode ~= "supervised" then
      return invoke("run-argv", request, cli_timeout(request.timeout_seconds))
    end
    if request.listener_mode ~= "fkst-inherited-listeners-v1" then
      release_listener_claims(request.operation_id)
      error("environment-factory: listener-mode-invalid: supervised argv requires inherited listeners")
    end
    local key = listener_group_key(request.runtime_ports)
    local active = active_listener_claims[request.operation_id]
    local group = type(active) == "table" and active.groups[key] or nil
    if type(group) ~= "table" or type(group.claim) ~= "table" then
      release_listener_claims(request.operation_id)
      error("environment-factory: listener-claim-missing: supervised argv has no exact active listener group")
    end
    local names = {}
    for _, item in ipairs(request.runtime_ports or {}) do table.insert(names, item.name) end
    local ok, outcome = pcall(invoke, "run-argv", request, cli_timeout(request.timeout_seconds), {
      claim = group.claim,
      names = names,
    })
    release_listener_group(request.operation_id, key)
    if not ok then
      release_listener_claims(request.operation_id)
      error(outcome, 0)
    end
    if type(outcome) ~= "table" or outcome.status ~= "running" then
      release_listener_claims(request.operation_id)
    end
    return outcome
  end
  ports.wait_readiness = function(request)
    return invoke("wait-readiness", request, cli_timeout(request.timeout_seconds))
  end
  ports.cleanup = function(request)
    release_listener_claims(request.operation_id)
    return invoke("cleanup", request, cli_timeout(request.timeout_seconds))
  end
  ports.write_receipt = function(request)
    return invoke("write-receipt", request, cli_timeout(request.timeout_seconds))
  end

  return ports
end

R.call_cli = call_cli

return R
