local J = {}

local strings = require("contract.strings")

local function is_array(value)
  local count, max_index = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return false end
    count = count + 1
    if key > max_index then max_index = key end
  end
  return count == max_index
end

function J.encode(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then return tostring(value) end
  if kind == "string" then return strings.json_string(value) end
  if kind ~= "table" then return strings.json_string(value) end

  local parts = {}
  if is_array(value) then
    for _, item in ipairs(value) do table.insert(parts, J.encode(item)) end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local keys = {}
  for key, _ in pairs(value) do table.insert(keys, tostring(key)) end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local escaped = strings.json_string(key):sub(2, -2)
    table.insert(parts, '"' .. escaped .. '":' .. J.encode(value[key]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

return J
