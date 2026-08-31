-- contract.canonical_json: deterministic UTF-8 JSON bytes for contract identities.
local M = {}

local array_type = {}
local object_type = {}
M.null = {}
M.max_integer = 9007199254740991
M.min_integer = -M.max_integer

local escapes = {
  [8] = "\\b",
  [9] = "\\t",
  [10] = "\\n",
  [12] = "\\f",
  [13] = "\\r",
  [34] = '\\"',
  [92] = "\\\\",
}

local function fail(message)
  error("contract.canonical-json: canonicalization-failed: " .. message)
end

local function require_table(value, kind)
  if type(value) ~= "table" or value == M.null then
    fail(kind .. " value must be a table")
  end
  return value
end

function M.array(value)
  if value == nil then value = {} end
  return setmetatable(require_table(value, "array"), array_type)
end

function M.object(value)
  if value == nil then value = {} end
  return setmetatable(require_table(value, "object"), object_type)
end

local function continuation(byte)
  return byte ~= nil and byte >= 0x80 and byte <= 0xbf
end

function M.is_valid_utf8(value)
  local index = 1
  while index <= #value do
    local first = value:byte(index)
    if first <= 0x7f then
      index = index + 1
    elseif first >= 0xc2 and first <= 0xdf then
      if not continuation(value:byte(index + 1)) then return false end
      index = index + 2
    elseif first == 0xe0 then
      local second, third = value:byte(index + 1), value:byte(index + 2)
      if second == nil or second < 0xa0 or second > 0xbf or not continuation(third) then return false end
      index = index + 3
    elseif (first >= 0xe1 and first <= 0xec) or (first >= 0xee and first <= 0xef) then
      if not continuation(value:byte(index + 1)) or not continuation(value:byte(index + 2)) then return false end
      index = index + 3
    elseif first == 0xed then
      local second, third = value:byte(index + 1), value:byte(index + 2)
      if second == nil or second < 0x80 or second > 0x9f or not continuation(third) then return false end
      index = index + 3
    elseif first == 0xf0 then
      local second = value:byte(index + 1)
      if second == nil or second < 0x90 or second > 0xbf
          or not continuation(value:byte(index + 2)) or not continuation(value:byte(index + 3)) then return false end
      index = index + 4
    elseif first >= 0xf1 and first <= 0xf3 then
      if not continuation(value:byte(index + 1)) or not continuation(value:byte(index + 2))
          or not continuation(value:byte(index + 3)) then return false end
      index = index + 4
    elseif first == 0xf4 then
      local second = value:byte(index + 1)
      if second == nil or second < 0x80 or second > 0x8f
          or not continuation(value:byte(index + 2)) or not continuation(value:byte(index + 3)) then return false end
      index = index + 4
    else
      return false
    end
  end
  return true
end

local function encode_string(value)
  if not M.is_valid_utf8(value) then fail("strings must contain valid UTF-8") end
  local parts = { '"' }
  local start = 1
  for index = 1, #value do
    local byte = value:byte(index)
    local escaped = escapes[byte]
    if escaped ~= nil or byte < 0x20 then
      if start < index then parts[#parts + 1] = value:sub(start, index - 1) end
      parts[#parts + 1] = escaped or string.format("\\u%04x", byte)
      start = index + 1
    end
  end
  if start <= #value then parts[#parts + 1] = value:sub(start) end
  parts[#parts + 1] = '"'
  return table.concat(parts)
end

local function table_kind(value)
  local tagged = getmetatable(value)
  if tagged == array_type then return "array" end
  if tagged == object_type then return "object" end
  if tagged ~= nil then fail("tables must not have unsupported metatables") end

  local count, highest, inferred = 0, 0, nil
  for key in pairs(value) do
    local key_kind = type(key)
    if key_kind == "number" and key >= 1 and key == math.floor(key) then
      if inferred == "object" then fail("tables must not mix array and object keys") end
      inferred = "array"
      count = count + 1
      highest = math.max(highest, key)
    elseif key_kind == "string" then
      if inferred == "array" then fail("tables must not mix array and object keys") end
      inferred = "object"
    else
      fail("object keys must be strings and array indexes must be positive integers")
    end
  end
  if inferred == "array" and count ~= highest then fail("arrays must be dense") end
  return inferred or "array"
end

function M.encode(value)
  local active = {}

  local function encode(item)
    if item == M.null then return "null" end
    local kind = type(item)
    if kind == "nil" then return "null" end
    if kind == "boolean" then return item and "true" or "false" end
    if kind == "number" then
      if item ~= item or item == math.huge or item == -math.huge or item ~= math.floor(item)
          or item < M.min_integer or item > M.max_integer then
        fail("numbers must be integers in the inclusive safe range")
      end
      if item == 0 then return "0" end
      return string.format("%.0f", item)
    end
    if kind == "string" then return encode_string(item) end
    if kind ~= "table" then fail("unsupported value type " .. kind) end
    if active[item] then fail("cyclic tables are not supported") end
    active[item] = true

    local container = table_kind(item)
    local parts = {}
    if container == "array" then
      local count = 0
      for key in pairs(item) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then fail("array indexes must be positive integers") end
        count = count + 1
      end
      for index = 1, count do
        if item[index] == nil then fail("arrays must be dense") end
        parts[index] = encode(item[index])
      end
      active[item] = nil
      return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for key in pairs(item) do
      if type(key) ~= "string" then fail("object keys must be strings") end
      if not M.is_valid_utf8(key) then fail("object keys must contain valid UTF-8") end
      keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do parts[#parts + 1] = encode_string(key) .. ":" .. encode(item[key]) end
    active[item] = nil
    return "{" .. table.concat(parts, ",") .. "}"
  end

  return encode(value)
end

return M
