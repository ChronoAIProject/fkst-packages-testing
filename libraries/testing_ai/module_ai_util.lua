local strings = require("contract.strings")

local U = {}

local default_max_string = 512
local default_max_actions = 8

local forbidden_terms = {
  "raw_dom",
  "screenshot_body",
  "model_transcript",
  "browser_" .. "storage",
  "local" .. "storage",
  "session" .. "storage",
  "coo" .. "kie",
  "to" .. "ken",
  "pass" .. "word",
  "credential",
  "raw_prompt",
  "raw_response",
  "raw_report",
}

local blocked_route_terms = {
  "admin",
  "auth",
  "billing",
  "delete",
  "login",
  "logout",
  "oauth",
  "permissions",
  "remove",
}

function U.bounded_string(value, limit)
  if type(value) ~= "string" or value == "" then return false end
  if #value > (limit or default_max_string) then return false end
  return value:find("[%z\1-\31]") == nil
end

function U.dense_list(value)
  if type(value) ~= "table" then return false, 0 end
  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" then return false, 0 end
    if key < 1 or math.floor(key) ~= key then return false, 0 end
    count = count + 1
  end
  return count == #value, count
end

function U.validate_fields(value, allowed, context)
  local prefix = context or "testing-runner: malformed-ai-payload"
  for key, _ in pairs(value or {}) do
    if allowed[key] ~= true then error(prefix .. ": unsupported field") end
  end
end

function U.strip_url_detail(value, limit)
  local text = tostring(value or ""):gsub("[#?].*$", "")
  if #text > (limit or default_max_string) then text = text:sub(1, limit or default_max_string) end
  return text
end

function U.origin_from_url(value, limit)
  if not U.bounded_string(value, limit or default_max_string) then return nil end
  local scheme, authority = value:match("^(https?)://([^/%?#]+)")
  if scheme == nil then return nil end
  if authority == nil or authority == "" then return nil end
  if authority:find("%s") ~= nil then return nil end
  if authority:find("\\", 1, true) ~= nil then return nil end
  if authority:find("@", 1, true) ~= nil then return nil end
  return scheme:lower() .. "://" .. authority:lower()
end

function U.local_http_url(value)
  local authority = tostring(value or ""):match("^http://([^/%?#]+)")
  if authority == nil then return false end
  local bracketed = authority:match("^%[([^%]]+)%]")
  local host = bracketed ~= nil and bracketed or (authority:match("^([^:]+)") or authority)
  local normalized = host:lower()
  if normalized == "localhost" then return true end
  if normalized == "127.0.0.1" then return true end
  return normalized == "::1"
end

function U.safe_artifact_pointer(value, limit)
  local max = limit or default_max_string
  return U.bounded_string(value, max)
    and strings.is_path_safe_key(value, max)
    and value:sub(1, 14) == ".testing/runs/"
end

function U.copy_string_list(value, fallback, allowed, context, max_items)
  local source = value or fallback or {}
  local ok, count = U.dense_list(source)
  if not ok or count > (max_items or default_max_actions) then error(context .. " must be a bounded dense list") end
  local out = {}
  for _, item in ipairs(source) do
    if not U.bounded_string(item, default_max_string) or (allowed ~= nil and allowed[item] ~= true) then
      error(context .. " contains unsupported item")
    end
    table.insert(out, item)
  end
  return out
end

function U.set_from_list(value)
  local set = {}
  for _, item in ipairs(value or {}) do set[item] = true end
  return set
end

function U.stable_digest_seed(value, parts)
  parts = parts or {}
  local kind = type(value)
  if kind ~= "table" then table.insert(parts, kind .. ":" .. tostring(value)); return table.concat(parts, "\31") end
  if U.dense_list(value) then
    table.insert(parts, "["); for _, item in ipairs(value) do U.stable_digest_seed(item, parts) end; table.insert(parts, "]")
  else
    local keys = {}; for key, _ in pairs(value) do table.insert(keys, tostring(key)) end; table.sort(keys); table.insert(parts, "{")
    for _, key in ipairs(keys) do table.insert(parts, "key:" .. key); U.stable_digest_seed(value[key], parts) end
    table.insert(parts, "}")
  end
  return table.concat(parts, "\31")
end

function U.contains_forbidden(value)
  local kind = type(value)
  if kind == "string" then
    local text = value:lower()
    for _, term in ipairs(forbidden_terms) do
      if text:find(term, 1, true) ~= nil then return term end
    end
  elseif kind == "table" then
    for key, item in pairs(value) do
      local bad = U.contains_forbidden(key) or U.contains_forbidden(item)
      if bad ~= nil then return bad end
    end
  end
  return nil
end

function U.blocked_route_target(value)
  local text = tostring(value or ""):lower():gsub("[^%w]+", "/")
  for segment in text:gmatch("[^/]+") do
    for _, term in ipairs(blocked_route_terms) do
      if segment == term then return term end
    end
  end
  return nil
end

return U
