-- contract.testing: shared testing payload helpers for small, bounded handoff contracts.
local strings = require("contract.strings")

local T = {}

T.schemas = {
  runner_result = "testing-runner.result.v1",
  native_metadata = "testing-runner.native-metadata.v1",
  final_aggregate_report_request = "testing-runner.final-aggregate-report-request.v1",
  final_aggregate_report = "testing-runner.final-aggregate-report.v1",
  artifact_summary = "test-artifacts.summary.v1",
  publication_request = "test-publication.publication-request.v1",
  dry_run_publication_receipt = "test-publication.dry-run-receipt.v1",
  platform_completion_barrier = "platform-test-loop.completion-barrier.v1",
  platform_coverage_matrix = "platform-test-loop.coverage-matrix.v1",
  module_no_browser_summary = "testing-runner.module-no-browser-summary.v1",
  module_ui_loop_summary = "testing-runner.module-ui-loop-summary.v1",
  module_inventory_summary = "testing-runner.module-inventory-summary.v1",
  module_cdp_execution_summary = "testing-runner.module-cdp-execution-summary.v1",
  online_heartbeat_summary = "testing-runner.online-heartbeat-summary.v1",
  browser_driver_summary = "testing-runner.browser-driver-summary.v1",
}

T.runner_statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  degraded = true,
}

T.summary_statuses = {
  planned = true,
  passed = true,
  failed = true,
  blocked = true,
  degraded = true,
  mixed = true,
}

local max_string = 512
local max_id = 180

local function has_no_control(text)
  return type(text) == "string" and text:find("[%z\1-\31]") == nil
end

function T.is_bounded_id(value)
  return strings.is_bounded_string(value, max_id) and has_no_control(value)
end

function T.safe_key(value, fallback)
  local text = tostring(value or fallback or "testing")
  text = text:gsub("[^%w%._%-]", "-")
  text = text:gsub("%.+", ".")
  text = text:gsub("^%.", "")
  if text == "" then text = fallback or "testing" end
  if #text > max_id then text = text:sub(1, max_id) end
  return text
end

local function bounded_or_sanitized(value, fallback, limit)
  if type(value) == "string" and value ~= "" and #value <= limit and has_no_control(value) then
    return value
  end
  local safe = strings.sanitize_key(value or fallback, limit)
  if safe == "" or safe == "empty" then return fallback end
  return safe
end

function T.copy_source_ref(value, fallback_kind, fallback_ref)
  if type(value) == "table" then
    return {
      kind = bounded_or_sanitized(value.kind, fallback_kind or "request", 80),
      ref = bounded_or_sanitized(value.ref, fallback_ref or "unknown", max_string),
    }
  end
  return {
    kind = bounded_or_sanitized(fallback_kind, "request", 80),
    ref = bounded_or_sanitized(fallback_ref, "unknown", max_string),
  }
end

function T.copy_scalar_map(value)
  if value == nil then return nil end
  if type(value) ~= "table" then return nil end
  local copy = {}
  local count = 0
  for key, item in pairs(value) do
    if type(key) ~= "string" or not strings.is_bounded_string(key, 80) then return nil end
    if type(item) == "string" then
      if not strings.is_bounded_string(item, max_string) or not has_no_control(item) then return nil end
      copy[key] = item
    elseif type(item) == "number" or type(item) == "boolean" then
      copy[key] = item
    else
      return nil
    end
    count = count + 1
    if count > 16 then return nil end
  end
  return copy
end

local function has_only(value, allowed)
  for key, _ in pairs(value) do
    if allowed[key] ~= true then return false end
  end
  return true
end

local function bounded_field(value, limit)
  return type(value) == "string" and value ~= "" and #value <= (limit or max_string) and has_no_control(value)
end

local function dense_list(value)
  if type(value) ~= "table" then return false end
  local count, max_index = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return false end
    count = count + 1
    if key > max_index then max_index = key end
  end
  return count == max_index
end

local function copy_readiness(value)
  if type(value) ~= "table" then return nil end
  if not has_only(value, { status = true, sessions = true }) then return nil end
  if not bounded_field(value.status, 80) then return nil end
  local copy = { status = value.status }
  if value.sessions ~= nil then
    if not dense_list(value.sessions) or #value.sessions > 16 then return nil end
    local sessions = {}
    for _, session in ipairs(value.sessions) do
      if type(session) ~= "table" then return nil end
      if not has_only(session, { role = true, status = true }) then return nil end
      if not bounded_field(session.role, 80) or not bounded_field(session.status, 80) then return nil end
      table.insert(sessions, { role = session.role, status = session.status })
    end
    if #sessions > 0 then copy.sessions = sessions end
  end
  return copy
end

