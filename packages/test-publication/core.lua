local M = {}

local strings = require("contract.strings")

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
  if not strings.is_bounded_string(summary.artifact_root, 4096) then
    error("test-publication: malformed-summary: artifact_root is required")
  end
  return summary
end

function M.publication_request(summary)
  summary = M.validate_artifact_summary(summary)
  return {
    schema = "test-publication.publication-request.v1",
    status = tostring(summary.status or "blocked"),
    job = tostring(summary.job or "unknown"),
    artifact_root = summary.artifact_root,
    source_ref = source_ref(summary),
  }
end

return M
