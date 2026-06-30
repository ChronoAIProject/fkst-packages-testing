local M = {}

local function non_empty(value, limit)
  return type(value) == "string" and value ~= "" and #value <= (limit or 512)
end

local function dense_list(value)
  if type(value) ~= "table" then return false end
  local seen = 0
  for index, _ in pairs(value) do
    if type(index) ~= "number" or index < 1 or index % 1 ~= 0 then return false end
    if index > seen then seen = index end
  end
  for index = 1, seen do
    if value[index] == nil then return false end
  end
  return true
end

function M.validate_session(session)
  if type(session) ~= "table" then return false end
  if not non_empty(session.role, 80) then return false end
  local has_harness = non_empty(session.browser_harness_command, 256)
  local has_cdp = non_empty(session.cdp_endpoint_env, 128) or non_empty(session.cdp_url, 512)
  return has_harness or has_cdp
end

function M.validate_request(payload)
  if type(payload) ~= "table" then
    error("browser-readiness: malformed-request: payload must be a table")
  end
  if payload.schema ~= "browser-readiness.check.v1" then
    error("browser-readiness: unknown-schema: expected browser-readiness.check.v1")
  end
  if not dense_list(payload.sessions) or #payload.sessions == 0 then
    error("browser-readiness: malformed-request: sessions must be a non-empty dense list")
  end
  for _, session in ipairs(payload.sessions) do
    if not M.validate_session(session) then
      error("browser-readiness: malformed-request: invalid session")
    end
  end
  return payload
end

function M.result(payload, status)
  payload = M.validate_request(payload)
  local sessions = {}
  for _, session in ipairs(payload.sessions) do
    table.insert(sessions, { role = session.role, status = status or "planned" })
  end
  return {
    schema = "browser-readiness.result.v1",
    status = status or "planned",
    sessions = sessions,
    source_ref = payload.source_ref,
  }
end

return M
