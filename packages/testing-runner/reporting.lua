local M = {}

M.issue_drafts_schema = "testing-runner.issue-drafts.v1"

local max_string = 512
local max_items = 64

local function bounded(value, fallback)
  local text = value
  if type(text) ~= "string" then text = fallback end
  if type(text) ~= "string" then return nil end
  text = text:gsub("[%z\1-\31]", " ")
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if text == "" then return nil end
  return #text > max_string and text:sub(1, max_string) or text
end

local function line_value(value, fallback)
  return bounded(value, fallback) or fallback or "unknown"
end

local function safe_target(url)
  local text = bounded(url)
  if text == nil then return nil end
  local query = text:find("?", 1, true)
  local fragment = text:find("#", 1, true)
  local cut = query
  if cut == nil or (fragment ~= nil and fragment < cut) then cut = fragment end
  if cut ~= nil then text = text:sub(1, cut - 1) end
  return text
end

local function add_line(lines, value)
  table.insert(lines, value)
end

local function module_rows(payload, planning)
  local rows = {}
  if type(planning) == "table" and type(planning.test_plan) == "table" then
    for _, module in ipairs(planning.test_plan.modules or {}) do
      table.insert(rows, {
        id = bounded(module.id, payload.module),
        name = bounded(module.name, module.id or payload.module),
        entry_url = safe_target(module.entry_url),
        evidence_pointer = bounded(module.evidence_pointer),
        cases = module.cases or {},
      })
      if #rows >= max_items then break end
    end
  end
  if #rows == 0 then
    table.insert(rows, {
      id = bounded(payload.module, "module"),
      name = bounded(payload.module, "module"),
      cases = {},
    })
  end
  return rows
end

local function executed_map(artifact)
  local map = {}
  if type(artifact) == "table" and type(artifact.actions) == "table" then
    for _, action in ipairs(artifact.actions) do
      if type(action) == "table"
        and type(action.case_id) == "string"
        and action.execution_status == "executed"
        and action.assertion_status == "passed" then
        map[action.case_id] = true
      end
    end
  end
  return map
end

local function coverage_for(cases, executed)
  local coverage = {
    P0 = { planned = 0, executed = 0, skipped = 0 },
    P1 = { planned = 0, executed = 0, skipped = 0 },
    P2 = { planned = 0, executed = 0, skipped = 0 },
  }
  for _, case in ipairs(cases or {}) do
    local priority = case.priority
    local bucket = coverage[priority]
    if bucket ~= nil then
      bucket.planned = bucket.planned + 1
      if executed[case.id] then
        bucket.executed = bucket.executed + 1
      elseif case.review_status ~= "executable" then
        bucket.skipped = bucket.skipped + 1
      end
    end
  end
  return coverage
end

local function append_coverage(lines, cases, executed)
  local coverage = coverage_for(cases, executed)
  for _, priority in ipairs({ "P0", "P1", "P2" }) do
    local bucket = coverage[priority]
    add_line(lines, "- " .. priority .. ": " .. bucket.executed .. " executed / " .. bucket.planned .. " planned, " .. bucket.skipped .. " skipped")
  end
end

local function origin_coverage_for(cases, executed)
  local coverage = {
    deterministic = { planned = 0, executed = 0, skipped = 0 },
    ["ai-generated"] = { planned = 0, executed = 0, skipped = 0 },
  }
  for _, case in ipairs(cases or {}) do
    local origin = case.case_origin == "ai-generated" and "ai-generated" or "deterministic"
    local bucket = coverage[origin]
    bucket.planned = bucket.planned + 1
    if executed[case.id] then
      bucket.executed = bucket.executed + 1
    elseif case.review_status ~= "executable" then
      bucket.skipped = bucket.skipped + 1
    end
  end
  return coverage
end

local function append_origin_coverage(lines, cases, executed)
  local coverage = origin_coverage_for(cases, executed)
  for _, origin in ipairs({ "deterministic", "ai-generated" }) do
    local bucket = coverage[origin]
    add_line(lines, "- " .. origin .. ": " .. bucket.executed .. " executed / " .. bucket.planned .. " planned, " .. bucket.skipped .. " skipped")
  end
