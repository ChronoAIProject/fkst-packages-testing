local contract = require("contract.browser_readiness")

local M = {}

local function non_empty(value, limit)
  return type(value) == "string" and value ~= "" and #value <= (limit or 512)
end


local function deep_copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[deep_copy(key)] = deep_copy(item) end
  return out
end

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function joined(left, right)
  return left .. right
end

local function contains_credential_marker(value)
  local text = tostring(value or ""):lower()
  return text:match("^[a-z][a-z0-9+.-]*://[^/?#]*@") ~= nil
    or text:find(joined("pass", "word="), 1, true) ~= nil
    or text:find(joined("to", "ken="), 1, true) ~= nil
    or text:find("secret=", 1, true) ~= nil
    or text:find("authorization:", 1, true) ~= nil
    or text:find("bearer ", 1, true) ~= nil
end

local function local_url(value)
  if not non_empty(value, 512) or contains_credential_marker(value) then return false end
  return value:match("^https?://localhost[:/%?]") ~= nil
    or value:match("^https?://127%.0%.0%.1[:/%?]") ~= nil
    or value:match("^https?://%[::1%][:/%?]") ~= nil
end
M.local_url = local_url

local function command_name(value)
  if not non_empty(value, 256) then return nil end
  local first = tostring(value):match("^%s*(%S+)")
  if not non_empty(first, 256) then return nil end
  if first:find("[^%w%._%-%/]") ~= nil then return nil end
  return first
end
M.command_name = command_name

function M.validate_session(session)
  if type(session) ~= "table" then return false end
  if not non_empty(session.role, 80) then return false end
  local has_harness = non_empty(session.browser_harness_command, 256) or non_empty(session.browser_harness_command_env, 128)
  local has_cdp = non_empty(session.cdp_endpoint_env, 128)
    or (non_empty(session.cdp_url, 512) and not contains_credential_marker(session.cdp_url))
  return has_harness or has_cdp
end

function M.validate_request(payload)
  return contract.validate_request(payload)
end

local function default_probe()
  return {
    env = function(name)
      return os.getenv(name)
    end,
    command_exists = function(command)
      local name = command_name(command)
      if name == nil then return false end
      local ok = os.execute("command -v " .. shell_quote(name) .. " >/dev/null 2>&1")
      return ok == true or ok == 0
    end,
    local_http_ready = function(url)
      if not local_url(url) then return false end
      local ok = os.execute("curl -fsS --max-time 2 " .. shell_quote(url) .. " >/dev/null 2>&1")
      return ok == true or ok == 0
    end,
  }
end

local function check(status, name, reason)
  local item = { name = name, status = status }
  if reason ~= nil then item.reason = reason end
  return item
end

local function session_readiness(session, probe)
  local checks = {}

  if non_empty(session.browser_harness_command_env, 128) then
    local value = probe.env(session.browser_harness_command_env)
    if non_empty(value, 256) and probe.command_exists(value) then
      table.insert(checks, check("ready", "browser_harness_command_env"))
    else
      table.insert(checks, check("blocked", "browser_harness_command_env", "missing or unavailable command"))
    end
  elseif non_empty(session.browser_harness_command, 256) then
    if probe.command_exists(session.browser_harness_command) then
      table.insert(checks, check("ready", "browser_harness_command"))
    else
      table.insert(checks, check("blocked", "browser_harness_command", "missing command"))
    end
  end

  local resolved_cdp_url = nil
  if non_empty(session.cdp_endpoint_env, 128) then
    local value = probe.env(session.cdp_endpoint_env)
    if local_url(value) then
      resolved_cdp_url = value
      table.insert(checks, check("ready", "cdp_endpoint_env"))
    else
      table.insert(checks, check("blocked", "cdp_endpoint_env", "missing or non-local endpoint"))
    end
  elseif non_empty(session.cdp_url, 512) then
    if local_url(session.cdp_url) then
      resolved_cdp_url = session.cdp_url
      table.insert(checks, check("ready", "cdp_url"))
    else
      table.insert(checks, check("blocked", "cdp_url", "non-local endpoint"))
    end
  end

  local status = "ready"
  for _, item in ipairs(checks) do
    if item.status ~= "ready" then status = "blocked" end
  end
  if #checks == 0 then status = "blocked" end
  local result = { role = session.role, status = status, checks = checks }
  if resolved_cdp_url ~= nil then result.cdp_url = resolved_cdp_url end
  return result
end

local function overall_status(items)
  for _, item in ipairs(items) do
    if item.status ~= "ready" then return "blocked" end
  end
  return "ready"
end

local function forced_result(payload, status)
  local sessions = {}
  for _, session in ipairs(payload.sessions) do
    local item = { role = session.role, status = status or "planned" }
    if local_url(session.cdp_url) then item.cdp_url = session.cdp_url end
    table.insert(sessions, item)
  end
  return contract.validate_result({
    schema = "browser-readiness.result.v1",
    status = status or "planned",
    sessions = sessions,
    source_ref = payload.source_ref,
    request_context = payload.request_context,
    correlation = deep_copy(payload.correlation),
  })
end

function M.result(payload, opts)
  payload = M.validate_request(payload)
  if type(opts) == "string" then
    return forced_result(payload, opts)
  end

  opts = opts or {}
  local probe = opts.probe or payload.probe or default_probe()
  local items = {}
  if payload.base_url ~= nil then
    if local_url(payload.base_url) and probe.local_http_ready(payload.base_url) then
      table.insert(items, { role = "base_url", status = "ready", checks = { check("ready", "local_http") } })
    else
      table.insert(items, { role = "base_url", status = "blocked", checks = { check("blocked", "local_http", "base URL is unavailable or non-local") } })
    end
  end
  for _, session in ipairs(payload.sessions) do
    table.insert(items, session_readiness(session, probe))
  end
  return contract.validate_result({
    schema = "browser-readiness.result.v1",
    status = overall_status(items),
    sessions = items,
    source_ref = payload.source_ref,
    request_context = payload.request_context,
    correlation = deep_copy(payload.correlation),
  })
end

return M
