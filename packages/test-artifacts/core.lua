local M = {}

local strings = require("contract.strings")

local statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  mixed = true,
}

M.bounded_string = strings.is_bounded_string

local function safe_key(value)
  local text = tostring(value or "artifact")
  text = text:gsub("[^%w%._%-%/#]", "-"):gsub("^/+", "")
  if text == "" then text = "artifact" end
  if #text > 180 then text = text:sub(1, 180) end
  return text
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
  if not strings.is_bounded_string(summary.artifact_root, 4096) then
    error("test-artifacts: malformed-summary: artifact_root is required")
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
  return M.validate_summary({
    schema = "test-artifacts.summary.v1",
    job = tostring(result.job or "unknown"),
    status = status,
    artifact_root = result.artifact_root or (".testing/runs/" .. safe_key(result.job)),
    source_ref = result.source_ref,
  })
end

return M
