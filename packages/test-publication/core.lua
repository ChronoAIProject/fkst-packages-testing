local M = {}

local strings = require("contract.strings")
local testing_contract = require("contract.testing")
local artifact_io = require("testing_runtime.artifact_io")
local json_codec = require("testing_runtime.json")

local statuses = testing_contract.summary_statuses

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
  if status == "blocked" or status == "degraded" or status == "mixed" then return "warning" end
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
  return testing_contract.copy_source_ref(summary.source_ref, "artifact", summary.artifact_root or "unknown")
end

local function require_dry_run(condition, message)
  if not condition then
    error("test-publication: malformed-dry-run: " .. message)
  end
end

local function copy_dry_run_pointers(request, summary)
  local native = type(summary.native_summary) == "table" and summary.native_summary or nil
  if native == nil then return request end
  if native.stage_report_path ~= nil then
    if native.stage_report_path ~= summary.artifact_root .. "/stage-report.md" then
      error("test-publication: malformed-summary: stage_report_path must point under artifact_root")
    end
    request.stage_report_path = native.stage_report_path
  end
  if native.issue_drafts_path ~= nil then
    if native.issue_drafts_path ~= summary.artifact_root .. "/issue-drafts.json" then
      error("test-publication: malformed-summary: issue_drafts_path must point under artifact_root")
    end
    request.issue_drafts_path = native.issue_drafts_path
  end
  if native.publication_dry_run ~= nil then
    if native.publication_dry_run ~= true then
      error("test-publication: malformed-summary: publication_dry_run must be true when present")
    end
    request.publication_dry_run = true
  end
  return request
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
  if summary.trace_id ~= nil and not testing_contract.is_bounded_id(summary.trace_id) then
    error("test-publication: malformed-summary: trace_id must be a bounded string")
  end
  if summary.dedup_key ~= nil and not testing_contract.is_bounded_id(summary.dedup_key) then
    error("test-publication: malformed-summary: dedup_key must be a bounded string")
  end
  if summary.final_report_path ~= nil then
    require_dry_run(summary.final_report_path == summary.artifact_root .. "/final-report.md", "final_report_path must point under artifact_root")
    require_dry_run(summary.publication_mode == "artifact-only", "publication_mode must be artifact-only")
    require_dry_run(summary.publication_dry_run == true, "publication_dry_run must be true")
  end
  return summary
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
    source_ref = src,
  }
  if summary.final_report_path ~= nil then
    request.final_report_path = summary.final_report_path
    request.publication_mode = summary.publication_mode
    request.publication_dry_run = summary.publication_dry_run
  end
  return copy_dry_run_pointers(request, summary)
end

function M.is_artifact_only_dry_run(request)
  return type(request) == "table"
    and request.schema == testing_contract.schemas.publication_request
    and request.publication_mode == "artifact-only"
    and request.publication_dry_run == true
    and request.final_report_path ~= nil
end

function M.publication_request_path(artifact_root)
  return artifact_root .. "/publication-request.json"
end

function M.dry_run_receipt_path(artifact_root)
  return artifact_root .. "/dry-run-publication-receipt.json"
end

function M.persist_dry_run(request, artifact_ports)
  require_dry_run(M.is_artifact_only_dry_run(request), "request must be an artifact-only dry-run")
  require_dry_run(strings.is_artifact_root(request.artifact_root), "artifact_root is unsafe")
  require_dry_run(request.final_report_path == request.artifact_root .. "/final-report.md", "final_report_path is invalid")
  require_dry_run(testing_contract.is_bounded_id(request.trace_id) and testing_contract.is_bounded_id(request.dedup_key), "trace and dedup identifiers are required")
  local request_path = M.publication_request_path(request.artifact_root)
  local receipt_path = M.dry_run_receipt_path(request.artifact_root)
  artifact_io.write_immutable(request_path, json_codec.encode(request) .. "\n", artifact_ports)
  local receipt = {
    schema = testing_contract.schemas.dry_run_publication_receipt,
    artifact_kind = "dry-run-publication-receipt",
    status = "dry-run",
    publication_key = request.dedup_key,
    trace_id = request.trace_id,
    artifact_root = request.artifact_root,
    publication_request_path = request_path,
    final_report_path = request.final_report_path,
    external_operation = false,
  }
  artifact_io.write_immutable(receipt_path, json_codec.encode(receipt) .. "\n", artifact_ports)
  receipt.receipt_path = receipt_path
  return receipt
end

return M
