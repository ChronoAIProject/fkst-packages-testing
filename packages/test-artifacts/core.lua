local M = {}

local strings = require("contract.strings")
local testing_contract = require("contract.testing")

local statuses = testing_contract.summary_statuses

M.bounded_string = strings.is_bounded_string

local artifact_files = {
  report = "dry-run-report.md",
  issue_draft = "issue-draft.md",
}

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

local display = testing_contract.display_text

local function source_ref(value, artifact_root)
  return testing_contract.copy_source_ref(value, "artifact", artifact_root)
end

local function artifact_path(summary, name)
  return summary.artifact_root .. "/" .. name
end

local function default_report_path(summary)
  return artifact_path(summary, artifact_files.report)
end

local function default_issue_draft_path(summary)
  return artifact_path(summary, artifact_files.issue_draft)
end

local function validate_optional_artifact_path(summary, key)
  if summary[key] ~= nil and not testing_contract.is_artifact_child_path(summary[key], summary.artifact_root) then
    error("test-artifacts: malformed-summary: " .. key .. " must point under artifact_root")
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
  validate_optional_artifact_path(summary, "report_path")
  validate_optional_artifact_path(summary, "issue_draft_path")
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
  return summary
end

local function module_from_summary(summary)
  local native = summary.native_summary
  if type(native) == "table" and strings.is_bounded_string(native.module, 512) then
    return native.module
  end
  if type(summary.source_ref) == "table" and strings.is_bounded_string(summary.source_ref.ref, 512) then
    return summary.source_ref.ref
  end
  return nil
end

local function scenario_from_summary(summary)
  local native = summary.native_summary
  if type(native) == "table" and native.schema == testing_contract.schemas.online_heartbeat_summary then
    return "Check the configured service heartbeat endpoint without browser state"
  end
  if type(native) == "table" and native.schema == testing_contract.schemas.browser_driver_summary then
    return "Exercise module " .. display(native.module, "unknown module") .. " through driver " .. display(native.driver, "configured driver")
  end
  if type(native) == "table" and native.schema == testing_contract.schemas.module_no_browser_summary then
    return "Validate module " .. display(native.module, "unknown module") .. " through the configured no-browser command"
  end
  if summary.job == "platform-test-loop" then
    return "Review the configured platform module set"
  end
  return "Review the configured testing scenario"
end

local function executed_case(summary)
  if summary.status == "passed" or summary.status == "failed" then
    return scenario_from_summary(summary) .. ": " .. display(summary.status, "not_available")
  end
  return "None. The run status is " .. display(summary.status, "not_available") .. ", so no completed user-facing scenario result is available."
end

local function classification(summary)
  if summary.status == "passed" then return "no_follow_up_recommended" end
  if summary.status == "failed" then return "human_review_recommended" end
  if summary.status == "blocked" then return "execution_blocked" end
  if summary.status == "mixed" then return "mixed_results_need_review" end
  return "not_available"
end

function M.report_path(summary)
  summary = M.validate_summary(summary)
  return summary.report_path or default_report_path(summary)
end

function M.issue_draft_path(summary)
  summary = M.validate_summary(summary)
  return summary.issue_draft_path or default_issue_draft_path(summary)
end

