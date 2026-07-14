local M = {}

local strings = require("contract.strings")
local testing_contract = require("contract.testing")
local artifact_io = require("testing_runtime.artifact_io")

local statuses = testing_contract.summary_statuses

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

M.safe_artifact_root = strings.is_artifact_root

local function bounded_text(value, limit)
  return type(value) == "string" and #value <= limit
end

local function source_ref(value, artifact_root)
  return testing_contract.copy_source_ref(value, "artifact", artifact_root)
end

local function require_final_report(condition, message)
  if not condition then
    error("test-artifacts: malformed-final-report: " .. message)
  end
end

function M.validate_summary(summary)
  if type(summary) ~= "table" then
    error("test-artifacts: malformed-summary: summary must be a table")
  end
  if summary.schema ~= testing_contract.schemas.artifact_summary then
    error("test-artifacts: unknown-schema: expected test-artifacts.summary.v1")
  end
  if not statuses[summary.status] then
    error("test-artifacts: malformed-summary: unknown status")
  end
  if not strings.is_artifact_root(summary.artifact_root) then
    error("test-artifacts: malformed-summary: artifact_root must be a safe .testing/runs/... path")
  end
  if summary.metadata_path ~= nil and summary.metadata_path ~= summary.artifact_root .. "/metadata.json" then
    error("test-artifacts: malformed-summary: metadata_path must point under artifact_root")
  end
  if summary.stderr_excerpt ~= nil and not bounded_text(summary.stderr_excerpt, 600) then
    error("test-artifacts: malformed-summary: stderr_excerpt is too large")
  end
  if summary.trace_id ~= nil and not testing_contract.is_bounded_id(summary.trace_id) then
    error("test-artifacts: malformed-summary: trace_id must be a bounded string")
  end
  if summary.dedup_key ~= nil and not testing_contract.is_bounded_id(summary.dedup_key) then
    error("test-artifacts: malformed-summary: dedup_key must be a bounded string")
  end
  if summary.adapter ~= nil and testing_contract.copy_scalar_map(summary.adapter) == nil then
    error("test-artifacts: malformed-summary: adapter metadata must be bounded scalar fields")
  end
  if summary.native_summary ~= nil and testing_contract.copy_native_summary(summary.native_summary) == nil then
    error("test-artifacts: malformed-summary: native_summary must be a known bounded native summary")
  end
  if summary.final_report_path ~= nil then
    require_final_report(summary.final_report_path == summary.artifact_root .. "/final-report.md", "final_report_path must point under artifact_root")
    require_final_report(summary.publication_mode == "artifact-only", "publication_mode must be artifact-only")
    require_final_report(summary.publication_dry_run == true, "publication_dry_run must be true")
  end
  return summary
end

function M.persist_final_report(rendered, artifact_ports)
  require_final_report(type(rendered) == "table", "rendered report must be a table")
  require_final_report(rendered.schema == testing_contract.schemas.final_aggregate_report, "rendered report schema is unknown")
  require_final_report(statuses[rendered.status] == true, "rendered report status is unknown")
  require_final_report(strings.is_artifact_root(rendered.artifact_root), "artifact_root is unsafe")
  require_final_report(rendered.rendered_report_path == rendered.artifact_root .. "/.rendered/final-aggregate-report.md", "rendered report pointer is invalid")
  require_final_report(rendered.final_report_path == rendered.artifact_root .. "/final-report.md", "final report pointer is invalid")
  require_final_report(rendered.publication_mode == "artifact-only" and rendered.publication_dry_run == true, "publication must be artifact-only dry-run")
  require_final_report(testing_contract.is_bounded_id(rendered.trace_id) and testing_contract.is_bounded_id(rendered.dedup_key), "trace and dedup identifiers are required")
  local content = artifact_io.read(rendered.rendered_report_path, artifact_ports)
  require_final_report(type(content) == "string" and content ~= "", "rendered report artifact is missing")
  artifact_io.write_immutable(rendered.final_report_path, content, artifact_ports)
  return M.validate_summary({
    schema = testing_contract.schemas.artifact_summary,
    job = "platform-test-loop",
    status = rendered.status,
    artifact_root = rendered.artifact_root,
    metadata_path = rendered.metadata_path,
    final_report_path = rendered.final_report_path,
    publication_mode = rendered.publication_mode,
    publication_dry_run = rendered.publication_dry_run,
    source_ref = source_ref(rendered.source_ref, rendered.artifact_root),
    trace_id = rendered.trace_id,
    dedup_key = rendered.dedup_key,
  })
end

function M.from_testing_result(result)
  if type(result) ~= "table" then
    error("test-artifacts: malformed-result: result must be a table")
  end
  if result.schema ~= testing_contract.schemas.runner_result then
    error("test-artifacts: unknown-result-schema: expected testing-runner.result.v1")
  end
  local status = statuses[result.status] and result.status or "blocked"
  local artifact_root = result.artifact_root or (".testing/runs/" .. safe_key(result.job))
  local src = source_ref(result.source_ref, artifact_root)
  local adapter = testing_contract.copy_scalar_map(result.adapter)
  local native_summary = testing_contract.copy_native_summary(result.native_summary)
  if result.adapter ~= nil and adapter == nil then
    error("test-artifacts: malformed-result: adapter metadata must be bounded scalar fields")
  end
  if result.native_summary ~= nil and native_summary == nil then
    error("test-artifacts: malformed-result: native_summary must be a known bounded native summary")
  end
  local summary = {
    schema = testing_contract.schemas.artifact_summary,
    job = tostring(result.job or "unknown"),
    status = status,
    artifact_root = artifact_root,
    metadata_path = artifact_root .. "/metadata.json",
    source_ref = src,
    trace_id = testing_contract.trace_id(result.trace_id, src, artifact_root),
    dedup_key = testing_contract.dedup_key(result.dedup_key, {
      "artifact-summary",
      tostring(result.job or "unknown"),
      src.kind,
      src.ref,
      artifact_root,
    }),
    adapter = adapter,
    native_summary = native_summary,
    exit_code = type(result.exit_code) == "number" and result.exit_code or nil,
    stderr_excerpt = result.stderr_excerpt,
  }
  return M.validate_summary(summary)
end

return M
