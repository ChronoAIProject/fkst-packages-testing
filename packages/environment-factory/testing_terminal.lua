local contract = require("contract.environment_factory")

local T = {}

local statuses = {
  planned = true, passed = true, failed = true, blocked = true, degraded = true, mixed = true,
}
local severities = { success = true, failure = true, warning = true, info = true }

local function only_fields(value, allowed)
  if type(value) ~= "table" then
    error("environment-factory: malformed-testing-terminal: testing terminal must be a table")
  end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then
      error("environment-factory: malformed-testing-terminal: unsupported field " .. tostring(key))
    end
  end
end

local function bounded(value, field, limit)
  if type(value) ~= "string" or value == "" or #value > (limit or 512)
    or value:find("[%z\1-\31\127]") ~= nil then
    error("environment-factory: malformed-testing-terminal: " .. field .. " must be bounded")
  end
  return value
end

function T.validate(payload)
  only_fields(payload, {
    schema = true,
    publication_kind = true,
    channel = true,
    severity = true,
    subject = true,
    trace_id = true,
    dedup_key = true,
    status = true,
    job = true,
    artifact_root = true,
    metadata_path = true,
    source_ref = true,
    stage_report_path = true,
    issue_drafts_path = true,
    publication_dry_run = true,
  })
  if payload.schema ~= "test-publication.publication-request.v1"
    or payload.publication_kind ~= "testing-summary" or payload.channel ~= "testing" then
    error("environment-factory: malformed-testing-terminal: expected testing publication request")
  end
  if statuses[payload.status] ~= true or severities[payload.severity] ~= true then
    error("environment-factory: malformed-testing-terminal: unknown status or severity")
  end
  bounded(payload.subject, "subject", 512)
  bounded(payload.trace_id, "trace_id", 180)
  bounded(payload.dedup_key, "dedup_key", 180)
  bounded(payload.job, "job", 180)
  bounded(payload.artifact_root, "artifact_root", 4096)
  if payload.artifact_root:sub(1, 14) ~= ".testing/runs/"
    or payload.artifact_root:find("..", 1, true) ~= nil then
    error("environment-factory: malformed-testing-terminal: artifact_root is unsafe")
  end
  if payload.metadata_path ~= payload.artifact_root .. "/metadata.json" then
    error("environment-factory: malformed-testing-terminal: metadata_path differs from artifact_root")
  end
  if payload.stage_report_path ~= nil and payload.stage_report_path ~= payload.artifact_root .. "/stage-report.md" then
    error("environment-factory: malformed-testing-terminal: stage_report_path differs from artifact_root")
  end
  if payload.issue_drafts_path ~= nil and payload.issue_drafts_path ~= payload.artifact_root .. "/issue-drafts.json" then
    error("environment-factory: malformed-testing-terminal: issue_drafts_path differs from artifact_root")
  end
  if payload.publication_dry_run ~= nil and payload.publication_dry_run ~= true then
    error("environment-factory: malformed-testing-terminal: publication_dry_run must be true")
  end
  contract.validate_artifact_ref(payload.source_ref, "testing-terminal.source_ref")
  return payload
end

return T