function M.dry_run_report(summary)
  summary = M.validate_summary(summary)
  local module_name = module_from_summary(summary)
  local report_path = M.report_path(summary)
  local issue_draft_path = M.issue_draft_path(summary)
  local rows = {
    "# Testing Dry-Run Report",
    "",
    "This artifact is the dry-run source of truth for QA review and publication handoff.",
    "",
    "## Run",
    "- Job: " .. display(summary.job, "unknown"),
    "- Status: " .. display(summary.status, "not_available"),
    "- Artifact root: " .. display(summary.artifact_root, "not_available", 4096),
    "- Metadata: " .. display(summary.metadata_path, summary.artifact_root .. "/metadata.json", 4096),
    "- Report: " .. display(report_path, "not_available", 4096),
    "- Issue recommendation: " .. display(issue_draft_path, "not_available", 4096),
    "- Source: " .. display(type(summary.source_ref) == "table" and summary.source_ref.kind or "artifact")
      .. ":" .. display(type(summary.source_ref) == "table" and summary.source_ref.ref or summary.artifact_root, "unknown", 512),
    "- Trace: " .. display(summary.trace_id, "not_available"),
    "- Dedup key: " .. display(summary.dedup_key, "not_available"),
    "",
    "## Discovered Modules",
  }

  if module_name ~= nil then
    table.insert(rows, "- " .. display(module_name, "unknown module", 512) .. ": " .. display(summary.status, "not_available"))
  else
    table.insert(rows, "- not_available: no bounded module inventory was supplied to this package")
  end

  table.insert(rows, "")
  table.insert(rows, "## Coverage Status")
  table.insert(rows, "- P0: not_available. No P0 case inventory was supplied to this package.")
  table.insert(rows, "- P1: not_available. No P1 case inventory was supplied to this package.")
  table.insert(rows, "- P2: not_available. No P2 risk classification contract was supplied, so risky cases are not promoted by this report.")
  table.insert(rows, "")
  table.insert(rows, "## Executed Cases")
  table.insert(rows, "- " .. executed_case(summary))
  table.insert(rows, "")
  table.insert(rows, "## Skipped Cases")
  table.insert(rows, "- Risky P2 cases: skipped unless a host-provided risk classification contract marks them safe.")
  table.insert(rows, "- External publication: skipped. This run produces local dry-run artifacts only.")
  table.insert(rows, "")
  table.insert(rows, "## Classifications")
  table.insert(rows, "- Run classification: " .. classification(summary))
  table.insert(rows, "- Product defect classification: not_available until reviewed against host-owned acceptance criteria.")
  table.insert(rows, "")
  table.insert(rows, "## Evidence Pointers")
  table.insert(rows, "- Metadata: " .. display(summary.metadata_path, summary.artifact_root .. "/metadata.json", 4096))
  table.insert(rows, "- Artifact root: " .. display(summary.artifact_root, "not_available", 4096))
  table.insert(rows, "- Issue recommendation: " .. display(issue_draft_path, "not_available", 4096))
  if summary.stderr_excerpt ~= nil and summary.stderr_excerpt ~= "" then
    table.insert(rows, "- Error excerpt: " .. display(summary.stderr_excerpt, "not_available", 600))
  end
  table.insert(rows, "")
  table.insert(rows, "## Issue-Draft Recommendation")
  table.insert(rows, "Use the pointer above for human review. Create or update an external issue only after confirming the scenario is product-visible.")
  table.insert(rows, "")
  return table.concat(rows, "\n")
end

function M.issue_draft(summary)
  summary = M.validate_summary(summary)
  local report_path = M.report_path(summary)
  return table.concat({
    "# Dry-Run Issue Recommendation",
    "",
    "Subject: Testing " .. display(summary.status, "not_available") .. ": " .. display(summary.job, "unknown"),
    "",
    "Scenario: " .. scenario_from_summary(summary),
    "",
    "Classification: " .. classification(summary),
    "",
    "Evidence pointers:",
    "- Report: " .. display(report_path, "not_available", 4096),
    "- Metadata: " .. display(summary.metadata_path, summary.artifact_root .. "/metadata.json", 4096),
    "- Artifact root: " .. display(summary.artifact_root, "not_available", 4096),
    "",
    "Recommendation: Review this dry-run artifact before creating any external issue or comment.",
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
    return nil, err or "failed to open artifact file"
  end
  local wrote, write_err = file:write(content)
  file:close()
  if not wrote then
    return nil, write_err or "failed to write artifact file"
  end
  return true
end

local function write_or_fail(writer, path, content)
  local ok, err = writer(path, content)
  if not ok then
    return nil, tostring(err or "failed to write artifact")
  end
  return true
end

function M.write_dry_run_artifacts(summary, writer)
  summary = M.validate_summary(summary)
  writer = writer or write_file
  local ok, err = write_or_fail(writer, M.report_path(summary), M.dry_run_report(summary) .. "\n")
  if not ok then return nil, err end
  return write_or_fail(writer, M.issue_draft_path(summary), M.issue_draft(summary) .. "\n")
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
    report_path = artifact_root .. "/" .. artifact_files.report,
    issue_draft_path = artifact_root .. "/" .. artifact_files.issue_draft,
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
