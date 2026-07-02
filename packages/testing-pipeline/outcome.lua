local O = {}

local strings = require("contract.strings")
local testing_contract = require("contract.testing")

local schemas = {
  outcome_classification = "testing-pipeline.outcome-classification.v1",
  gap_backlog = "testing-pipeline.gap-backlog.v1",
}

local statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  mixed = true,
}

local categories = {
  product_defect = true,
  harness_tooling_issue = true,
  environment_session_issue = true,
  data_fixture_gap = true,
  not_executed_risk = true,
}

O.categories = categories

local gap_categories = {
  harness_tooling_issue = true,
  environment_session_issue = true,
  data_fixture_gap = true,
  not_executed_risk = true,
}

local max_reason = 240

local function bounded(value, limit)
  return type(value) == "string" and value ~= "" and #value <= limit
end

local function has_no_control(text)
  return type(text) == "string" and text:find("[%z\1-\31]") == nil
end

local function artifact_ref(value, suffix)
  return { kind = "artifact", ref = value.artifact_root .. "/" .. suffix }
end

local function native_summary(result)
  return type(result.native_summary) == "table" and result.native_summary or nil
end

local function module_name(result)
  local summary = native_summary(result)
  if type(summary) == "table" and bounded(summary.module, 256) then return summary.module end
  local source_ref = type(result.source_ref) == "table" and result.source_ref or {}
  if bounded(source_ref.ref, 256) then return source_ref.ref end
  return testing_contract.safe_key(result.job or result.dedup_key or "module", "module")
end

local function adapter_mode(result)
  local adapter = type(result.adapter) == "table" and result.adapter or {}
  return tostring(adapter.mode or adapter.name or "")
end

function O.valid_evidence_ref(item)
  return type(item) == "table"
    and item.kind == "artifact"
    and strings.is_path_safe_key(item.ref, 512)
    and item.user_facing == true
    and item.reproducible == true
end

