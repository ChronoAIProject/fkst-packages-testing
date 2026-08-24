-- contract.sweep: pure leaf utilities (bounds, rotation offset, cursor batching,
-- deferred-result shapes) shared across packages. Only genuine leaves live here:
-- functions whose original package bodies contained no late-bound `M.*`
-- call into another facade function. The `rotate`/`batch` orchestrators stay in
-- the package facade so their `M.sweep_rotate -> M.sweep_rotation_offset` and
-- `M.sweep_batch -> M.sweep_rotate` late-binding remains byte-for-byte observable.
local S = {}
local strings = require("contract.strings")
local decimal_checksum = strings.decimal_checksum

function S.positive_integer(value, fallback, minimum, maximum)
  local n = tonumber(value)
  if n == nil or n ~= math.floor(n) or n < minimum or n > maximum then
    return fallback
  end
  return n
end

function S.rotation_offset(count, seed)
  local n = tonumber(count)
  if n == nil or n <= 0 then
    return 0
  end
  local numeric_seed = tonumber(seed)
  if numeric_seed ~= nil and numeric_seed == math.floor(numeric_seed) then
    return numeric_seed % n
  end
  local hash = decimal_checksum(tostring(seed or ""))
  return tonumber(hash) % n
end

local function numeric_cursor_key(item, key_of)
  local value = type(key_of) == "function" and key_of(item) or item
  local key = tonumber(value)
  if key == nil or key < 0 or key ~= math.floor(key) then
    error("workflow-internal: sweep-cursor-key-invalid: workflow_internal.sweep: cursor key must be a non-negative integer")
  end
  return key
end

local function optional_cursor_key(value)
  local key = tonumber(value)
  if key == nil or key < 0 or key ~= math.floor(key) then
    return nil
  end
  return key
end

local function maximum_cursor_key(source, key_of)
  local maximum = nil
  for _, item in ipairs(source) do
    local key = numeric_cursor_key(item, key_of)
    if maximum == nil or key > maximum then
      maximum = key
    end
  end
  return maximum
end

local function next_cursor_index(source, selected_indexes, cursor_key, high_water, key_of)
  for index, item in ipairs(source) do
    local key = numeric_cursor_key(item, key_of)
    if not selected_indexes[index]
      and key <= high_water
      and (cursor_key == nil or key > cursor_key) then
      return index, key
    end
  end
  return nil, nil
end

function S.cursor_batch(items, cursor, cap, default_cap, key_of, high_water)
  local source = items or {}
  local count = #source
  local bounded_cap = S.positive_integer(cap, default_cap or 25, 1, 1000)
  if count == 0 then
    return {}, 0, nil, nil, {}
  end

  local cursor_key = optional_cursor_key(cursor)
  local current_high_water = maximum_cursor_key(source, key_of)
  local cycle_high_water = optional_cursor_key(high_water) or current_high_water

  local selected = {}
  local selected_indexes = {}
  local progress = {}
  for i = 1, math.min(count, bounded_cap) do
    local index, key = next_cursor_index(
      source,
      selected_indexes,
      cursor_key,
      cycle_high_water,
      key_of
    )
    if index == nil then
      cursor_key = nil
      cycle_high_water = current_high_water
      index, key = next_cursor_index(
        source,
        selected_indexes,
        cursor_key,
        cycle_high_water,
        key_of
      )
    end
    if index == nil then
      break
    end
    selected_indexes[index] = true
    table.insert(selected, source[index])
    cursor_key = key
    table.insert(progress, {
      cursor_key = cursor_key,
      high_water = cycle_high_water,
    })
  end

  local checkpoint = progress[#progress]
  return selected,
    math.max(0, count - #selected),
    checkpoint and checkpoint.cursor_key or nil,
    checkpoint and checkpoint.high_water or nil,
    progress
end

function S.cursor_advance(progress, processed)
  local checkpoints = progress or {}
  local step = tonumber(processed) or 0
  if step < 0 or step ~= math.floor(step) then
    step = 0
  end
  step = math.min(step, #checkpoints)
  if step == 0 then
    return nil, nil
  end
  local checkpoint = checkpoints[step]
  return numeric_cursor_key(checkpoint.cursor_key), numeric_cursor_key(checkpoint.high_water)
end

function S.deadline_deferred_result(error_class, stderr)
  return {
    deferred = true,
    reason = "deadline",
    error_class = tostring(error_class or "sweep command"),
    stdout = "",
    stderr = tostring(stderr or "sweep deadline exhausted"),
    exit_code = 0,
  }
end

function S.result_deferred(result)
  return type(result) == "table" and result.deferred == true
end

return S
