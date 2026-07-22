local environment_factory = require("contract.environment_factory")
local structured_execution = require("contract.structured_execution")
local testing_design = require("contract.testing_design")
local strings = require("contract.strings")

local M = {}

M.schemas = {
  request = "workflow-qa.run-request.v2",
  state = "workflow-qa.run-state.v2",
  interrupt = "workflow-qa.interrupt.v2",
  terminal = "workflow-qa.terminal-request.v2",
}

local function fail(classification, message)
  error("contract.workflow-qa: " .. classification .. ": " .. message)
end

local function bounded(value, limit)
  return strings.is_bounded_string(value, limit or 512)
    and value:find("[%z\1-\31\127]") == nil
end

local function only_fields(value, allowed, label)
  if type(value) ~= "table" then fail("malformed-" .. label, label .. " must be a table") end
  for key, _ in pairs(value) do
    if allowed[key] ~= true then fail("malformed-" .. label, "unsupported field " .. tostring(key)) end
  end
end

local function dense(value, limit, non_empty)
  if type(value) ~= "table" then return false end
  local count, highest = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then return false end
    count = count + 1
    highest = math.max(highest, key)
  end
  return count == highest and count <= limit and (not non_empty or count > 0)
end

local function digest(value)
  return type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") ~= nil
end

