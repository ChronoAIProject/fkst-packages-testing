local M = {}

local ai_generation = require("module_ai_generation")
local ai_design_loop = require("module_ai_design_loop")

M.feature_inventory_schema = "testing-runner.feature-inventory.v1"
M.test_plan_schema = "testing-runner.module-test-plan.v1"

local function module_label(module)
  return module.name or module.visible_label or module.route or module.id or "module"
end

local function case_id(module, suffix)
  return tostring(module.id or "module") .. ":" .. suffix
end

local safe_mutation_kinds = {
  ["create-test-data"] = true,
  ["edit-test-data"] = true,
}

local blocked_mutation_kinds = {
  delete = true,
  permissions = true,
  billing = true,
  ["external-notification"] = true,
  ["real-user-impact"] = true,
}

local function review_case(module, priority, suffix, title, case_kind, review_status, reason, extra)
  local case = {
    id = case_id(module, suffix),
    module_id = module.id,
    priority = priority,
    title = title,
    objective = title,
    case_kind = case_kind,
    case_origin = "deterministic",
    evidence_pointer = module.evidence_pointer,
    review_status = review_status,
    reason = reason,
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do case[key] = value end
  end
  return case
end

local function fixture_complete(fixture)
  return type(fixture) == "table"
    and type(fixture.fixture_lifecycle_path) == "string"
    and fixture.fixture_lifecycle_path:sub(1, 14) == ".testing/runs/"
end

local function mutation_gate(policy, fixture)
  if policy == "read-only" then
    return "not-executed-risk", "mutation_policy read-only records this as a gap", {
      status = "not-executed-risk",
      classification = "read-only-policy",
    }
  end
  if type(fixture) ~= "table" then
    return "blocked", "fixture/data gap: safe mutation requires a host fixture lifecycle descriptor", {
      status = "blocked",
      classification = "fixture-data-gap",
    }
  end
  local kind = fixture.mutation_kind
  if blocked_mutation_kinds[kind] then
    return "blocked", "mutation kind " .. kind .. " is destructive or externally visible and blocked by default", {
      status = "blocked",
      classification = "destructive-or-external-risk",
      mutation_kind = kind,
    }
  end
  if not safe_mutation_kinds[kind] or not fixture_complete(fixture) then
    return "blocked", "fixture/data gap: create/edit test-data mutations require a fixture lifecycle descriptor", {
      status = "blocked",
      classification = "fixture-data-gap",
      mutation_kind = kind,
    }
  end
  return "executable", "safe local test-data mutation has a host fixture lifecycle descriptor", {
    status = "executable",
    classification = "safe-local-test-data",
    mutation_kind = kind,
    fixture_lifecycle_path = fixture.fixture_lifecycle_path,
  }
end

local function mutation_fixture_index(fixtures)
  local indexed = {}
  if type(fixtures) ~= "table" then return indexed end
  for _, fixture in ipairs(fixtures) do
    if type(fixture) == "table" and type(fixture.case_id) == "string" then
      indexed[fixture.case_id] = fixture
    end
  end
  return indexed
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

local function cases_for(module, mutation_policy, fixtures)
  local label = module_label(module)
  local indexed_fixtures = mutation_fixture_index(fixtures)
  local cases = {
    review_case(module, "P0", "reachability", "Reach " .. label .. " entry URL", "entry-health", "executable", "accepted local inventory module has in-scope entry_url"),
    review_case(module, "P0", "page-load", "Load " .. label .. " without fatal render failure", "entry-health", "executable", "covered by local UI loop readiness and page load observation"),
    review_case(module, "P0", "visible-elements", "Verify key visible elements for " .. label, "entry-health", "executable", "module has visible label or route evidence"),
    review_case(module, "P0", "console-network-health", "Check obvious console and network health for " .. label, "entry-health", "executable", "safe read-only health signal for local session"),
    review_case(module, "P1", "navigation", "Navigate to " .. label .. " from visible route or link", "primary-interaction", "executable", "navigation or route evidence is in scope"),
    review_case(module, "P1", "search-filter", "Exercise visible search or filtering controls for " .. label, "primary-interaction", "blocked", "requires visible search/filter control evidence"),
    review_case(module, "P1", "open-details", "Open visible detail surfaces for " .. label, "primary-interaction", "blocked", "requires visible detail-link evidence"),
  }
  local write_id = case_id(module, "write-flow")
  local state_id = case_id(module, "state-change")
  local write_status, write_reason, write_gate = mutation_gate(mutation_policy, indexed_fixtures[write_id])
  local state_status, state_reason, state_gate = mutation_gate(mutation_policy, indexed_fixtures[state_id])
  table.insert(cases, review_case(module, "P2", "write-flow", "Exercise safe create/edit test-data flow for " .. label, "mutation-or-edge", write_status, write_reason, {
    mutation_gate = write_gate,
  }))
  table.insert(cases, review_case(module, "P2", "state-change", "Verify safe test-data state change handling for " .. label, "mutation-or-edge", state_status, state_reason, {
    mutation_gate = state_gate,
  }))
  table.insert(cases, review_case(module, "P2", "negative-edge", "Exercise negative and edge paths for " .. label, "mutation-or-edge", "not-executed-risk", "negative paths require host-selected fixtures and assertions", {
    mutation_gate = {
      status = "not-executed-risk",
      classification = "host-selected-assertion-gap",
    },
  }))
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

function M.build(inventory, ui_loop, artifact_root, opts)
  opts = opts or {}
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
      cases = cases_for(module, mutation_policy, opts.mutation_fixtures),
    })
  end

  local ai_design_case_count = 0
  if opts.ai_design_loop_state ~= nil then
    ai_design_loop.validate_state(opts.ai_design_loop_state)
    ai_design_case_count = ai_design_loop.merge_into_plan(plan_modules, opts.ai_design_loop_state)
  end

  local ai_context, generated_cases, generated_case_gate, agent_generation, agent_review, ai_review_closure
  if ai_generation.enabled(opts.ai_generation) then
    ai_context = ai_generation.build_context(inventory, ui_loop, artifact_root, {
      ai_generation = opts.ai_generation,
      step_budget = opts.step_budget,
      case_priorities = opts.case_priorities,
    })
    generated_cases = opts.generated_cases
    if generated_cases == nil then error("testing-runner: ai-artifact-missing: generated cases") end
    ai_generation.validate_generated_cases(generated_cases)
    generated_case_gate = ai_generation.gate_generated_cases(generated_cases, ai_context, opts.ai_generation)
    if type(opts.generated_case_gate) ~= "table" or opts.generated_case_gate.gate_digest ~= generated_case_gate.gate_digest then
      error("testing-runner: ai-artifact-mismatch: deterministic gate")
    end
    agent_generation = opts.ai_agent_generation
    agent_review = opts.generated_case_agent_review
    if (opts.ai_generation or {}).mode == "autonomous-reviewed" then
      ai_generation.validate_agent_generation(agent_generation)
      ai_generation.validate_agent_review(agent_review)
      if agent_generation.candidate_generation_digest ~= generated_cases.generation_digest then
        error("testing-runner: ai-artifact-mismatch: agent generation digest")
      end
      if agent_review.candidate_generation_digest ~= generated_cases.generation_digest
        or agent_review.gate_digest ~= generated_case_gate.gate_digest then
        error("testing-runner: ai-artifact-mismatch: agent review digest")
      end
      ai_generation.merge_generated_cases(plan_modules, generated_case_gate, agent_review)
    else
      ai_generation.merge_generated_cases(plan_modules, generated_case_gate)
    end
    ai_review_closure = ai_generation.build_review_closure(ai_context, generated_cases, generated_case_gate, agent_generation, agent_review)
  end

  local counts = count_cases(plan_modules)
  local ai_summary = ai_generation.summary(ai_context, generated_cases, generated_case_gate, agent_generation, agent_review)
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
      ai_generation = ai_summary,
      ai_design_case_count = ai_design_case_count,
      ai_design_closure = opts.ai_design_loop_state and opts.ai_design_loop_state.current_artifacts.closure or nil,
    },
    ai_generation = ai_summary,
    ai_test_design_loop = ai_review_closure,
    limitations = inventory.limitations,
  }

  return {
    feature_inventory_path = feature_inventory_path,
    test_plan_path = test_plan_path,
    plan_status = plan_status,
    feature_inventory = feature_inventory,
    test_plan = test_plan,
    ai_context = ai_context,
    generated_cases = generated_cases,
    generated_case_gate = generated_case_gate,
    ai_agent_generation = agent_generation,
    generated_case_agent_review = agent_review,
    ai_review_closure = ai_review_closure,
    ai_design_loop_state = opts.ai_design_loop_state,
  }
end

return M
