local contract = require("contract.environment_factory")

local O = {}

local function require_only(value, allowed, context)
  if type(value) ~= "table" then error("environment-factory: malformed-runtime-outcome: " .. context) end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then
      error("environment-factory: unsafe-runtime-outcome: " .. context .. " returned " .. tostring(key))
    end
  end
  return value
end

function O.authenticated_state(envelope)
  require_only(envelope, { authenticated = true, state = true, revision = true }, "state-envelope")
  if envelope.authenticated ~= true or type(envelope.state) ~= "table"
    or type(envelope.revision) ~= "number" or envelope.revision < 1
    or envelope.revision ~= math.floor(envelope.revision) then
    error("environment-factory: unauthenticated-state: durable artifact state is not an authorization capability")
  end
  local state = envelope.state
  state.storage_revision = envelope.revision
  return state
end

function O.exact_runtime_ports(expected, actual)
  if type(actual) ~= "table" then return false end
  local expected_set = contract.port_set_from_list(expected)
  local actual_set = contract.port_set_from_list(actual)
  for port, name in pairs(expected_set) do if actual_set[port] ~= name then return false end end
  for port, name in pairs(actual_set) do if expected_set[port] ~= name then return false end end
  return true
end

function O.validate_claim(request, outcome)
  require_only(outcome, {
    status = true,
    profile_snapshot = true,
    cleanup_ref = true,
    runtime_ports = true,
    deadline_epoch_seconds = true,
    diagnostic_ref = true,
    request_binding = true,
  }, "authorize_claim_ports")
  if outcome.status ~= "passed" then
    error("environment-factory: occupied-port: approved port lease failed")
  end
  contract.validate_profile_binding(request, outcome.profile_snapshot)
  if not contract.same_start_binding(outcome.request_binding, contract.start_binding(request)) then
    error("environment-factory: authorization-scope-mismatch: trusted port claim binds a different request")
  end
  contract.validate_ref(outcome.cleanup_ref, "port-claim.cleanup_ref")
  if not O.exact_runtime_ports(request.runtime_ports, outcome.runtime_ports) then
    error("environment-factory: missing-runtime-ports: lease did not bind the exact approved ports")
  end
  if type(outcome.deadline_epoch_seconds) ~= "number"
    or outcome.deadline_epoch_seconds ~= math.floor(outcome.deadline_epoch_seconds)
    or outcome.deadline_epoch_seconds < 1 then
    error("environment-factory: malformed-deadline: port claim must return a total lifecycle deadline")
  end
  if outcome.diagnostic_ref ~= nil then
    contract.validate_artifact_ref(outcome.diagnostic_ref, "port-claim.diagnostic_ref")
  end
  return outcome
end

function O.validate_checkout(outcome)
  require_only(outcome, {
    status = true,
    resolved_commit = true,
    workspace_ref = true,
    cleanup_ref = true,
    diagnostic_ref = true,
  }, "checkout")
  if outcome.workspace_ref ~= nil then contract.validate_ref(outcome.workspace_ref, "checkout.workspace_ref") end
  if outcome.cleanup_ref ~= nil then contract.validate_ref(outcome.cleanup_ref, "checkout.cleanup_ref") end
  if outcome.diagnostic_ref ~= nil then contract.validate_artifact_ref(outcome.diagnostic_ref, "checkout.diagnostic_ref") end
  if outcome.status == "passed" then
    if type(outcome.resolved_commit) ~= "string" or outcome.workspace_ref == nil or outcome.cleanup_ref == nil then
      error("environment-factory: malformed-checkout: successful checkout lacks exact acquisition metadata")
    end
  elseif outcome.status ~= "blocked" then
    error("environment-factory: checkout-failed: checkout returned an invalid status")
  end
  if outcome.resolved_commit ~= nil and #outcome.resolved_commit ~= 40 then
    error("environment-factory: source-mismatch: checkout did not report an exact commit")
  end
  return outcome
end

function O.validate_effect(outcome, context, allowed)
  require_only(outcome, allowed, context)
  contract.validate_runtime_outcome(outcome, context)
  return outcome
end

return O