local function safe_pointer(value, root)
  return strings.is_artifact_root(value, 4096)
    and (root == nil or value == root or value:sub(1, #root + 1) == root .. "/")
end

local function has_label(labels, expected)
  for _, label in ipairs(labels or {}) do if label == expected then return true end end
  return false
end

local function validate_repository(value)
  only_fields(value, { slug = true, url = true, commit_sha = true }, "repository")
  if not bounded(value.slug, 180) or value.slug:match("^[%w_.%-]+/[%w_.%-]+$") == nil
    or not bounded(value.url, 1024) or value.url:match("^https://") == nil
    or value.url:find("@", 1, true) ~= nil or value.url:find("?", 1, true) ~= nil
    or type(value.commit_sha) ~= "string" or #value.commit_sha ~= 40
    or value.commit_sha:match("^[0-9a-f]+$") == nil then
    fail("mutable-repository", "repository must bind slug, credential-free URL, and full commit")
  end
end

local function validate_proposed_action(value)
  only_fields(value, {
    action = true, target = true, expected = true, target_module_id = true, evidence_pointer = true,
  }, "proposed-action")
  if not bounded(value.action, 80) or not bounded(value.target, 512) or not bounded(value.expected, 512) then
    fail("malformed-seeds", "proposed action requires bounded action, target, and expected")
  end
  if value.target_module_id ~= nil and not bounded(value.target_module_id, 180) then
    fail("malformed-seeds", "target_module_id is invalid")
  end
  if value.evidence_pointer ~= nil and not safe_pointer(value.evidence_pointer) then
    fail("malformed-seeds", "action evidence pointer is unsafe")
  end
end

local function validate_proposed_case(value)
  only_fields(value, {
    id = true, module_id = true, priority = true, title = true, objective = true,
    case_kind = true, actions = true, expected_observable = true,
    coverage_subject_ids = true, review_status = true,
  }, "proposed-case")
  if not bounded(value.id, 180) or not bounded(value.module_id, 180)
    or (value.priority ~= "P0" and value.priority ~= "P1" and value.priority ~= "P2")
    or not bounded(value.title, 512) or not bounded(value.objective, 512)
    or not bounded(value.case_kind, 80) or not bounded(value.expected_observable, 512)
    or not dense(value.actions, 8, true) or not dense(value.coverage_subject_ids, 32, true) then
    fail("malformed-seeds", "proposed case is incomplete or unbounded")
  end
  for _, action in ipairs(value.actions) do validate_proposed_action(action) end
  for _, subject_id in ipairs(value.coverage_subject_ids) do
    if not bounded(subject_id, 180) then fail("malformed-seeds", "coverage subject ID is invalid") end
  end
  if value.review_status ~= nil and value.review_status ~= "executable"
    and value.review_status ~= "blocked" and value.review_status ~= "not-executed-risk" then
    fail("malformed-seeds", "review_status is invalid")
  end
end

function M.validate_request(value)
  only_fields(value, {
    schema = true, issue = true, run_id = true, repository = true, artifact_root = true,
    state_ref = true, proposed_cases = true, environment_start = true,
    analysis_request = true, design_module_start = true, structured_execution = true,
    publication = true, terminal_policy = true, trace_id = true, dedup_key = true,
  }, "request")
  if value.schema ~= M.schemas.request then fail("unknown-schema", "expected " .. M.schemas.request) end
  only_fields(value.issue, { repository = true, number = true, state = true, labels = true }, "issue")
  if value.issue.state ~= "open" or value.issue.repository ~= value.repository.slug
    or type(value.issue.number) ~= "number" or value.issue.number < 1 or value.issue.number ~= math.floor(value.issue.number)
    or not dense(value.issue.labels, 32, true) or not has_label(value.issue.labels, "fkst-qa") then
    fail("unclaimable-request", "only open fkst-qa issues are claimable")
  end
  validate_repository(value.repository)
  if not bounded(value.run_id, 180) or not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then
    fail("malformed-identity", "run, trace, and dedup identity must be bounded")
  end
  if not safe_pointer(value.artifact_root) or value.state_ref ~= value.artifact_root .. "/workflow-state.json" then
    fail("malformed-pointer", "artifact root and state pointer are invalid")
  end
  if not dense(value.proposed_cases, 32, true) then fail("malformed-seeds", "proposed_cases must be non-empty and bounded") end
  for _, proposed in ipairs(value.proposed_cases) do validate_proposed_case(proposed) end

  environment_factory.validate_start(value.environment_start)
  if value.environment_start.operation_id ~= value.run_id
    or value.environment_start.repository.url ~= value.repository.url
    or value.environment_start.repository.commit_sha ~= value.repository.commit_sha
    or value.environment_start.trace_id ~= value.trace_id
    or value.environment_start.dedup_key ~= value.dedup_key
    or not safe_pointer(value.environment_start.artifact_root, value.artifact_root) then
    fail("foreign-environment", "environment request differs from the closed run identity")
  end

  testing_design.validate_request(value.analysis_request)
  if value.analysis_request.repository.url ~= value.repository.url
    or value.analysis_request.repository.commit_sha ~= value.repository.commit_sha
    or value.analysis_request.trace_id ~= value.trace_id
    or value.analysis_request.dedup_key ~= value.dedup_key
    or not safe_pointer(value.analysis_request.artifact_root, value.artifact_root) then
    fail("foreign-analysis", "analysis request differs from the closed run identity")
  end

  local module_start = value.design_module_start
  if type(module_start) ~= "table" or module_start.schema ~= "module-testing-pipeline.module-start.v1"
    or not safe_pointer(module_start.artifact_root, value.artifact_root)
    or type(module_start.source_ref) ~= "table" or module_start.source_ref.kind ~= "workflow-qa"
    or module_start.source_ref.ref ~= value.run_id or module_start.trace_id ~= value.trace_id
    or module_start.dedup_key ~= value.dedup_key
    or (type(module_start.cdp_execution) ~= "table" and type(module_start.module_discovery) ~= "table")
    or (type(module_start.cdp_execution) == "table"
      and type(module_start.cdp_execution.ai_design_loop_request) ~= "table") then
    fail("foreign-design", "design module start differs from the closed run identity")
  end

  only_fields(value.structured_execution, {
    artifact_root = true, preauthorization_ref = true, preauthorization_sha256 = true,
    case_catalog_ref = true, case_catalog_sha256 = true, structured_plan_ref = true,
    grant_ref = true,
  }, "structured-execution")
  local execution = value.structured_execution
  if not safe_pointer(execution.artifact_root, value.artifact_root)
    or not safe_pointer(execution.preauthorization_ref, value.artifact_root)
    or not safe_pointer(execution.case_catalog_ref, value.artifact_root)
    or not safe_pointer(execution.structured_plan_ref, execution.artifact_root)
    or not safe_pointer(execution.grant_ref, execution.artifact_root)
    or not digest(execution.preauthorization_sha256) or not digest(execution.case_catalog_sha256) then
    fail("malformed-execution", "structured execution configuration is invalid")
  end

  only_fields(value.publication, {
    ledger_ref = true, defect_ledger_ref = true, defect_receipt_ref = true,
    issue_drafts_ref = true, aggregate_report_ref = true, terminal_summary_ref = true,
  }, "publication")
  for _, field in ipairs({
    "ledger_ref", "defect_ledger_ref", "defect_receipt_ref", "issue_drafts_ref",
    "aggregate_report_ref", "terminal_summary_ref",
  }) do
    if not safe_pointer(value.publication[field], value.artifact_root) then
      fail("malformed-publication", field .. " is outside the run artifact root")
    end
  end
  only_fields(value.terminal_policy, { mode = true }, "terminal-policy")
  if value.terminal_policy.mode ~= "host" then
    fail("unsupported-terminal-policy", "only host terminal policy is implemented")
  end
  return value
end

function M.validate_interrupt(value)
  only_fields(value, { schema = true, interruption = true, trace_id = true, dedup_key = true }, "interrupt")
  if value.schema ~= M.schemas.interrupt
    or (value.interruption ~= "cancelled" and value.interruption ~= "interrupted" and value.interruption ~= "timed-out")
    or not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then
    fail("malformed-interruption", "interrupt identity or status is invalid")
  end
  return value
end

function M.validate_terminal(value)
  only_fields(value, {
    schema = true, repository = true, issue_number = true, run_id = true,
    status = true, counts = true, artifact_root = true,
    aggregate_report_ref = true, aggregate_report_sha256 = true,
    aggregate_publication_receipt_ref = true, aggregate_publication_receipt_sha256 = true,
    cleanup_receipt_ref = true, cleanup_receipt_sha256 = true,
    terminal_policy = true, trace_id = true, dedup_key = true,
  }, "terminal")
  local terminal_statuses = {
    passed = true, failed = true, blocked = true, degraded = true, error = true,
    cancelled = true, interrupted = true, ["timed-out"] = true,
  }
  if value.schema ~= M.schemas.terminal or not bounded(value.repository, 180)
    or value.repository:match("^[%w_.%-]+/[%w_.%-]+$") == nil
    or type(value.issue_number) ~= "number" or value.issue_number < 1
    or value.issue_number ~= math.floor(value.issue_number)
    or not bounded(value.run_id, 180) or not terminal_statuses[value.status]
    or not safe_pointer(value.artifact_root) or value.terminal_policy ~= "host"
    or not bounded(value.trace_id, 180) or not bounded(value.dedup_key, 180) then
    fail("malformed-terminal", "terminal handoff identity or policy is invalid")
  end
  only_fields(value.counts, {
    planned = true, executed = true, passed = true, failed = true,
    skipped = true, error = true, blocked = true,
  }, "terminal-counts")
  for _, field in ipairs({ "planned", "executed", "passed", "failed", "skipped", "error", "blocked" }) do
    local count = value.counts[field]
    if type(count) ~= "number" or count < 0 or count > 100000 or count ~= math.floor(count) then
      fail("malformed-terminal", "terminal counts must be bounded non-negative integers")
    end
  end
  for _, field in ipairs({ "aggregate_report_ref", "aggregate_publication_receipt_ref", "cleanup_receipt_ref" }) do
    if not safe_pointer(value[field], value.artifact_root) then
      fail("malformed-terminal", field .. " must remain under the run artifact root")
    end
  end
  for _, field in ipairs({ "aggregate_report_sha256", "aggregate_publication_receipt_sha256", "cleanup_receipt_sha256" }) do
    if not digest(value[field]) then fail("malformed-terminal", field .. " must be a lowercase SHA-256 digest") end
  end
  return value
end

function M.same_request(left, right)
  local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for key, item in pairs(a) do if not equal(item, b[key]) then return false end end
    for key, _ in pairs(b) do if a[key] == nil then return false end end
    return true
  end
  return equal(left, right)
end

M.structured_execution = structured_execution

return M