end

local function append_executed(lines, artifact)
  local actions = type(artifact) == "table" and artifact.actions or nil
  if type(actions) ~= "table" or #actions == 0 then
    add_line(lines, "- No bounded browser/CDP cases were executed in this stage.")
    return
  end
  local executed = 0
  for _, action in ipairs(actions) do
    if action.execution_status == "executed" then
      executed = executed + 1
      add_line(lines, "- " .. line_value(action.case_id, "case") .. " (" .. line_value(action.priority, "priority") .. "): " .. line_value(action.intent or action.action, "scenario") .. " — evidence " .. line_value(action.evidence_pointer, "not recorded"))
    end
  end
  if executed == 0 then
    add_line(lines, "- No bounded browser/CDP cases were executed in this stage.")
  end
end

local function append_skipped(lines, backlog)
  local skipped = type(backlog) == "table" and backlog.skipped_cases or nil
  if type(skipped) ~= "table" or #skipped == 0 then
    add_line(lines, "- No skipped reviewed cases were recorded.")
    return
  end
  for _, item in ipairs(skipped) do
    add_line(lines, "- " .. line_value(item.case_id, "case") .. " (" .. line_value(item.priority, "priority") .. "): " .. line_value(item.review_status, "skipped") .. " — " .. line_value(item.required_follow_up or item.reason, "follow-up required"))
  end
end

local function evidence_paths(paths, backlog)
  local refs = {}
  local function add(label, path)
    path = bounded(path)
    if path ~= nil then table.insert(refs, { label = label, path = path }) end
  end
  add("metadata", paths.metadata)
  add("evidence bundle", paths.bundle)
  add("gap backlog", paths.gap_backlog)
  add("stage report", paths.stage_report)
  add("issue drafts", paths.issue_drafts)
  add("AI generation", paths.ai_generation)
  add("AI test design loop", paths.ai_test_design_loop)
  if type(backlog) == "table" then
    add("execution", backlog.execution_path)
  end
  return refs
end

local function draft_title(payload, outcome)
  local prefix = outcome == "product-defect" and "Review user-facing failure" or "QA follow-up"
  return prefix .. ": " .. line_value(payload.module, "module")
end

local function issue_drafts(result, payload, backlog, paths)
  local follow_up = type(backlog) == "table" and backlog.required_follow_up or nil
  local recommendations = {}
  for _, item in ipairs(follow_up or {}) do
    table.insert(recommendations, {
      title = draft_title(payload, type(backlog) == "table" and backlog.outcome_classification or nil),
      summary = bounded(item, "Review native UI loop follow-up before filing a host issue."),
      outcome_classification = type(backlog) == "table" and backlog.outcome_classification or nil,
      status = result.status,
      stage_report_path = paths.stage_report,
      evidence_bundle_path = paths.bundle,
      gap_backlog_path = paths.gap_backlog,
      dry_run = true,
    })
    if #recommendations >= 16 then break end
  end
  if #recommendations == 0 and result.status ~= "passed" then
    table.insert(recommendations, {
      title = draft_title(payload, type(backlog) == "table" and backlog.outcome_classification or nil),
      summary = "Review the stage report and evidence pointers before deciding whether a host issue is warranted.",
      outcome_classification = type(backlog) == "table" and backlog.outcome_classification or nil,
      status = result.status,
      stage_report_path = paths.stage_report,
      evidence_bundle_path = paths.bundle,
      gap_backlog_path = paths.gap_backlog,
      dry_run = true,
    })
  end
  return {
    schema = M.issue_drafts_schema,
    artifact_kind = "issue-drafts",
    module = bounded(payload.module, "module"),
    status = result.status,
    artifact_root = result.artifact_root,
    stage_report_path = paths.stage_report,
    evidence_bundle_path = paths.bundle,
    gap_backlog_path = paths.gap_backlog,
    publication_dry_run = true,
    external_write = false,
    recommendations = recommendations,
    recommendation_count = #recommendations,
  }
