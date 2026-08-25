local internal = require("workflow_internal.codex")

local M = setmetatable({}, { __index = internal })

local role_aliases = {
  ["testing-ai-author"] = "implement",
  ["testing-ai-design-author"] = "implement",
  ["testing-ai-browser-turn"] = "judgment",
}

local function mapped_identity(identity)
  if type(identity) ~= "table" or role_aliases[identity.role] == nil then return identity end
  local mapped = {}
  for key, value in pairs(identity) do mapped[key] = value end
  mapped.role = role_aliases[identity.role]
  return mapped
end

local function restore_role(result, internal_role, original_role)
  if type(result) ~= "table" then return result end
  if result.role == internal_role then result.role = original_role end
  if type(result.identity) == "table" and result.identity.role == internal_role then
    result.identity.role = original_role
  end
  return result
end

function M.live_run_active(identity_or_role, proposal_id, dedup_key)
  if type(identity_or_role) == "table" then
    return internal.live_run_active(mapped_identity(identity_or_role))
  end
  return internal.live_run_active(role_aliases[identity_or_role] or identity_or_role, proposal_id, dedup_key)
end

function M.dispatch(identity, opts)
  if type(identity) ~= "table" then return internal.dispatch(identity, opts) end
  local original_role = identity.role
  local mapped = mapped_identity(identity)
  if mapped == identity then return internal.dispatch(identity, opts) end
  return restore_role(internal.dispatch(mapped, opts), mapped.role, original_role)
end

return M
