local M = {}

M.schema = "testing-runner.gap-backlog.v1"

local max_string = 512
local max_items = 64

local category = {
  product_defect = "product-defect",
  harness_tooling = "harness-tooling-issue",
  environment_session = "environment-session-issue",
  data_fixture = "data-fixture-gap",
  not_executed_risk = "not-executed-risk",
}
M.category = category

local function bounded(value, fallback)
  local text = type(value) == "string" and value or fallback
  if type(text) ~= "string" or text == "" then return nil end
  text = text:gsub("[%z\1-\31]", " ")
  if #text > max_string then text = text:sub(1, max_string) end
  return text
end

local function safe_target(url)
  if type(url) ~= "string" then return nil end
  local text = url:gsub("[#?].*$", "")
  if #text > max_string then text = text:sub(1, max_string) end
  return text
end

local function add_unique(list, seen, value)
  value = bounded(value)
  if value == nil or seen[value] then return end
  seen[value] = true
  table.insert(list, value)
end

local function fixture_gap(gate)
  return type(gate) == "table" and gate.classification == "fixture-data-gap"
end

local function not_executed_risk(case, gate)
  return case.review_status == "not-executed-risk"
    or (type(gate) == "table" and gate.status == "not-executed-risk")
end

local function selected_priority_map(artifact)
  local map = {}
  if type(artifact) == "table" and type(artifact.case_priorities) == "table" then
    for _, priority in ipairs(artifact.case_priorities) do map[priority] = true end
  end
  return map
end

local function executed_case_map(artifact)
  local map = {}
  if type(artifact) == "table" and type(artifact.actions) == "table" then
    for _, action in ipairs(artifact.actions) do
      if type(action) == "table" and type(action.case_id) == "string" then map[action.case_id] = true end
    end
  end
  return map
end

local function follow_up_for_case(case, gate)
  if fixture_gap(gate) then
    return "Provide safe create/edit test-data fixture evidence plus cleanup or rollback pointer before execution."
  end
  if type(gate) == "table" and gate.classification == "read-only-policy" then
    return "Keep the write path recorded as not-executed risk, or rerun with dry-run/host-approved safe fixtures."
  end
  if type(gate) == "table" and gate.classification == "destructive-or-external-risk" then
    return "Keep destructive or externally visible mutation blocked unless an explicit safe local fixture is approved."
  end
  if not_executed_risk(case, gate) then
    return "Host review is required before turning this risk case into an executable local check."
  end
  return "Add bounded local evidence so the case can be reviewed and executed."
end

local function collect_skipped_cases(planning, artifact)
  local skipped = {}
  local selected = selected_priority_map(artifact)
  local executed = executed_case_map(artifact)
  local has_fixture_gap = false
  local has_risk = false
  if type(planning) ~= "table" or type(planning.test_plan) ~= "table" then
    return skipped, has_fixture_gap, has_risk
  end
  for _, module in ipairs(planning.test_plan.modules or {}) do
    for _, case in ipairs(module.cases or {}) do
      local gate = type(case) == "table" and case.mutation_gate or nil
      local skipped_status = case.review_status
      if case.review_status == "executable" and selected[case.priority] and not executed[case.id] then
        skipped_status = "not-run"
      end
      if skipped_status ~= "executable" then
        if fixture_gap(gate) then has_fixture_gap = true end
        if not_executed_risk(case, gate) then has_risk = true end
        table.insert(skipped, {
          module_id = bounded(case.module_id or module.id),
          case_id = bounded(case.id),
          priority = bounded(case.priority),
          review_status = bounded(skipped_status),
          reason = bounded(case.reason),
          gap_classification = bounded(type(gate) == "table" and gate.classification or nil),
          evidence_pointer = bounded(case.evidence_pointer),
          required_follow_up = follow_up_for_case(case, gate),
        })
        if #skipped >= max_items then return skipped, has_fixture_gap, has_risk end
      end
    end
  end
  return skipped, has_fixture_gap, has_risk
end