end

local function markdown(result, payload, artifact, planning, backlog, paths)
  local lines = {}
  local modules = module_rows(payload, planning)
  local executed = executed_map(artifact)
  add_line(lines, "# Native module UI loop stage report")
  add_line(lines, "")
  add_line(lines, "- Module: " .. line_value(payload.module, "module"))
  add_line(lines, "- Status: " .. line_value(result.status, "unknown"))
  add_line(lines, "- Runner classification: " .. line_value(type(result.native_summary) == "table" and result.native_summary.classification or nil, "not-recorded"))
  add_line(lines, "- Outcome classification: " .. line_value(type(backlog) == "table" and backlog.outcome_classification or nil, "not-recorded"))
  add_line(lines, "- Publication handoff: dry-run pointer handoff only")
  add_line(lines, "")
  add_line(lines, "## Discovered modules")
  for _, module in ipairs(modules) do
    add_line(lines, "- " .. line_value(module.name, module.id) .. " (`" .. line_value(module.id, "module") .. "`) at " .. line_value(module.entry_url, "not recorded") .. " — evidence " .. line_value(module.evidence_pointer, "not recorded"))
  end
  add_line(lines, "")
  add_line(lines, "## Coverage status")
  for _, module in ipairs(modules) do
    add_line(lines, "### " .. line_value(module.name, module.id))
    append_coverage(lines, module.cases, executed)
    append_origin_coverage(lines, module.cases, executed)
  end
  add_line(lines, "")
  add_line(lines, "## AI generated coverage")
  local ai_summary = type(planning) == "table" and type(planning.test_plan) == "table" and planning.test_plan.ai_generation or nil
  add_line(lines, "- Status: " .. line_value(ai_summary and ai_summary.status, "disabled"))
  add_line(lines, "- Generated cases: " .. tostring(ai_summary and ai_summary.generated_case_count or 0))
  add_line(lines, "- Executable generated cases: " .. tostring(ai_summary and ai_summary.executable_generated_case_count or 0))
  add_line(lines, "- Blocked/rejected generated cases: " .. tostring((ai_summary and ai_summary.blocked_generated_case_count or 0) + (ai_summary and ai_summary.rejected_generated_case_count or 0)))
  add_line(lines, "- Agent generation: " .. line_value(ai_summary and ai_summary.agent_generation_status, "not-recorded") .. " (seats " .. tostring(ai_summary and ai_summary.agent_generation_seat_count or 0) .. ") — " .. line_value(ai_summary and ai_summary.ai_agent_generation_path, "not recorded"))
  add_line(lines, "- Agent review: " .. line_value(ai_summary and ai_summary.agent_review_status, "not-recorded") .. " (seats " .. tostring(ai_summary and ai_summary.agent_review_seat_count or 0) .. ", approved " .. tostring(ai_summary and ai_summary.agent_approved_generated_case_count or 0) .. ") — " .. line_value(ai_summary and ai_summary.generated_case_agent_review_path, "not recorded"))
  local loop = type(planning) == "table" and planning.ai_review_closure or nil
  add_line(lines, "- AI test design loop: " .. line_value(loop and loop.status, "not-recorded") .. " (eligible " .. tostring(loop and loop.execution_eligible_generated_case_count or 0) .. ", blocked " .. tostring(loop and loop.blocked_generated_case_count or 0) .. ", risk " .. tostring(loop and loop.not_executed_risk_generated_case_count or 0) .. ") — " .. line_value(ai_summary and ai_summary.ai_test_design_loop_path, "not recorded"))
  add_line(lines, "")
  add_line(lines, "## Executed user-facing scenarios")
  append_executed(lines, artifact)
  add_line(lines, "")
  add_line(lines, "## Skipped or deferred scenarios")
  append_skipped(lines, backlog)
  add_line(lines, "")
  add_line(lines, "## Evidence pointers")
  for _, ref in ipairs(evidence_paths(paths, backlog)) do
    add_line(lines, "- " .. ref.label .. ": " .. ref.path)
  end
  add_line(lines, "")
  add_line(lines, "## Issue-draft recommendations")
  add_line(lines, "Recommendations are dry-run artifacts only. No host issue, comment, or external publication write is performed by this package.")
  for _, item in ipairs((type(backlog) == "table" and backlog.required_follow_up) or {}) do
    add_line(lines, "- " .. line_value(item, "Review evidence before filing."))
  end
  return table.concat(lines, "\n") .. "\n"