local function valid_run_evidence_ref(item, artifact_root)
  if not O.valid_evidence_ref(item) or not strings.is_artifact_root(artifact_root) then return false end
  local prefix = artifact_root .. "/evidence/"
  return item.ref:sub(1, #prefix) == prefix and #item.ref > #prefix
end

local function evidence_refs(result)
  local refs = {}
  if type(result.evidence_refs) ~= "table" then return refs end
  for _, item in ipairs(result.evidence_refs) do
    if valid_run_evidence_ref(item, result.artifact_root) then
      table.insert(refs, {
        kind = item.kind,
        ref = item.ref,
        user_facing = true,
        reproducible = true,
      })
      if #refs >= 8 then break end
    end
  end
  return refs
end

local function readiness_status(result)
  local summary = native_summary(result)
  local readiness = type(summary) == "table" and type(summary.readiness) == "table" and summary.readiness or nil
  return type(readiness) == "table" and tostring(readiness.status or "") or ""
end

local function has_blocked_session(result)
  local summary = native_summary(result)
  local readiness = type(summary) == "table" and type(summary.readiness) == "table" and summary.readiness or nil
  if type(readiness) ~= "table" or type(readiness.sessions) ~= "table" then return false end
  for _, session in ipairs(readiness.sessions) do
    if type(session) == "table" and tostring(session.status or "") ~= "ready" then return true end
  end
  return false
end

local function is_harness_uncertain(result, refs)
  local mode = adapter_mode(result)
  local stderr = tostring(result.stderr_excerpt or ""):lower()
  if mode:find("browser%-driver", 1, false) ~= nil and result.status == "failed" and #refs == 0 then
    return true
  end
  return mode:find("legacy%-cli", 1, false) ~= nil
    or stderr:find("cdp", 1, true) ~= nil
    or stderr:find("harness", 1, true) ~= nil
    or stderr:find("unmocked external command", 1, true) ~= nil
end

local function is_environment_session(result)
  local mode = adapter_mode(result)
  local stderr = tostring(result.stderr_excerpt or ""):lower()
  if mode == "readiness-blocked" then return true end
  if readiness_status(result) == "blocked" or has_blocked_session(result) then return true end
  return stderr:find("preflight", 1, true) ~= nil
    or stderr:find("missing session", 1, true) ~= nil
    or stderr:find("login", 1, true) ~= nil
    or stderr:find("base url", 1, true) ~= nil
    or stderr:find("local server", 1, true) ~= nil
end

local function is_data_fixture_gap(result)
  local stderr = tostring(result.stderr_excerpt or ""):lower()
  return stderr:find("fixture", 1, true) ~= nil
    or stderr:find("cleanup", 1, true) ~= nil
    or stderr:find("rollback", 1, true) ~= nil
    or stderr:find("safe data", 1, true) ~= nil
end

local function reason_for(category)
  if category == "product_defect" then return "failed run has reproducible user-facing evidence refs" end
  if category == "harness_tooling_issue" then return "harness or CDP uncertainty prevents product defect classification" end
  if category == "environment_session_issue" then return "missing or blocked environment/session readiness" end
  if category == "data_fixture_gap" then return "missing fixture, cleanup, rollback, or safe data" end
  return "case was planned, skipped, blocked, or lacked product-defect evidence"
end

local function follow_up_for(category)
  if category == "harness_tooling_issue" then return "stabilize harness or CDP signal and rerun" end
  if category == "environment_session_issue" then return "restore session, login, local server, or readiness inputs and rerun" end
  if category == "data_fixture_gap" then return "add safe fixture, cleanup, rollback, or seed data before rerun" end
  return "execute the planned case or add missing evidence before triage"
end

local function validate_result(result)
  if type(result) ~= "table" then error("testing-pipeline: malformed-result: result must be a table") end
  if result.schema ~= "testing-runner.result.v1" then
    error("testing-pipeline: unknown-result-schema: expected testing-runner.result.v1")
  end
  if result.artifact_root ~= nil and not strings.is_artifact_root(result.artifact_root) then
    error("testing-pipeline: malformed-result: artifact_root must be a safe .testing/runs/... path")
  end
  return result
end

function O.classify_testing_result(result)
  result = validate_result(result)
  local status = statuses[result.status] and result.status or "blocked"
  if status == "passed" then return nil end
  local src = testing_contract.copy_source_ref(result.source_ref, "testing-result", result.artifact_root or result.job)
  local refs = evidence_refs(result)
  local category
  if is_environment_session(result) then
    category = "environment_session_issue"
  elseif is_harness_uncertain(result, refs) then
    category = "harness_tooling_issue"
  elseif is_data_fixture_gap(result) then
    category = "data_fixture_gap"
  elseif status == "failed" and #refs > 0 then
    category = "product_defect"
  else
    category = "not_executed_risk"
  end
  local classification = {
    schema = schemas.outcome_classification,
    category = category,
    status = status,
    job = tostring(result.job or "unknown"),
    module = module_name(result),
    reason = reason_for(category),
    artifact_root = result.artifact_root,
    source_ref = src,
    trace_id = testing_contract.trace_id(result.trace_id, src, result.artifact_root),
    dedup_key = testing_contract.dedup_key(result.dedup_key, {
      "outcome-classification",
      tostring(result.job or "unknown"),
      src.kind,
      src.ref,
      result.artifact_root or "artifact",
    }),
    evidence_refs = refs,
  }
  if result.artifact_root ~= nil then classification.metadata_ref = artifact_ref(result, "metadata.json") end
  return O.validate_outcome_classification(classification)
end

function O.validate_outcome_classification(classification)
  if type(classification) ~= "table" then error("testing-pipeline: malformed-classification: classification must be a table") end
  if classification.schema ~= schemas.outcome_classification then
    error("testing-pipeline: unknown-classification-schema: expected testing-pipeline.outcome-classification.v1")
  end
  if not categories[classification.category] or not statuses[classification.status] then
    error("testing-pipeline: malformed-classification: unknown category or status")
  end
  if not bounded(classification.job, 128) or not bounded(classification.module, 256) then
    error("testing-pipeline: malformed-classification: job and module are required")
  end
  if not bounded(classification.reason, max_reason) or not has_no_control(classification.reason) then
    error("testing-pipeline: malformed-classification: reason must be bounded text")
  end
  if classification.artifact_root ~= nil and not strings.is_artifact_root(classification.artifact_root) then
    error("testing-pipeline: malformed-classification: artifact_root must be a safe .testing/runs/... path")
  end
  if not testing_contract.is_bounded_id(classification.trace_id) or not testing_contract.is_bounded_id(classification.dedup_key) then
    error("testing-pipeline: malformed-classification: trace_id and dedup_key are required")
  end
  if type(classification.source_ref) ~= "table" or type(classification.evidence_refs) ~= "table" then
    error("testing-pipeline: malformed-classification: source_ref and evidence_refs are required")
  end
  if classification.metadata_ref ~= nil
    and (type(classification.metadata_ref) ~= "table"
      or classification.metadata_ref.kind ~= "artifact"
      or classification.metadata_ref.ref ~= classification.artifact_root .. "/metadata.json")
  then
    error("testing-pipeline: malformed-classification: metadata_ref must point under artifact_root")
  end
  for _, item in ipairs(classification.evidence_refs) do
    if not valid_run_evidence_ref(item, classification.artifact_root) then
      error("testing-pipeline: malformed-classification: evidence_refs must be run-bound reproducible user-facing artifact refs")
    end
  end
  if classification.category == "product_defect" and #classification.evidence_refs == 0 then
    error("testing-pipeline: malformed-classification: product_defect requires run-bound evidence_refs")
  end
  return classification
end

function O.gap_backlog(classification)
  classification = O.validate_outcome_classification(classification)
  if not gap_categories[classification.category] then return nil end
  local artifact_root = classification.artifact_root
  if not strings.is_artifact_root(artifact_root) then
    error("testing-pipeline: malformed-backlog: artifact_root is required for gap backlog")
  end
  local item = {
    module = classification.module,
    category = classification.category,
    status = classification.status,
    reason = classification.reason,
    follow_up = follow_up_for(classification.category),
    artifact_ref = artifact_ref(classification, "metadata.json"),
  }
  local backlog = {
    schema = schemas.gap_backlog,
    artifact_root = artifact_root,
    backlog_ref = artifact_ref(classification, "gap-backlog.json"),
    source_ref = classification.source_ref,
    trace_id = classification.trace_id,
    dedup_key = testing_contract.dedup_key(nil, {
      "gap-backlog",
      classification.job,
      classification.module,
      classification.category,
      artifact_root,
    }),
    blocked_modules = {},
    skipped_cases = {},
    required_follow_up = { item },
  }
  if classification.category == "not_executed_risk" then
    backlog.skipped_cases = { item }
  else
    backlog.blocked_modules = { item }
  end
  return O.validate_gap_backlog(backlog)
end

local function valid_backlog_item(item, root)
  return type(item) == "table"
    and bounded(item.module, 256)
    and categories[item.category] == true
    and statuses[item.status] == true
    and bounded(item.reason, max_reason)
    and bounded(item.follow_up, max_reason)
    and type(item.artifact_ref) == "table"
    and item.artifact_ref.kind == "artifact"
    and item.artifact_ref.ref == root .. "/metadata.json"
end

function O.validate_gap_backlog(backlog)
  if type(backlog) ~= "table" then error("testing-pipeline: malformed-backlog: backlog must be a table") end
  if backlog.schema ~= schemas.gap_backlog then
    error("testing-pipeline: unknown-backlog-schema: expected testing-pipeline.gap-backlog.v1")
  end
  if not strings.is_artifact_root(backlog.artifact_root) then
    error("testing-pipeline: malformed-backlog: artifact_root must be a safe .testing/runs/... path")
  end
  if type(backlog.backlog_ref) ~= "table" or backlog.backlog_ref.ref ~= backlog.artifact_root .. "/gap-backlog.json" then
    error("testing-pipeline: malformed-backlog: backlog_ref must point under artifact_root")
  end
  if type(backlog.source_ref) ~= "table"
    or not testing_contract.is_bounded_id(backlog.trace_id)
    or not testing_contract.is_bounded_id(backlog.dedup_key)
  then
    error("testing-pipeline: malformed-backlog: source_ref, trace_id, and dedup_key are required")
  end
  for _, list_name in ipairs({ "blocked_modules", "skipped_cases", "required_follow_up" }) do
    if type(backlog[list_name]) ~= "table" then error("testing-pipeline: malformed-backlog: invalid list") end
    for _, item in ipairs(backlog[list_name]) do
      if not valid_backlog_item(item, backlog.artifact_root) then
        error("testing-pipeline: malformed-backlog: invalid item")
      end
    end
  end
  return backlog
end

return O
