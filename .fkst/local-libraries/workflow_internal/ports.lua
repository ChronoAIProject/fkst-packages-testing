local M = {}

M.names = {
  actionable_epoch_resolve = "actionable_epoch_resolve",
  dependency_release_marker = "dependency_release_marker",
  is_state = "is_state",
  restart_durable_marker_fields = "restart_durable_marker_fields",
  restart_lifecycle_states = "restart_lifecycle_states",
  restart_responsibility_inventory_errors = "restart_responsibility_inventory_errors",
  restart_transition_table = "restart_transition_table",
  trusted_bot_login = "trusted_bot_login",
}

local types = {
  actionable_epoch_resolve = "function",
  dependency_release_marker = "function",
  is_state = "function",
  restart_durable_marker_fields = "function",
  restart_lifecycle_states = "table",
  restart_responsibility_inventory_errors = "function",
  restart_transition_table = "function",
  trusted_bot_login = "function",
}

M.optional = {
  [M.names.actionable_epoch_resolve] = true,
  [M.names.is_state] = true,
  [M.names.restart_durable_marker_fields] = true,
  [M.names.restart_lifecycle_states] = true,
  [M.names.restart_responsibility_inventory_errors] = true,
}

local groups = {
  restart_liveness_contract = {
    M.names.actionable_epoch_resolve,
    M.names.dependency_release_marker,
    M.names.is_state,
    M.names.restart_durable_marker_fields,
    M.names.restart_lifecycle_states,
    M.names.restart_responsibility_inventory_errors,
    M.names.restart_transition_table,
    M.names.trusted_bot_login,
  },
}

local function required_names(group_name, names)
  if names ~= nil then
    return names
  end
  local group = groups[group_name]
  if group == nil then
    error("workflow_internal.ports: port-group-unknown: unknown port group " .. tostring(group_name))
  end
  return group
end

local function require_ports(resolved, owner, names)
  local group_owner = owner or "workflow"
  if type(resolved) ~= "table" then
    error("workflow_internal.ports: resolved-ports-missing: missing resolved for " .. tostring(group_owner))
  end
  local source = resolved.workflow_ports
  if type(source) ~= "table" then
    error("workflow_internal.ports: workflow-ports-missing: missing resolved.workflow_ports for " .. tostring(group_owner))
  end

  local ports = {}
  for _, name in ipairs(required_names(group_owner, names)) do
    local value = source[name]
    local expected_type = types[name]
    if expected_type == nil then
      error("workflow_internal.ports: workflow-port-unknown: unknown port " .. tostring(name) .. " for " .. tostring(group_owner))
    end
    local missing_required = value == nil and M.optional[name] ~= true
    local wrong_type = value ~= nil and type(value) ~= expected_type
    if missing_required or wrong_type then
      error("workflow_internal.ports: workflow-port-unavailable: missing " .. expected_type .. " port " .. tostring(name) .. " for " .. tostring(group_owner))
    end
    if value ~= nil then
      ports[name] = value
    end
  end
  return { ports = ports }
end

function M.restart_liveness_contract(resolved)
  return require_ports(resolved, "restart_liveness_contract")
end

return M