local function product_defect_evidence(artifact)
  local defect = type(artifact) == "table" and artifact.product_defect or nil
  if type(defect) ~= "table" then return nil end
  if defect.reproducible ~= true then return nil end
  if not bounded(defect.evidence_pointer) or not bounded(defect.user_facing_behavior) then return nil end
  return defect
end

local function classify(result, artifact, skipped, has_fixture_gap, has_risk)
  local native_classification = type(result.native_summary) == "table" and result.native_summary.classification or nil
  if product_defect_evidence(artifact) ~= nil then return category.product_defect end
  if native_classification == "unsafe-runtime-input"
    or native_classification == "readiness-blocked"
    or native_classification == "missing-cdp-session" then
    return category.environment_session
  end
  if has_fixture_gap then return category.data_fixture end
  if has_risk then return category.not_executed_risk end
  if type(artifact) == "table" and artifact.classification == "missing-cdp-session" then
    return category.environment_session
  end
  if result.status == "blocked" or result.status == "degraded" or #skipped > 0 then
    return category.harness_tooling
  end
  return nil
end

local function blocked_modules_for(result, payload, artifact, outcome)
  local modules = {}
  if outcome == nil then return modules end
  local reason = nil
  if type(artifact) == "table" and type(artifact.limitations) == "table" then reason = artifact.limitations[1] end
  if reason == nil and result.stderr_excerpt ~= nil then reason = result.stderr_excerpt end
  if reason == nil then reason = "native module UI loop requires follow-up before full execution" end
  if result.status == "blocked" or outcome == category.environment_session or outcome == category.harness_tooling then
    table.insert(modules, {
      module = bounded(payload.module, "module"),
      status = result.status,
      reason = bounded(reason),
      required_follow_up = outcome == category.environment_session
        and "Restore local server/readiness/login/CDP session inputs, then rerun the native UI loop."
        or "Complete bounded native browser exploration support or provide the missing harness input, then rerun.",
    })
  end
  return modules
end

local function required_follow_up(outcome, skipped)
  local follow_up, seen = {}, {}
  if outcome == category.product_defect then
    add_unique(follow_up, seen, "Open a product defect with the supporting evidence pointer and reproducible user-facing behavior.")
  elseif outcome == category.environment_session then
    add_unique(follow_up, seen, "Restore local server/readiness/login/CDP session inputs, then rerun the native UI loop.")
  elseif outcome == category.data_fixture then
    add_unique(follow_up, seen, "Provide safe fixture, evidence, and cleanup or rollback pointers for blocked data cases.")
  elseif outcome == category.not_executed_risk then
    add_unique(follow_up, seen, "Host review is required for not-executed risk before expanding executable coverage.")
  elseif outcome == category.harness_tooling then
    add_unique(follow_up, seen, "Complete bounded native browser exploration support or provide the missing harness input, then rerun.")
  end
  for _, item in ipairs(skipped) do add_unique(follow_up, seen, item.required_follow_up) end
  return follow_up
end

function M.path(artifact_root)
  return artifact_root .. "/gap-backlog.json"
end

function M.build(result, payload, artifact, planning)
  local skipped, has_fixture_gap, has_risk = collect_skipped_cases(planning, artifact)
  local outcome = classify(result, artifact, skipped, has_fixture_gap, has_risk)
  return {
    schema = M.schema,
    artifact_kind = "gap-backlog",
    module = bounded(payload.module, "module"),
    status = result.status,
    outcome_classification = outcome,
    artifact_root = result.artifact_root,
    gap_backlog_path = M.path(result.artifact_root),
    evidence_bundle_path = result.native_summary and result.native_summary.evidence_bundle_path,
    execution_path = type(artifact) == "table" and artifact.execution_path or nil,
    blocked_modules = blocked_modules_for(result, payload, artifact, outcome),
    skipped_cases = skipped,
    skipped_count = #skipped,
    required_follow_up = required_follow_up(outcome, skipped),
    base_url = safe_target((payload.ui_loop or {}).base_url),
  }
end

return M
