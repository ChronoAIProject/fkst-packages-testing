local J = {}

local function escape(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\b", "\\b")
  text = text:gsub("\f", "\\f")
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  text = text:gsub("[%z\1-\31]", function(char)
    return string.format("\\u%04x", char:byte())
  end)
  return text
end

local function is_array(value)
  local count, highest = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    if key > highest then highest = key end
  end
  return count == highest
end

function J.encode(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then return tostring(value) end
  if kind == "string" then return '"' .. escape(value) .. '"' end
  if kind ~= "table" then error("testing-runtime: json-encode-unsupported: " .. kind) end

  local parts = {}
  if is_array(value) then
    for _, item in ipairs(value) do table.insert(parts, J.encode(item)) end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local keys = {}
  for key, _ in pairs(value) do
    if type(key) ~= "string" then error("testing-runtime: json-encode-key: object keys must be strings") end
    table.insert(keys, key)
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    table.insert(parts, '"' .. escape(key) .. '":' .. J.encode(value[key]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

return J
