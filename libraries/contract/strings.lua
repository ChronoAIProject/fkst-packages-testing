-- contract.strings: small, dependency-free string utilities shared across packages.
local S = {}

function S.trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function S.trim_end(value)
  return tostring(value or ""):gsub("%s+$", "")
end

function S.split_final_path_segment(value)
  local segment = value:match("/([^/]+)$")
  local prefix = segment and value:sub(1, #value - #segment - 1) or nil
  if prefix == nil or prefix == "" or segment == nil or segment == "" then
    return nil
  end
  return prefix, segment
end

function S.normalize_control_line(value)
  if value == nil then
    return nil
  end
  local text = tostring(value):gsub("%c", " "):gsub("%s+", " ")
  text = S.trim(text)
  if text == "" then
    return nil
  end
  return text
end

function S.map_lines(value, transform)
  local output = {}
  local start = 1
  while true do
    local newline = value:find("\n", start, true)
    if newline == nil then
      table.insert(output, transform(value:sub(start)))
      break
    end
    table.insert(output, transform(value:sub(start, newline - 1)))
    table.insert(output, "\n")
    start = newline + 1
  end
  return table.concat(output)
end

-- contract.strings.json_string is a temporary byte-identical stopgap for #976 only:
-- canonical JSON encoding remains deferred to a dedicated encoder boundary.
-- Keep this body matched to the folded github-devloop encode_json_string copies;
-- do not extend it into a partial general JSON serializer.
function S.json_string(value)
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
  return '"' .. text .. '"'
end

function S.is_bounded_string(value, limit)
  return type(value) == "string" and value ~= "" and #value <= limit
end

function S.is_sha256(value)
  return type(value) == "string" and #value == 64
    and value:match("^[0-9a-f]+$") ~= nil
end

function S.is_artifact_root(value, limit)
  return S.is_path_safe_key(value, limit or 4096) and value:sub(1, 14) == ".testing/runs/"
end

local function is_strict_safe_path(value, limit)
  return S.is_path_safe_key(value, limit)
    and value:sub(-1) ~= "/"
    and value:find("//", 1, true) == nil
    and value:find("#", 1, true) == nil
end

function S.artifact_run_id(value)
  if not is_strict_safe_path(value, 4096) then return nil end
  return value:match("^%.testing/runs/([^/]+)")
end

function S.is_artifact_descendant(value, root)
  if not is_strict_safe_path(root, 4096) or root:sub(1, 14) ~= ".testing/runs/"
    or not is_strict_safe_path(value, 4096) then
    return false
  end
  return value:sub(1, #root + 1) == root .. "/"
end

function S.decimal_checksum(value)
  local hash = 2166136261
  local text = tostring(value or "")
  for i = 1, #text do
    hash = (hash * 16777619 + text:byte(i)) % 4294967291
  end
  return string.format("%010d", hash)
end

function S.is_path_safe_key(value, limit)
  if not S.is_bounded_string(value, limit) then
    return false
  end
  if value:sub(1, 1) == "/" then
    return false
  end
  if value:find("\\", 1, true) ~= nil then
    return false
  end
  if value:find("%s") ~= nil then
    return false
  end
  if value:find("[^%w%._%-%/#]") ~= nil then
    return false
  end
  for segment in value:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      return false
    end
  end
  return true
end

function S.sanitize_key(value, limit)
  local max_len = limit
  local sanitized = tostring(value or ""):gsub("[^%w%._%-%/#]", "-")
  sanitized = sanitized:gsub("/+", "/")
  sanitized = sanitized:gsub("^/+", ""):gsub("/+$", "")
  if sanitized == "" then
    return "empty"
  end

  local segments = {}
  for segment in sanitized:gmatch("[^/]+") do
    local safe_segment = segment
    if safe_segment == "." or safe_segment == ".." then
      safe_segment = "-"
    end
    table.insert(segments, safe_segment)
  end

  sanitized = table.concat(segments, "/")
  if max_len ~= false and max_len ~= nil and #sanitized > max_len then
    sanitized = sanitized:sub(1, max_len)
    sanitized = sanitized:gsub("/+$", "")
  end
  if sanitized == "" then
    return "empty"
  end
  return sanitized
end

function S.runtime_safe_segment(value)
  local safe = tostring(value or ""):gsub("[^%w._-]", "_")
  safe = safe:gsub("_+", "_"):gsub("^_+", ""):gsub("_+$", "")
  if safe == "" then
    return "empty"
  end
  return safe
end

S.max_cache_key_segment_len = 120

-- Renders a value as one cache-key segment. A sibling of sanitize_key, not a variant of it:
-- it excludes "#", takes allow_slash rather than always permitting slashes, collapses runs of
-- "-", and carries its own bound. Three byte-identical copies lived in devloop, forge and
-- github-proxy; all three already depend on contract, which is where the rest of this family is.
function S.sanitize_cache_segment(value, allow_slash)
  local pattern = allow_slash and "[^%w%._%-%/]" or "[^%w%._%-]"
  local safe = tostring(value or ""):gsub(pattern, "-")
  safe = safe:gsub("-+", "-")
  if allow_slash then
    safe = safe:gsub("/+", "/"):gsub("^/+", ""):gsub("/+$", "")
  else
    safe = safe:gsub("^-+", ""):gsub("-+$", "")
  end
  local segments = {}
  for segment in safe:gmatch("[^/]+") do
    if segment == "." or segment == ".." then
      segment = "-"
    end
    table.insert(segments, segment)
  end
  safe = table.concat(segments, allow_slash and "/" or "-")
  if #safe > S.max_cache_key_segment_len then
    safe = safe:sub(1, S.max_cache_key_segment_len):gsub("/+$", ""):gsub("-+$", "")
  end
  if safe == "" then
    return "empty"
  end
  return safe
end

return S
