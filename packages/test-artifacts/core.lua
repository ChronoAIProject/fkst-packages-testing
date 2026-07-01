local M = {}

local strings = require("contract.strings")

local statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  mixed = true,
}

local max_string = 512
local max_path = 4096

M.bounded_string = strings.is_bounded_string

local function safe_key(value)
  local text = tostring(value or "artifact")
  text = text:gsub("[^%w%._%-]", "-")
  text = text:gsub("%.+", ".")
  text = text:gsub("^%.", "")
  if text == "" then text = "artifact" end
  if #text > 180 then text = text:sub(1, 180) end
  return text
end

local function safe_artifact_root(value)
  if not strings.is_bounded_string(value, max_path) then return false end
  if value:sub(1, 14) ~= ".testing/runs/" then return false end
  if value:find("..", 1, true) ~= nil or value:find("\0", 1, true) ~= nil then return false end
  return true
end
M.safe_artifact_root = safe_artifact_root

local function bounded_text(value, limit)
  return type(value) == "string" and #value <= limit
end

local function bounded_map(value)
  if type(value) ~= "table" then return nil end
  local copy = {}
  local count = 0
  for key, item in pairs(value) do
    local key_text = tostring(key)
    if not strings.is_bounded_string(key_text, 80) then return nil end
    if type(item) == "string" then
      if not strings.is_bounded_string(item, max_string) then return nil end
      copy[key_text] = item
    elseif type(item) == "number" or type(item) == "boolean" then
      copy[key_text] = item
    else
      return nil
    end
    count = count + 1
    if count > 16 then return nil end
  end
  return copy
end

local function source_ref(value)
  if type(value) ~= "table" then return nil end
  return {
    kind = tostring(value.kind or "request"),
    ref = tostring(value.ref or "unknown"),
  }
end

function M.validate_summary(summary)
  if type(summary) ~= "table" then
    error("test-artifacts: malformed-summary: summary must be a table")
  end
  if summary.schema ~= "test-artifacts.summary.v1" then
    error("test-artifacts: unknown-schema: expected test-artifacts.summary.v1")
  end
  if not statuses[summary.status] then
    error("test-artifacts: malformed-summary: unknown status")
  end
  if not safe_artifact_root(summary.artifact_root) then
    error("test-artifacts: malformed-summary: artifact_root must be a safe .testing/runs/... path")
  end
  if summary.metadata_path ~= nil and summary.metadata_path ~= summary.artifact_root .. "/metadata.json" then
    error("test-artifacts: malformed-summary: metadata_path must point under artifact_root")
  end
  if summary.stderr_excerpt ~= nil and not bounded_text(summary.stderr_excerpt, 600) then
    error("test-artifacts: malformed-summary: stderr_excerpt is too large")
  end
  return summary
end

function M.from_testing_result(result)
  if type(result) ~= "table" then
    error("test-artifacts: malformed-result: result must be a table")
  end
  if result.schema ~= "testing-runner.result.v1" then
    error("test-artifacts: unknown-result-schema: expected testing-runner.result.v1")
  end
  local status = statuses[result.status] and result.status or "blocked"
  local artifact_root = result.artifact_root or (".testing/runs/" .. safe_key(result.job))
  local adapter = bounded_map(result.adapter)
  local native_summary = bounded_map(result.native_summary)
  if result.adapter ~= nil and adapter == nil then
    error("test-artifacts: malformed-result: adapter metadata must be bounded scalar fields")
  end
  if result.native_summary ~= nil and native_summary == nil then
    error("test-artifacts: malformed-result: native_summary must be bounded scalar fields")
  end
  local summary = {
    schema = "test-artifacts.summary.v1",
    job = tostring(result.job or "unknown"),
    status = status,
    artifact_root = artifact_root,
    metadata_path = artifact_root .. "/metadata.json",
    source_ref = source_ref(result.source_ref),
    adapter = adapter,
    native_summary = native_summary,
    exit_code = type(result.exit_code) == "number" and result.exit_code or nil,
    stderr_excerpt = result.stderr_excerpt,
  }
  return M.validate_summary(summary)
end

return M