end

function M.stage_report_path(artifact_root)
  return artifact_root .. "/stage-report.md"
end

function M.issue_drafts_path(artifact_root)
  return artifact_root .. "/issue-drafts.json"
end

function M.final_aggregate_report_path(artifact_root)
  return artifact_root .. "/final-report.md"
end

function M.rendered_aggregate_report_path(artifact_root)
  return artifact_root .. "/.rendered/final-aggregate-report.md"
end

local function require_aggregate_report(condition, message)
  if not condition then
    error("testing-runner: malformed-final-aggregate: " .. message)
  end
end

function M.final_aggregate(aggregate, coverage_matrix)
  require_aggregate_report(type(aggregate) == "table" and aggregate.schema == "platform-test-loop.aggregate.v1", "aggregate schema is unknown")
  require_aggregate_report(type(aggregate.modules) == "table", "aggregate modules are required")
  require_aggregate_report(type(coverage_matrix) == "table" and coverage_matrix.schema == "platform-test-loop.coverage-matrix.v1", "coverage matrix schema is unknown")
  require_aggregate_report(type(coverage_matrix.rows) == "table", "coverage matrix rows are required")

  local lines = {}
  local run_ref = type(aggregate.source_ref) == "table" and aggregate.source_ref.ref or nil
  add_line(lines, "# Final platform testing report")
  add_line(lines, "")
  add_line(lines, "- Run: " .. line_value(run_ref, aggregate.dedup_key))
  add_line(lines, "- Trace ID: " .. line_value(aggregate.trace_id, "not-recorded"))
  add_line(lines, "- Status: " .. line_value(aggregate.status, "unknown"))
  add_line(lines, "- Artifact root: " .. line_value(aggregate.artifact_root, "not-recorded"))
  add_line(lines, "")
  add_line(lines, "## Modules")
  for _, module in ipairs(aggregate.modules) do
    local report = module.module_report_path and "[module report](" .. module.module_report_path .. ")" or "module report not recorded"
    add_line(lines, "- " .. line_value(module.module, "module") .. ": " .. line_value(module.status, "unknown") .. " - " .. report)
  end
  add_line(lines, "")
  add_line(lines, "## Matrix-backed coverage")
  local backed = 0
  for _, row in ipairs(coverage_matrix.rows) do
    if row.evidence_pointer ~= nil then
      backed = backed + 1
      add_line(lines, "- " .. line_value(row.claim, row.id) .. " (`" .. line_value(row.module, "module") .. "`) - [evidence](" .. row.evidence_pointer .. ")")
    end
  end
  if backed == 0 then add_line(lines, "- No matrix-backed coverage claims were supplied.") end
  return table.concat(lines, "\n") .. "\n"
end

function M.build(result, payload, artifact, planning, backlog, paths)
  paths = paths or {}
  paths.metadata = paths.metadata or (result.artifact_root .. "/metadata.json")
  paths.bundle = paths.bundle or (result.artifact_root .. "/evidence-bundle.json")
  paths.gap_backlog = paths.gap_backlog or (result.artifact_root .. "/gap-backlog.json")
  paths.stage_report = paths.stage_report or M.stage_report_path(result.artifact_root)
  paths.issue_drafts = paths.issue_drafts or M.issue_drafts_path(result.artifact_root)
  return {
    stage_report = markdown(result, payload, artifact, planning, backlog, paths),
    issue_drafts = issue_drafts(result, payload, backlog, paths),
  }
end

return M
