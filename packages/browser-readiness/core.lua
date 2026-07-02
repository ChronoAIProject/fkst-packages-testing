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

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function local_origin(value)
  if not non_empty(value, 512) then return nil end
  local scheme, rest = value:match("^(https?)://(.+)$")
  if scheme == nil then return nil end
  local hostport = rest:match("^([^/%?#]+)")
  if hostport == nil or hostport == "" then return nil end
  local local_host = hostport == "localhost"
    or hostport:match("^localhost:%d+$") ~= nil
    or hostport == "127.0.0.1"
    or hostport:match("^127%.0%.0%.1:%d+$") ~= nil
    or hostport == "[::1]"
    or hostport:match("^%[::1%]:%d+$") ~= nil
  if not local_host then return nil end
  return scheme .. "://" .. hostport
end
M.local_origin = local_origin

local function local_url(value)
  return local_origin(value) ~= nil
end
M.local_url = local_url

local function allowed_origin_set(value)
  if value == nil then return nil, true end
  if not dense_list(value) or #value == 0 then return nil, false end
  local allowed = {}
  for _, item in ipairs(value) do
    local origin = local_origin(item)
    if origin == nil or origin ~= item then return nil, false end
    allowed[origin] = true
  end
  return allowed, true
end

local function base_url_allowed(url, allowed)
  local origin = local_origin(url)
  if origin == nil then return false end
  if allowed == nil then return true end
  return allowed[origin] == true
end

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
  local has_cdp = non_empty(session.cdp_endpoint_env, 128) or non_empty(session.cdp_url, 512)
  return has_harness or has_cdp
end

local context_keys = {
  native_argv = true,
  dry_run = true,
  no_browser = true,
}

local function validate_native_argv(value)
  if value == nil then return end
  if not dense_list(value) or #value == 0 then
    error("browser-readiness: malformed-request: request_context.native_argv must be a non-empty dense list")
  end
  for _, item in ipairs(value) do
    if not non_empty(item, 512) then
      error("browser-readiness: malformed-request: request_context.native_argv items must be bounded strings")
    end
  end
end

local function validate_request_context(value)
  if value == nil then return end
  if type(value) ~= "table" then
    error("browser-readiness: malformed-request: request_context must be a table")
  end
  for key, _ in pairs(value) do
    if context_keys[key] ~= true then
      error("browser-readiness: malformed-request: request_context has unsupported field")
    end
  end
  validate_native_argv(value.native_argv)
  if value.dry_run ~= nil and type(value.dry_run) ~= "boolean" then
    error("browser-readiness: malformed-request: request_context.dry_run must be boolean")
  end
  if value.no_browser ~= nil and type(value.no_browser) ~= "boolean" then
    error("browser-readiness: malformed-request: request_context.no_browser must be boolean")
  end
end

function M.validate_request(payload)
  if type(payload) ~= "table" then
    error("browser-readiness: malformed-request: payload must be a table")
  end
  if payload.schema ~= "browser-readiness.check.v1" then
    error("browser-readiness: unknown-schema: expected browser-readiness.check.v1")
  end
  if payload.base_url ~= nil and not non_empty(payload.base_url, 512) then
    error("browser-readiness: malformed-request: base_url is too large")
  end
  if payload.allowed_origins ~= nil then
    if not dense_list(payload.allowed_origins) or #payload.allowed_origins == 0 then
      error("browser-readiness: malformed-request: allowed_origins must be a non-empty dense list")
    end
    for _, origin in ipairs(payload.allowed_origins) do
      if not non_empty(origin, 512) or local_origin(origin) ~= origin then
        error("browser-readiness: malformed-request: allowed_origins items must be local origins")
      end
    end
  end
  if not dense_list(payload.sessions) or #payload.sessions == 0 then
    error("browser-readiness: malformed-request: sessions must be a non-empty dense list")
  end
  for _, session in ipairs(payload.sessions) do
    if not M.validate_session(session) then
      error("browser-readiness: malformed-request: invalid session")
    end
  end
  validate_request_context(payload.request_context)
  return payload
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

  if non_empty(session.cdp_endpoint_env, 128) then
    local value = probe.env(session.cdp_endpoint_env)
    if local_url(value) then
      table.insert(checks, check("ready", "cdp_endpoint_env"))
    else
      table.insert(checks, check("blocked", "cdp_endpoint_env", "missing or non-local endpoint"))
    end
  elseif non_empty(session.cdp_url, 512) then
    if local_url(session.cdp_url) then
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
  return { role = session.role, status = status, checks = checks }
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
    table.insert(sessions, { role = session.role, status = status or "planned" })
  end
  return {
    schema = "browser-readiness.result.v1",
    status = status or "planned",
    sessions = sessions,
    source_ref = payload.source_ref,
    request_context = payload.request_context,
  }
end

function M.result(payload, opts)
  payload = M.validate_request(payload)
  if type(opts) == "string" then
    return forced_result(payload, opts)
  end

  opts = opts or {}
  local probe = opts.probe or payload.probe or default_probe()
  local items = {}
  local allowed, allowed_valid = allowed_origin_set(payload.allowed_origins)
  if payload.base_url ~= nil then
    if allowed_valid and base_url_allowed(payload.base_url, allowed) and probe.local_http_ready(payload.base_url) then
      table.insert(items, { role = "base_url", status = "ready", checks = { check("ready", "local_http") } })
    else
      table.insert(items, {
        role = "base_url",
        status = "blocked",
        checks = { check("blocked", "local_http", "base URL is unavailable, non-local, or outside allowed origins") },
      })
    end
  end
  for _, session in ipairs(payload.sessions) do
    table.insert(items, session_readiness(session, probe))
  end
  return {
    schema = "browser-readiness.result.v1",
    status = overall_status(items),
    sessions = items,
    source_ref = payload.source_ref,
    request_context = payload.request_context,
  }
end

return M
