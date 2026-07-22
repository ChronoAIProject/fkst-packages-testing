local strings = require("contract.strings")

local M = {}

M.schemas = {
  request = "browser-readiness.check.v1",
  result = "browser-readiness.result.v1",
}

local function fail(classification, message)
  error("contract.browser-readiness: " .. classification .. ": " .. message)
end

local function bounded(value, limit)
  return strings.is_bounded_string(value, limit or 512)
    and value:find("[%z\1-\31\127]") == nil
end

local function only_fields(value, allowed, label)
  if type(value) ~= "table" then fail("malformed-" .. label, label .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then fail("malformed-" .. label, "unsupported field " .. tostring(key)) end
  end
end

local function dense(value, limit, non_empty)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    highest = math.max(highest, key)
  end
  return count == highest and count <= limit and (not non_empty or count > 0)
end

local function contains_credential_marker(value)
  local text = tostring(value or ""):lower()
  return text:match("^[a-z][a-z0-9+.-]*://[^/?#]*@") ~= nil
    or text:find("password=", 1, true) ~= nil
    or text:find("token=", 1, true) ~= nil
    or text:find("secret=", 1, true) ~= nil
    or text:find("authorization:", 1, true) ~= nil
    or text:find("bearer ", 1, true) ~= nil
end

local function local_url(value)
  if not bounded(value, 512) or contains_credential_marker(value) then return false end
  return value:match("^https?://localhost[:/%?]") ~= nil
    or value:match("^https?://127%.0%.0%.1[:/%?]") ~= nil
    or value:match("^https?://%[::1%][:/%?]") ~= nil
end
M.local_url = local_url

local function validate_ref(value, label)
  if value == nil then return nil end
  only_fields(value, { kind = true, ref = true }, label)
  if not bounded(value.kind, 80) or not bounded(value.ref, 2048) then
    fail("malformed-reference", label .. " must contain bounded kind and ref")
  end
  return value
end

local request_session_fields = {
  role = true,
  browser_harness_command = true,
  browser_harness_command_env = true,
  cdp_endpoint_env = true,
  cdp_url = true,
}

function M.validate_session(value)
  only_fields(value, request_session_fields, "session")
  if not bounded(value.role, 80) then fail("malformed-session", "session role is required") end
  local harness = bounded(value.browser_harness_command, 256)
    or bounded(value.browser_harness_command_env, 128)
  local cdp = bounded(value.cdp_endpoint_env, 128)
    or (bounded(value.cdp_url, 512) and not contains_credential_marker(value.cdp_url))
  if not harness and not cdp then
    fail("malformed-session", "session requires a browser harness or CDP source")
  end
  return value
end

local context_fields = { native_argv = true, dry_run = true, no_browser = true }

function M.validate_request_context(value)
  if value == nil then return nil end
  only_fields(value, context_fields, "request-context")
  if value.native_argv ~= nil then
    if not dense(value.native_argv, 32, true) then
      fail("malformed-request-context", "native_argv must be a non-empty bounded list")
    end
    for _, item in ipairs(value.native_argv) do
      if not bounded(item, 512) then fail("malformed-request-context", "native_argv item is invalid") end
    end
  end
  if value.dry_run ~= nil and type(value.dry_run) ~= "boolean" then
    fail("malformed-request-context", "dry_run must be boolean")
  end
  if value.no_browser ~= nil and type(value.no_browser) ~= "boolean" then
    fail("malformed-request-context", "no_browser must be boolean")
  end
  return value
end

local forbidden_correlation_keys = {
  cookie = true, cookies = true, storage = true, localstorage = true,
  sessionstorage = true, stdout = true, stderr = true, output = true,
  body = true, screenshot = true, password = true, token = true,
  secret = true, authorization = true, api_key = true,
}

function M.validate_correlation(value)
  if value == nil then return nil end
  if type(value) ~= "table" then fail("malformed-correlation", "correlation must be a table") end
  local count = 0
  local function walk(item, depth)
    if depth > 6 then fail("malformed-correlation", "correlation exceeds maximum depth") end
    local kind = type(item)
    if kind == "string" then
      if not bounded(item, 1024) or contains_credential_marker(item) then
        fail("malformed-correlation", "correlation contains an unsafe string")
      end
      return
    end
    if kind == "boolean" then return end
    if kind == "number" then
      if item ~= item or item == math.huge or item == -math.huge then
        fail("malformed-correlation", "correlation contains an invalid number")
      end
      return
    end
    if kind ~= "table" then fail("malformed-correlation", "correlation contains an unsupported value") end
    local list = dense(item, 64, false)
    for key, nested in pairs(item) do
      count = count + 1
      if count > 64 then fail("malformed-correlation", "correlation has too many items") end
      if not list then
        if not bounded(key, 128) then fail("malformed-correlation", "correlation key is invalid") end
        local normalized = key:lower()
        if forbidden_correlation_keys[normalized]
          or normalized:find("cookie", 1, true) or normalized:find("storage", 1, true) then
          fail("malformed-correlation", "correlation contains a forbidden field")
        end
      end
      walk(nested, depth + 1)
    end
  end
  walk(value, 1)
  return value
end

function M.validate_request(value)
  only_fields(value, {
    schema = true, base_url = true, sessions = true, request_context = true,
    source_ref = true, correlation = true,
  }, "request")
  if value.schema ~= M.schemas.request then fail("unknown-schema", "expected " .. M.schemas.request) end
  if value.base_url ~= nil and not bounded(value.base_url, 512) then
    fail("malformed-request", "base_url is invalid")
  end
  if not dense(value.sessions, 16, true) then fail("malformed-request", "sessions must be non-empty and bounded") end
  for _, session in ipairs(value.sessions) do M.validate_session(session) end
  M.validate_request_context(value.request_context)
  M.validate_correlation(value.correlation)
  validate_ref(value.source_ref, "source-ref")
  return value
end

local result_statuses = { ready = true, blocked = true, planned = true }

local function validate_check(value)
  only_fields(value, { name = true, status = true, reason = true }, "result-check")
  if not bounded(value.name, 128) or not result_statuses[value.status]
    or (value.reason ~= nil and not bounded(value.reason, 512)) then
    fail("malformed-result-check", "readiness check is invalid")
  end
end

local function validate_result_session(value)
  only_fields(value, { role = true, status = true, checks = true, cdp_url = true }, "result-session")
  if not bounded(value.role, 80) or not result_statuses[value.status] then
    fail("malformed-result-session", "result session identity is invalid")
  end
  if value.checks ~= nil then
    if not dense(value.checks, 16, false) then fail("malformed-result-session", "checks must be bounded") end
    for _, item in ipairs(value.checks) do validate_check(item) end
  end
  if value.cdp_url ~= nil and not local_url(value.cdp_url) then
    fail("malformed-result-session", "resolved CDP URL must be local")
  end
end

function M.validate_result(value)
  only_fields(value, {
    schema = true, status = true, sessions = true, source_ref = true,
    request_context = true, correlation = true,
  }, "result")
  if value.schema ~= M.schemas.result or not result_statuses[value.status]
    or not dense(value.sessions, 17, true) then
    fail("malformed-result", "result schema, status, or sessions are invalid")
  end
  for _, session in ipairs(value.sessions) do validate_result_session(session) end
  validate_ref(value.source_ref, "source-ref")
  M.validate_request_context(value.request_context)
  M.validate_correlation(value.correlation)
  return value
end

function M.copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[M.copy(key)] = M.copy(item) end
  return out
end

function M.equal(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, item in pairs(left) do if not M.equal(item, right[key]) then return false end end
  for key, _ in pairs(right) do if left[key] == nil then return false end end
  return true
end

return M
