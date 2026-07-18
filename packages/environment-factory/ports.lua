local P = {}
local runtime = require("runtime")

local runtime_names = {
  "load_authorization_bundle",
  "authorize_claim_ports",
  "checkout",
  "remaining_budget",
  "create_readiness_attempt",
  "run_argv",
  "wait_readiness",
  "cleanup",
  "write_receipt",
}

local function unavailable(name)
  return function()
    error("environment-factory: runtime-port-unavailable: " .. name)
  end
end

local function dense_list(value)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    if key > highest then highest = key end
  end
  return count == highest
end

local function escape_json(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\b", "\\b")
  text = text:gsub("\f", "\\f")
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  text = text:gsub("[%z\1-\31]", function(char) return string.format("\\u%04x", char:byte()) end)
  return text
end

local function encode_json(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then return tostring(value) end
  if kind == "string" then return '"' .. escape_json(value) .. '"' end
  if kind ~= "table" then error("environment-factory: state-encode-failed: unsupported value type") end
  local parts = {}
  if dense_list(value) then
    for _, item in ipairs(value) do table.insert(parts, encode_json(item)) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for key, _ in pairs(value) do
    if type(key) ~= "string" then error("environment-factory: state-encode-failed: object keys must be strings") end
    table.insert(keys, key)
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    table.insert(parts, '"' .. escape_json(key) .. '":' .. encode_json(value[key]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function P.production()
  local host = rawget(_G, "environment_factory_runtime")
  if type(host) ~= "table" then return runtime.production() end
  local ports = {
    load_state = type(host.load_state) == "function" and host.load_state or unavailable("load_state"),
    save_state = type(host.save_state) == "function" and host.save_state or unavailable("save_state"),
  }
  for _, name in ipairs(runtime_names) do
    ports[name] = type(host[name]) == "function" and host[name] or unavailable(name)
  end
  return ports
end

function P.resolve(value)
  local ports = value or P.production()
  for _, name in ipairs({
    "load_state",
    "save_state",
    "load_authorization_bundle",
    "authorize_claim_ports",
    "checkout",
    "remaining_budget",
    "create_readiness_attempt",
    "run_argv",
    "wait_readiness",
    "cleanup",
    "write_receipt",
  }) do
    if type(ports[name]) ~= "function" then error("environment-factory: invalid-runtime: missing " .. name) end
  end
  return ports
end

P.encode_json = encode_json

return P
