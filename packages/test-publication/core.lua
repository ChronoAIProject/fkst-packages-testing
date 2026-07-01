local M = {}

local strings = require("contract.strings")

local statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  mixed = true,
}

M.safe_artifact_root = strings.is_artifact_root

local function safe_key(value)
  local text = tostring(value or "testing-summary")
  text = text:gsub("[^%w%._%-]", "-")
  text = text:gsub("%.+", ".")
  text = text:gsub("^%.", "")
  if text == "" then text = "testing-summary" end
  if #text > 180 then text = text:sub(1, 180) end
  return text
end

local function severity(status)
  if status == "passed" then return "success" end
  if status == "failed" then return "failure" end
  if status == "blocked" or status == "mixed" then return "warning" end
  return "info"
end
M.severity = severity

local function subject(summary)
  local job = safe_key(summary.job or "unknown")
  local status = statuses[summary.status] and summary.status or "blocked"
  return "Testing " .. status .. ": " .. job
end
M.subject = subject

local function source_ref(summary)
  if type(summary.source_ref) == "table" then
    return {
      kind = tostring(summary.source_ref.kind or "artifact"),
      ref = tostring(summary.source_ref.ref or "unknown"),
    }
  end
  return { kind = "artifact", ref = tostring(summary.artifact_root or "unknown") }
end

function M.validate_artifact_summary(summary)
  if type(summary) ~= "table" then
    error("test-publication: malformed-summary: summary must be a table")
  end
  if summary.schema ~= "test-artifacts.summary.v1" then
    error("test-publication: unknown-schema: expected test-artifacts.summary.v1")
  end
  if not strings.is_artifact_root(summary.artifact_root) then
    error("test-publication: malformed-summary: artifact_root must be a safe .testing/runs/... path")
  end
  if summary.status ~= nil and not statuses[summary.status] then
    error("test-publication: malformed-summary: unknown status")
  end
  if summary.metadata_path ~= nil and summary.metadata_path ~= summary.artifact_root .. "/metadata.json" then
    error("test-publication: malformed-summary: metadata_path must point under artifact_root")
  end
  return summary
end

function M.publication_request(summary)
  summary = M.validate_artifact_summary(summary)
  local status = statuses[summary.status] and summary.status or "blocked"
  local src = source_ref(summary)
  local request = {
    schema = "test-publication.publication-request.v1",
    publication_kind = "testing-summary",
    channel = "testing",
    severity = severity(status),
    subject = subject(summary),
    dedup_key = safe_key((src.kind or "artifact") .. "-" .. (src.ref or summary.artifact_root)),
    status = status,
    job = tostring(summary.job or "unknown"),
    artifact_root = summary.artifact_root,
    metadata_path = summary.metadata_path,
    source_ref = src,
  }
  return request
end

return M