local outcome_classifications = {
  ["product-defect"] = true,
  ["harness-tooling-issue"] = true,
  ["harness-tooling-gap"] = true,
  ["environment-session-issue"] = true,
  ["environment-readiness-gap"] = true,
  ["data-fixture-gap"] = true,
  ["not-executed-risk"] = true,
  ["ai-generation-gap"] = true,
  ["unsafe-generated-case"] = true,
  ["multi-module-flow-gap"] = true,
}

local function copy_outcome_fields(copy, value)
  if value.outcome_classification ~= nil then
    if outcome_classifications[value.outcome_classification] ~= true then return nil end
    copy.outcome_classification = value.outcome_classification
  end
  if value.gap_backlog_path ~= nil then
    if value.gap_backlog_path ~= value.artifact_root .. "/gap-backlog.json" then return nil end
    copy.gap_backlog_path = value.gap_backlog_path
  end
  if value.stage_report_path ~= nil then
    if value.stage_report_path ~= value.artifact_root .. "/stage-report.md" then return nil end
    copy.stage_report_path = value.stage_report_path
  end
  if value.issue_drafts_path ~= nil then
    if value.issue_drafts_path ~= value.artifact_root .. "/issue-drafts.json" then return nil end
    copy.issue_drafts_path = value.issue_drafts_path
  end
  if value.publication_dry_run ~= nil then
    if value.publication_dry_run ~= true then return nil end
    copy.publication_dry_run = true
  end
  return copy
end

local function copy_module_no_browser(value)
  if not has_only(value, { schema = true, module = true, status = true, mode = true }) then return nil end
  if not bounded_field(value.module, max_string) or not bounded_field(value.status, 80) or not bounded_field(value.mode, 80) then return nil end
  return {
    schema = T.schemas.module_no_browser_summary,
    module = value.module,
    status = value.status,
    mode = value.mode,
  }
end

local function copy_module_ui_loop(value)
  if not has_only(value, { schema = true, module = true, status = true, classification = true, mode = true, artifact_root = true, metadata_path = true, evidence_bundle_path = true, gap_backlog_path = true, outcome_classification = true, stage_report_path = true, issue_drafts_path = true, publication_dry_run = true, gap_ref = true, backlog_ref = true }) then return nil end
  if not bounded_field(value.module, max_string) or not bounded_field(value.status, 80) then return nil end
  if not bounded_field(value.classification, 80) or not bounded_field(value.mode, 80) then return nil end
  if not strings.is_artifact_root(value.artifact_root) then return nil end
  if value.metadata_path ~= value.artifact_root .. "/metadata.json" then return nil end
  if value.evidence_bundle_path ~= nil and value.evidence_bundle_path ~= value.artifact_root .. "/evidence-bundle.json" then return nil end
  local copy = {
    schema = T.schemas.module_ui_loop_summary,
    module = value.module,
    status = value.status,
    classification = value.classification,
    mode = value.mode,
    artifact_root = value.artifact_root,
    metadata_path = value.metadata_path,
  }
  if value.evidence_bundle_path ~= nil then copy.evidence_bundle_path = value.evidence_bundle_path end
  if value.gap_ref ~= nil then
    if not bounded_field(value.gap_ref, max_string) then return nil end
    copy.gap_ref = value.gap_ref
  end
  if value.backlog_ref ~= nil then
    if not bounded_field(value.backlog_ref, max_string) then return nil end
    copy.backlog_ref = value.backlog_ref
  end
  return copy_outcome_fields(copy, value)
end

local function copy_module_inventory(value)
  if not has_only(value, { schema = true, module = true, status = true, discovery_status = true, artifact_root = true, inventory_path = true, module_count = true, coverage = true, feature_inventory_path = true, test_plan_path = true, plan_status = true, evidence_bundle_path = true, gap_backlog_path = true, outcome_classification = true, stage_report_path = true, issue_drafts_path = true, publication_dry_run = true }) then return nil end
  if not bounded_field(value.module, max_string) or not bounded_field(value.status, 80) then return nil end
  if value.discovery_status ~= "complete" and value.discovery_status ~= "degraded" then return nil end
  if value.plan_status ~= nil and value.plan_status ~= "complete" and value.plan_status ~= "degraded" then return nil end
  if not strings.is_artifact_root(value.artifact_root) then return nil end
  if value.inventory_path ~= value.artifact_root .. "/module-inventory.json" then return nil end
  if value.feature_inventory_path ~= nil and value.feature_inventory_path ~= value.artifact_root .. "/feature-inventory.json" then return nil end
  if value.test_plan_path ~= nil and value.test_plan_path ~= value.artifact_root .. "/test-plan.json" then return nil end
  if value.evidence_bundle_path ~= nil and value.evidence_bundle_path ~= value.artifact_root .. "/evidence-bundle.json" then return nil end
  if type(value.module_count) ~= "number" or value.module_count < 0 or value.module_count > 64 or math.floor(value.module_count) ~= value.module_count then return nil end
  if value.coverage ~= "visible-session-only" then return nil end
  local copy = {
    schema = T.schemas.module_inventory_summary,
    module = value.module,
    status = value.status,
    discovery_status = value.discovery_status,
    artifact_root = value.artifact_root,
    inventory_path = value.inventory_path,
    module_count = value.module_count,
    coverage = value.coverage,
  }
  if value.feature_inventory_path ~= nil then copy.feature_inventory_path = value.feature_inventory_path end
  if value.test_plan_path ~= nil then copy.test_plan_path = value.test_plan_path end
  if value.plan_status ~= nil then copy.plan_status = value.plan_status end
  if value.evidence_bundle_path ~= nil then copy.evidence_bundle_path = value.evidence_bundle_path end
  return copy_outcome_fields(copy, value)
