-- contract.error_facts: dependency-free primitives for stable failure fingerprints.
local F = {}

F.ERROR_ENVELOPE_GRAMMAR = {
  subsystem_segment_initial = "abcdefghijklmnopqrstuvwxyz0123456789",
  subsystem_segment_rest = "abcdefghijklmnopqrstuvwxyz0123456789-_",
  hierarchy_separator = ".",
  component_separator = ": ",
  class_initial = "abcdefghijklmnopqrstuvwxyz0123456789",
  class_rest = "abcdefghijklmnopqrstuvwxyz0123456789-",
  class_terminator = ":",
  fallback = "caught-failure",
}

local error_envelope_grammar = F.ERROR_ENVELOPE_GRAMMAR

local function contains_character(allowed, character)
  return allowed:find(character, 1, true) ~= nil
end

local function valid_token(value, initial, rest)
  if value == "" or not contains_character(initial, value:sub(1, 1)) then
    return false
  end
  for index = 2, #value do
    if not contains_character(rest, value:sub(index, index)) then
      return false
    end
  end
  return true
end

local function valid_subsystem(value)
  local start_index = 1
  while true do
    local separator_index = value:find(error_envelope_grammar.hierarchy_separator, start_index, true)
    local end_index = separator_index and separator_index - 1 or #value
    if not valid_token(
      value:sub(start_index, end_index),
      error_envelope_grammar.subsystem_segment_initial,
      error_envelope_grammar.subsystem_segment_rest
    ) then
      return false
    end
    if separator_index == nil then
      return true
    end
    start_index = separator_index + #error_envelope_grammar.hierarchy_separator
  end
end

local function strip_position_prefix(text)
  local current = text
  for _ = 1, 8 do
    local rest = current:match("^[^\n]-:%d+: (.*)$")
    if rest == nil or rest == current then break end
    current = rest
  end
  return current
end

function F.error_class_from_message(message)
  local text = strip_position_prefix(tostring(message or ""))
  local subsystem_end = text:find(error_envelope_grammar.component_separator, 1, true)
  if subsystem_end == nil or not valid_subsystem(text:sub(1, subsystem_end - 1)) then
    return error_envelope_grammar.fallback
  end
  local class_start = subsystem_end + #error_envelope_grammar.component_separator
  local class_end = text:find(error_envelope_grammar.class_terminator, class_start, true)
  local error_class = class_end and text:sub(class_start, class_end - 1) or ""
  if not valid_token(error_class, error_envelope_grammar.class_initial, error_envelope_grammar.class_rest) then
    return error_envelope_grammar.fallback
  end
  return error_class
end

function F.error_message(subsystem, error_class, message)
  local subsystem_text = tostring(subsystem or "")
  local class_text = tostring(error_class or "")
  if not valid_subsystem(subsystem_text) then
    subsystem_text = "contract.error-facts"
    class_text = "invalid-subsystem"
  elseif not valid_token(class_text, error_envelope_grammar.class_initial, error_envelope_grammar.class_rest) then
    class_text = error_envelope_grammar.fallback
  end
  return subsystem_text .. error_envelope_grammar.component_separator .. class_text
    .. error_envelope_grammar.class_terminator .. " " .. tostring(message or "")
end

function F.one_line(value)
  return tostring(value or ""):gsub("%s+", " ")
end

function F.normalized_message(value)
  local text = F.one_line(value):lower()
  text = text:gsub("%d%d%d%d%-%d%d%-%d%d[tT ]%d%d:%d%d:%d%d%.?%d*Z?", "<time>")
  text = text:gsub("%f[%x]%x%x%x%x%x%x[%x]+%f[^%x]", "<sha>")
  text = text:gsub("/tmp/[^%s]+", "<path>")
  text = text:gsub("/var/folders/[^%s]+", "<path>")
  text = text:gsub("%s+", " ")
  return text
end

F.normalized_error_message = F.normalized_message

function F.stable_hash(value)
  local hash = 5381
  for index = 1, #value do
    hash = (hash * 33 + value:byte(index)) % 2147483647
  end
  return "fp-" .. tostring(hash)
end

function F.source_ref_field(source_ref)
  if type(source_ref) == "table" then
    return F.one_line(source_ref.kind) .. ":" .. F.one_line(source_ref.ref)
  end
  if source_ref ~= nil then
    return F.one_line(source_ref)
  end
  return nil
end

function F.error_fingerprint(error_class, queue, dept, message)
  return F.stable_hash(table.concat({
    tostring(error_class or "unknown-error"),
    tostring(queue or ""),
    tostring(dept or ""),
    F.normalized_message(message),
  }, "|"))
end

function F.error_fact_fields(error_class, queue, dept, message, context)
  local fields = {
    "error_class=" .. F.one_line(error_class or "unknown-error"),
    "fingerprint=" .. F.error_fingerprint(error_class, queue, dept, message),
  }
  local source_ref = F.source_ref_field(context and context.source_ref)
  if source_ref ~= nil and source_ref ~= "" then
    table.insert(fields, "source_ref=" .. source_ref)
  end
  if context and context.attempt ~= nil then
    table.insert(fields, "attempt=" .. F.one_line(context.attempt))
  end
  if context and context.terminal ~= nil then
    table.insert(fields, "terminal=" .. tostring(context.terminal == true))
  end
  return fields
end

function F.event_source_ref(event)
  if type(event) == "table" and event.source_ref ~= nil then
    return event.source_ref
  end
  local payload = type(event) == "table" and event.payload or nil
  if type(payload) == "table" then
    return payload.source_ref
  end
  return nil
end

return F
