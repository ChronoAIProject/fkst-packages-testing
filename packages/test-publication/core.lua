local M = {}

local strings = require("contract.strings")
local testing_contract = require("contract.testing")

local statuses = testing_contract.summary_statuses

M.safe_artifact_root = strings.is_artifact_root

local handoff_file = "publication-handoff.md"

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

local display = testing_contract.display_text

local function subject(summary)
  local job = safe_key(summary.job or "unknown")
  local status = statuses[summary.status] and summary.status or "blocked"
  return "Testing " .. status .. ": " .. job
end
M.subject = subject

local function source_ref(summary)
  return testing_contract.copy_source_ref(summary.source_ref, "artifact", summary.artifact_root or "unknown")
end

local function validate_optional_artifact_path(summary, key)
  if summary[key] ~= nil and not testing_contract.is_artifact_child_path(summary[key], summary.artifact_root) then
    error("test-publication: malformed-summary: " .. key .. " must point under artifact_root")
  end
end

function M.validate_artifact_summary(summary)
  if type(summary) ~= "table" then
    error("test-publication: malformed-summary: summary must be a table")
  end
  if summary.schema ~= testing_contract.schemas.artifact_summary then
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
  validate_optional_artifact_path(summary, "report_path")
  validate_optional_artifact_path(summary, "issue_draft_path")
  validate_optional_artifact_path(summary, "publication_handoff_path")
  if summary.trace_id ~= nil and not testing_contract.is_bounded_id(summary.trace_id) then
    error("test-publication: malformed-summary: trace_id must be a bounded string")
  end
  if summary.dedup_key ~= nil and not testing_contract.is_bounded_id(summary.dedup_key) then
    error("test-publication: malformed-summary: dedup_key must be a bounded string")
  end
  return summary
end

function M.publication_handoff_path(summary)
  summary = M.validate_artifact_summary(summary)
  return summary.publication_handoff_path or (summary.artifact_root .. "/" .. handoff_file)
end

function M.publication_request(summary)
  summary = M.validate_artifact_summary(summary)
  local status = statuses[summary.status] and summary.status or "blocked"
  local src = source_ref(summary)
  local request = {
    schema = testing_contract.schemas.publication_request,
    publication_kind = "testing-summary",
    channel = "testing",
    severity = severity(status),
    subject = subject(summary),
    trace_id = testing_contract.trace_id(summary.trace_id, src, summary.artifact_root),
    dedup_key = testing_contract.dedup_key(summary.dedup_key, {
      "testing-summary",
      "testing",
      tostring(summary.job or "unknown"),
      src.kind,
      src.ref,
      summary.artifact_root,
    }),
    status = status,
    job = tostring(summary.job or "unknown"),
    artifact_root = summary.artifact_root,
    metadata_path = summary.metadata_path,
    report_path = summary.report_path or (summary.artifact_root .. "/dry-run-report.md"),
    issue_draft_path = summary.issue_draft_path or (summary.artifact_root .. "/issue-draft.md"),
    publication_handoff_path = M.publication_handoff_path(summary),
    source_ref = src,
  }
  return request
end

function M.publication_handoff(request)
  if type(request) ~= "table" then
    error("test-publication: malformed-request: request must be a table")
  end
  if request.schema ~= testing_contract.schemas.publication_request then
    error("test-publication: unknown-request-schema: expected test-publication.publication-request.v1")
  end
  if not strings.is_artifact_root(request.artifact_root) then
    error("test-publication: malformed-request: artifact_root must be a safe .testing/runs/... path")
  end
  return table.concat({
    "# Publication Handoff",
    "",
    "Dry-run only. This artifact is a pointer handoff for a host publisher and does not authorize external writes.",
    "",
    "- Subject: " .. display(request.subject, "Testing " .. display(request.status, "not_available")),
    "- Channel: " .. display(request.channel, "testing"),
    "- Severity: " .. display(request.severity, "info"),
    "- Status: " .. display(request.status, "not_available"),
    "- Job: " .. display(request.job, "unknown"),
    "- Artifact root: " .. display(request.artifact_root, "not_available", 4096),
    "- Report: " .. display(request.report_path, request.artifact_root .. "/dry-run-report.md", 4096),
    "- Issue recommendation: " .. display(request.issue_draft_path, request.artifact_root .. "/issue-draft.md", 4096),
    "- Metadata: " .. display(request.metadata_path, request.artifact_root .. "/metadata.json", 4096),
    "- Trace: " .. display(request.trace_id, "not_available"),
    "- Dedup key: " .. display(request.dedup_key, "not_available"),
    "",
    "External publication remains disabled for this package. A host publisher must make any future GitHub write decision outside this dry-run handoff.",
    "",
  }, "\n")
end

local function quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function write_file(path, content)
  local dir = path:match("^(.*)/[^/]+$")
  if not dir or dir == "" then
    return nil, "missing artifact directory"
  end
  local ok = os.execute("mkdir -p " .. quote(dir))
  if ok ~= true and ok ~= 0 then
    return nil, "failed to create artifact directory"
  end
  local file, err = io.open(path, "w")
  if not file then
    return nil, err or "failed to open handoff artifact"
  end
  local wrote, write_err = file:write(content)
  file:close()
  if not wrote then
    return nil, write_err or "failed to write handoff artifact"
  end
  return true
end

function M.write_publication_handoff(request, writer)
  writer = writer or write_file
  local content = M.publication_handoff(request)
  local path = request.publication_handoff_path or (request.artifact_root .. "/" .. handoff_file)
  if not testing_contract.is_artifact_child_path(path, request.artifact_root) then
    return nil, "publication_handoff_path must point under artifact_root"
  end
  local ok, err = writer(path, content .. "\n")
  if not ok then
    return nil, tostring(err or "failed to write handoff artifact")
  end
  return true
end

return M