end

local function copy_flow_summary(value)
  if value == nil then return nil end
  if type(value) ~= "table" then return nil end
  if not has_only(value, { schema = true, planned = true, executed = true, skipped = true, blocked_by_safety_gate = true, blocked_by_fixture_gap = true, blocked_by_environment_readiness = true }) then return nil end
  local copy = {
    schema = value.schema or "platform-test-loop.flow-summary.v1",
    planned = value.planned or 0,
    executed = value.executed or 0,
    skipped = value.skipped or 0,
    blocked_by_safety_gate = value.blocked_by_safety_gate or 0,
    blocked_by_fixture_gap = value.blocked_by_fixture_gap or 0,
    blocked_by_environment_readiness = value.blocked_by_environment_readiness or 0,
  }
  if copy.schema ~= "platform-test-loop.flow-summary.v1" then return nil end
  for _, count in pairs({ copy.planned, copy.executed, copy.skipped, copy.blocked_by_safety_gate, copy.blocked_by_fixture_gap, copy.blocked_by_environment_readiness }) do
    if type(count) ~= "number" or count < 0 or count > 64 or math.floor(count) ~= count then return nil end
  end
  return copy
end

local function copy_module_cdp_execution(value)
  if not has_only(value, { schema = true, module = true, status = true, execution_status = true, classification = true, mode = true, artifact_root = true, execution_path = true, metadata_path = true, test_plan_path = true, cdp_readiness_ref = true, action_count = true, planned_action_count = true, blocked_action_count = true, executed_action_count = true, failed_action_count = true, evidence_bundle_path = true, gap_backlog_path = true, outcome_classification = true, stage_report_path = true, issue_drafts_path = true, publication_dry_run = true, ai_context_manifest_path = true, generated_cases_path = true, generated_case_gate_path = true, ai_agent_generation_path = true, generated_case_agent_review_path = true, ai_generation = true, platform_flow_summary = true }) then return nil end
  if not bounded_field(value.module, max_string) or not bounded_field(value.status, 80) then return nil end
  if value.execution_status ~= "planned"
    and value.execution_status ~= "passed"
    and value.execution_status ~= "failed"
    and value.execution_status ~= "blocked"
    and value.execution_status ~= "degraded" then return nil end
  if not bounded_field(value.classification, 80) or not bounded_field(value.mode, 80) then return nil end
  if not strings.is_artifact_root(value.artifact_root) then return nil end
  if value.execution_path ~= value.artifact_root .. "/cdp-execution.json" then return nil end
  if value.metadata_path ~= value.artifact_root .. "/metadata.json" then return nil end
  if value.test_plan_path ~= nil and value.test_plan_path ~= value.artifact_root .. "/test-plan.json" then return nil end
  if value.ai_context_manifest_path ~= nil and value.ai_context_manifest_path ~= value.artifact_root .. "/ai-context-manifest.json" then return nil end
  if value.generated_cases_path ~= nil and value.generated_cases_path ~= value.artifact_root .. "/generated-test-cases.json" then return nil end
  if value.generated_case_gate_path ~= nil and value.generated_case_gate_path ~= value.artifact_root .. "/generated-case-gate.json" then return nil end
  if value.ai_agent_generation_path ~= nil and value.ai_agent_generation_path ~= value.artifact_root .. "/ai-agent-generation.json" then return nil end
  if value.generated_case_agent_review_path ~= nil and value.generated_case_agent_review_path ~= value.artifact_root .. "/generated-case-agent-review.json" then return nil end
  if value.evidence_bundle_path ~= nil and value.evidence_bundle_path ~= value.artifact_root .. "/evidence-bundle.json" then return nil end
  if type(value.action_count) ~= "number" or value.action_count < 0 or value.action_count > 32 or math.floor(value.action_count) ~= value.action_count then return nil end
  for _, field in ipairs({ "planned_action_count", "blocked_action_count", "executed_action_count", "failed_action_count" }) do
    local count = value[field]
    if count ~= nil and (type(count) ~= "number" or count < 0 or count > 32 or math.floor(count) ~= count) then return nil end
  end
  local flow_summary = copy_flow_summary(value.platform_flow_summary)
  if value.platform_flow_summary ~= nil and flow_summary == nil then return nil end
  local copy = {
    schema = T.schemas.module_cdp_execution_summary,
    module = value.module,
    status = value.status,
    execution_status = value.execution_status,
    classification = value.classification,
    mode = value.mode,
    artifact_root = value.artifact_root,
    execution_path = value.execution_path,
    metadata_path = value.metadata_path,
    action_count = value.action_count,
    planned_action_count = value.planned_action_count or 0,
    blocked_action_count = value.blocked_action_count or 0,
    executed_action_count = value.executed_action_count or 0,
    failed_action_count = value.failed_action_count or 0,
  }
  if value.test_plan_path ~= nil then copy.test_plan_path = value.test_plan_path end
  if value.ai_context_manifest_path ~= nil then copy.ai_context_manifest_path = value.ai_context_manifest_path end
  if value.generated_cases_path ~= nil then copy.generated_cases_path = value.generated_cases_path end
  if value.generated_case_gate_path ~= nil then copy.generated_case_gate_path = value.generated_case_gate_path end
  if value.ai_agent_generation_path ~= nil then copy.ai_agent_generation_path = value.ai_agent_generation_path end
  if value.generated_case_agent_review_path ~= nil then copy.generated_case_agent_review_path = value.generated_case_agent_review_path end
  if flow_summary ~= nil then copy.platform_flow_summary = flow_summary end
  if value.evidence_bundle_path ~= nil then copy.evidence_bundle_path = value.evidence_bundle_path end
  if value.cdp_readiness_ref ~= nil then
    if not bounded_field(value.cdp_readiness_ref, max_string) then return nil end
    copy.cdp_readiness_ref = value.cdp_readiness_ref
  end
  return copy_outcome_fields(copy, value)
