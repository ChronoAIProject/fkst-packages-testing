local M = {}

M.feature_inventory_schema = "testing-runner.feature-inventory.v1"
M.test_plan_schema = "testing-runner.module-test-plan.v1"

local function module_label(module)
  return module.name or module.visible_label or module.route or module.id or "module"
end

local function case_id(module, suffix)
  return tostring(module.id or "module") .. ":" .. suffix
end

local function review_case(module, priority, suffix, title, case_kind, review_status, reason)
  return {
    id = case_id(module, suffix),
    module_id = module.id,
    priority = priority,
    title = title,
    case_kind = case_kind,
    evidence_pointer = module.evidence_pointer,
    review_status = review_status,
    reason = reason,
  }
end

local function p2_status(mutation_policy)
  if mutation_policy == "host-approved" then
    return "blocked", "requires host-approved fixtures before execution"
  end
  if mutation_policy == "dry-run" then
    return "blocked", "requires dry-run mutation fixture before execution"
  end
  return "not-executed-risk", "mutation_policy read-only records this as a gap"
end

local function feature_for(module)
  return {
    id = module.id,
    name = module_label(module),
    entry_url = module.entry_url,
    route = module.route,
    visible_label = module.visible_label,
    discovery_source = module.discovery_source,
    confidence = module.confidence,
    evidence_pointer = module.evidence_pointer,
    feature_signals = {
      "entry-route",
      "visible-label-or-route",
      "local-session-evidence",
    },
  }
end

local function cases_for(module, mutation_policy)
  local label = module_label(module)
  local cases = {
    review_case(module, "P0", "reachability", "Reach " .. label .. " entry URL", "entry-health", "executable", "accepted local inventory module has in-scope entry_url"),
    review_case(module, "P0", "page-load", "Load " .. label .. " without fatal render failure", "entry-health", "executable", "covered by local UI loop readiness and page load observation"),
    review_case(module, "P0", "visible-elements", "Verify key visible elements for " .. label, "entry-health", "executable", "module has visible label or route evidence"),
    review_case(module, "P0", "console-network-health", "Check obvious console and network health for " .. label, "entry-health", "executable", "safe read-only health signal for local session"),
    review_case(module, "P1", "navigation", "Navigate to " .. label .. " from visible route or link", "primary-interaction", "executable", "navigation or route evidence is in scope"),
    review_case(module, "P1", "search-filter", "Exercise visible search or filtering controls for " .. label, "primary-interaction", "blocked", "requires visible search/filter control evidence"),
    review_case(module, "P1", "open-details", "Open visible detail surfaces for " .. label, "primary-interaction", "blocked", "requires visible detail-link evidence"),
  }
  local status, reason = p2_status(mutation_policy)
  table.insert(cases, review_case(module, "P2", "write-flow", "Exercise write flow for " .. label, "mutation-or-edge", status, reason))
  table.insert(cases, review_case(module, "P2", "state-change", "Verify state change handling for " .. label, "mutation-or-edge", status, reason))
  table.insert(cases, review_case(module, "P2", "negative-edge", "Exercise negative and edge paths for " .. label, "mutation-or-edge", "not-executed-risk", "negative paths require host-selected fixtures and assertions"))
  return cases
end

local function count_cases(modules)
  local counts = { executable = 0, blocked = 0, ["not-executed-risk"] = 0 }
  for _, module in ipairs(modules) do
    for _, case in ipairs(module.cases or {}) do
      counts[case.review_status] = (counts[case.review_status] or 0) + 1
    end
  end
  return counts
end

function M.build(inventory, ui_loop, artifact_root)
  local mutation_policy = (ui_loop or {}).mutation_policy or "read-only"
  local inventory_path = artifact_root .. "/module-inventory.json"
  local feature_inventory_path = artifact_root .. "/feature-inventory.json"
  local test_plan_path = artifact_root .. "/test-plan.json"
  local feature_modules = {}
  local plan_modules = {}

  for _, module in ipairs(inventory.modules or {}) do
    table.insert(feature_modules, feature_for(module))
    table.insert(plan_modules, {
      id = module.id,
      name = module_label(module),
      entry_url = module.entry_url,
      evidence_pointer = module.evidence_pointer,
      cases = cases_for(module, mutation_policy),
    })
  end

  local counts = count_cases(plan_modules)
  local plan_status = inventory.discovery_status == "complete" and "complete" or "degraded"
  local review_status = plan_status == "complete" and "reviewed" or "degraded"
  local readiness_status = type(inventory.readiness) == "table" and inventory.readiness.status or "unknown"

  local feature_inventory = {
    schema = M.feature_inventory_schema,
    artifact_kind = "feature-inventory",
    artifact_root = artifact_root,
    inventory_path = inventory_path,
    modules = feature_modules,
    module_count = #feature_modules,
    coverage = inventory.coverage,
    limitations = inventory.limitations,
  }

  local test_plan = {
    schema = M.test_plan_schema,
    artifact_kind = "module-test-plan",
    artifact_root = artifact_root,
    inventory_path = inventory_path,
    feature_inventory_path = feature_inventory_path,
    modules = plan_modules,
    module_count = #plan_modules,
    plan_status = plan_status,
    coverage = inventory.coverage,
    review_gate = {
      status = review_status,
      mutation_policy = mutation_policy,
      readiness_status = readiness_status,
      executable_count = counts.executable,
      blocked_count = counts.blocked,
      not_executed_risk_count = counts["not-executed-risk"],
    },
    limitations = inventory.limitations,
  }

  return {
    feature_inventory_path = feature_inventory_path,
    test_plan_path = test_plan_path,
    plan_status = plan_status,
    feature_inventory = feature_inventory,
    test_plan = test_plan,
  }
end

return M