end

local function copy_online_heartbeat(value)
  if not has_only(value, { schema = true, target = true, status = true, mode = true }) then return nil end
  if not bounded_field(value.target, max_string) or not bounded_field(value.status, 80) or not bounded_field(value.mode, 80) then return nil end
  return {
    schema = T.schemas.online_heartbeat_summary,
    target = value.target,
    status = value.status,
    mode = value.mode,
  }
end

local function copy_browser_driver(value)
  if not has_only(value, { schema = true, module = true, driver = true, status = true, mode = true, readiness = true }) then return nil end
  if not bounded_field(value.module, max_string) or not bounded_field(value.driver, max_string) then return nil end
  if not bounded_field(value.status, 80) or not bounded_field(value.mode, 80) then return nil end
  local copy = {
    schema = T.schemas.browser_driver_summary,
    module = value.module,
    driver = value.driver,
    status = value.status,
    mode = value.mode,
  }
  if value.readiness ~= nil then
    local readiness = copy_readiness(value.readiness)
    if readiness == nil then return nil end
    copy.readiness = readiness
  end
  return copy
end

function T.copy_native_summary(value)
  if value == nil then return nil end
  if type(value) ~= "table" then return nil end
  if value.schema == T.schemas.module_no_browser_summary then
    return copy_module_no_browser(value)
  end
  if value.schema == T.schemas.module_ui_loop_summary then
    return copy_module_ui_loop(value)
  end
  if value.schema == T.schemas.module_inventory_summary then
    return copy_module_inventory(value)
  end
  if value.schema == T.schemas.module_cdp_execution_summary then
    return copy_module_cdp_execution(value)
  end
  if value.schema == T.schemas.online_heartbeat_summary then
    return copy_online_heartbeat(value)
  end
  if value.schema == T.schemas.browser_driver_summary then
    return copy_browser_driver(value)
  end
  return nil
end

local function source_basis(source_ref, artifact_root, fallback)
  if type(source_ref) == "table" then
    return tostring(source_ref.kind or "source") .. ":" .. tostring(source_ref.ref or "unknown")
  end
  return tostring(artifact_root or fallback or "testing")
end

function T.trace_id(value, source_ref, artifact_root)
  if T.is_bounded_id(value) then return value end
  return "trace-" .. strings.decimal_checksum(source_basis(source_ref, artifact_root, "trace"))
end

function T.dedup_key(value, parts)
  if T.is_bounded_id(value) then return value end
  return T.safe_key(table.concat(parts or { "testing" }, "-"), "testing")
end

return T
