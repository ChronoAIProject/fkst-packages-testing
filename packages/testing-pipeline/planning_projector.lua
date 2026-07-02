local P = {}

local evidence = require("planning_evidence")

local review_statuses = {
  executable = true,
  blocked = true,
  ["not-executed risk"] = true,
}

local testing_contract = require("contract.testing")

local function safe_id(value, fallback)
  return testing_contract.safe_key(value, fallback or "case")
end

local function classify(kind, label)
  local text = (tostring(kind or "") .. " " .. tostring(label or "")):lower()
  if text:find("search", 1, true) then return "P1", "search" end
  if text:find("filter", 1, true) then return "P1", "filter" end
  if text:find("detail", 1, true) or text:find("open", 1, true) then return "P1", "details" end
  if text:find("nav", 1, true) or text:find("link", 1, true) then return "P1", "navigation" end
  if text:find("create", 1, true) or text:find("add", 1, true) or text:find("edit", 1, true) then return "P2", "write-flow" end
  if text:find("delete", 1, true) or text:find("save", 1, true) or text:find("submit", 1, true) then return "P2", "write-flow" end
  if text:find("write", 1, true) or text:find("mutat", 1, true) then return "P2", "write-flow" end
  if text:find("state", 1, true) or text:find("toggle", 1, true) then return "P2", "state-change" end
  if text:find("edge", 1, true) or text:find("boundary", 1, true) then return "P2", "edge-case" end
  if text:find("negative", 1, true) or text:find("invalid", 1, true) then
    return "P2", "negative-path"
  end
  if text:find("validation", 1, true) then return "P2", "negative-path" end
  return "P1", "interaction"
end

local function interactions(raw)
  local items = {}
  evidence.append_items(items, raw.interactions or raw.actions or raw.features, "interaction")
  evidence.append_items(items, raw.navigation, "navigation")
  evidence.append_items(items, raw.search, "search")
  evidence.append_items(items, raw.filters or raw.filtering, "filter")
  evidence.append_items(items, raw.details or raw.detail_views, "details")
  evidence.append_items(items, raw.write_flows or raw.mutations, "write-flow")
  evidence.append_items(items, raw.state_changes, "state-change")
  evidence.append_items(items, raw.edge_cases, "edge-case")
  evidence.append_items(items, raw.negative_paths, "negative-path")

  local features = {}
  for index, item in ipairs(items) do
    local priority, category = classify(item.kind, item.label)
    table.insert(features, {
      id = safe_id(category .. "-" .. item.label .. "-" .. tostring(index), "feature-" .. tostring(index)),
      label = item.label,
      kind = category,
      priority = priority,
      target = item.target,
      visible = item.visible ~= false,
    })
  end
  return features
end

local function add(plan, item)
  table.insert(plan.priorities[item.priority], item)
  table.insert(plan.review_gate.decisions, {
    case_id = item.id,
    priority = item.priority,
    status = item.review_status,
    reason = item.reason,
  })
  local counts = plan.review_gate.counts
  if item.review_status == "not-executed risk" then
    counts.not_executed_risk = counts.not_executed_risk + 1
  else
    counts[item.review_status] = counts[item.review_status] + 1
  end
end

local function plan_case(id, priority, title, category, feature_id, status, reason)
  return {
    id = id,
    priority = priority,
    title = title,
    category = category,
    feature_id = feature_id,
    review_status = status,
    reason = reason,
  }
end

local function add_p0(plan, entry, visible, signals)
  local has_entry = entry.target ~= nil or entry.loaded ~= nil or #visible > 0
  add(plan, plan_case("p0-reachability", "P0", "Reach module entry", "reachability", "entry",
    entry.target ~= nil and "executable" or "blocked",
    entry.target ~= nil and "entry target observed in module evidence" or "entry target missing from module evidence"))
  add(plan, plan_case("p0-page-load", "P0", "Load module page", "page-loading", "entry",
    has_entry and "executable" or "blocked",
    has_entry and "entry load evidence observed" or "page load evidence missing from module evidence"))
  add(plan, plan_case("p0-key-visible-elements", "P0", "Verify key visible elements", "visible-elements", "visible-elements",
    #visible > 0 and "executable" or "blocked",
    #visible > 0 and "visible element evidence observed" or "no visible element evidence observed"))
  add(plan, plan_case("p0-console-health", "P0", "Check console health signals", "console-health", "console",
    signals.console ~= nil and "executable" or "blocked",
    signals.console ~= nil and "console signal observed: " .. signals.console or "console signal missing from module evidence"))
  add(plan, plan_case("p0-network-health", "P0", "Check network health signals", "network-health", "network",
    signals.network ~= nil and "executable" or "blocked",
    signals.network ~= nil and "network signal observed: " .. signals.network or "network signal missing from module evidence"))
end

local function add_p1_p2(plan, features)
  local p1_count = 0
  local seen_p2 = { ["write-flow"] = false, ["state-change"] = false, ["edge-case"] = false, ["negative-path"] = false }
  for _, feature in ipairs(features) do
    if feature.priority == "P1" then
      p1_count = p1_count + 1
      add(plan, plan_case("p1-" .. feature.id, "P1", "Exercise " .. feature.label, feature.kind, feature.id,
        feature.visible and "executable" or "blocked",
        feature.visible and feature.kind .. " interaction observed as low-risk" or "interaction is not visible in evidence"))
    elseif feature.priority == "P2" then
      seen_p2[feature.kind] = true
      local status = (feature.kind == "write-flow" or feature.kind == "state-change") and "blocked" or "not-executed risk"
      local reason = status == "blocked" and "requires mutation policy and safer fixtures before execution"
        or "planned as higher-risk coverage; not executed in this planning slice"
      add(plan, plan_case("p2-" .. feature.id, "P2", "Plan " .. feature.label, feature.kind, feature.id, status, reason))
    end
  end
  if p1_count == 0 then
    add(plan, plan_case("p1-primary-interactions-gap", "P1", "Record primary interaction gap", "interaction-gap", nil,
      "not-executed risk", "no low-risk primary interactions were observed"))
  end
  for _, category in ipairs({ "write-flow", "state-change", "edge-case", "negative-path" }) do
    if not seen_p2[category] then
      add(plan, plan_case("p2-" .. category .. "-gap", "P2", "Record " .. category .. " gap", category, nil,
        "not-executed risk", "no " .. category .. " evidence observed; record as planned coverage gap"))
    end
  end
end

local function inventory(payload, request, raw, root)
  local module = evidence.text(payload.module or (request and request.module), "module")
  local entry = evidence.entry(raw, module)
  local visible = evidence.visible_elements(raw)
  local raw_signals = type(raw.signals) == "table" and raw.signals or {}
  local signals = {
    console = evidence.signal(raw.console or raw.console_health or raw_signals.console),
    network = evidence.signal(raw.network or raw.network_health or raw_signals.network),
  }
  local interaction_features = interactions(raw)
  local features = { { id = "entry", label = entry.label, kind = "entry", priority = "P0", target = entry.target } }
  for index, item in ipairs(visible) do
    table.insert(features, { id = "visible-" .. tostring(index), label = item.label, kind = "visible-element", priority = "P0" })
  end
  if signals.console ~= nil then
    table.insert(features, { id = "console", label = signals.console, kind = "console-health", priority = "P0" })
  end
  if signals.network ~= nil then
    table.insert(features, { id = "network", label = signals.network, kind = "network-health", priority = "P0" })
  end
  for _, item in ipairs(interaction_features) do table.insert(features, item) end
  return {
    schema = "testing-pipeline.feature-inventory.v1",
    module = module,
    artifact_root = root,
    source_ref = request and request.source_ref,
    trace_id = request and request.trace_id,
    dedup_key = request and request.dedup_key,
    entry = entry,
    signals = signals,
    features = features,
    counts = { total = #features, visible_elements = #visible, interactions = #interaction_features },
  }, entry, visible, signals, interaction_features
end

function P.project(payload, request)
  local raw = evidence.from_payload(payload)
  if type(raw) ~= "table" then return nil, nil end
  local root = evidence.artifact_root(payload, request)
  local inv, entry, visible, signals, interaction_features = inventory(payload, request, raw, root)
  local plan = {
    schema = "testing-pipeline.test-plan.v1",
    module = inv.module,
    artifact_root = root,
    source_ref = inv.source_ref,
    trace_id = inv.trace_id,
    dedup_key = inv.dedup_key,
    priorities = { P0 = {}, P1 = {}, P2 = {} },
    review_gate = {
      schema = "testing-pipeline.review-gate.v1",
      counts = { executable = 0, blocked = 0, not_executed_risk = 0 },
      decisions = {},
    },
  }
  add_p0(plan, entry, visible, signals)
  add_p1_p2(plan, interaction_features)
  return P.validate_inventory(inv), P.validate_plan(plan)
end

function P.validate_inventory(inv)
  if type(inv) ~= "table" or inv.schema ~= "testing-pipeline.feature-inventory.v1" then
    error("testing-pipeline: unknown-inventory-schema: expected testing-pipeline.feature-inventory.v1")
  end
  if type(inv.features) ~= "table" or #inv.features == 0 then
    error("testing-pipeline: malformed-inventory: features must be non-empty")
  end
  return inv
end

function P.validate_plan(plan)
  if type(plan) ~= "table" or plan.schema ~= "testing-pipeline.test-plan.v1" then
    error("testing-pipeline: unknown-plan-schema: expected testing-pipeline.test-plan.v1")
  end
  for _, priority in ipairs({ "P0", "P1", "P2" }) do
    local cases = plan.priorities and plan.priorities[priority]
    if not evidence.dense_list(cases) or #cases == 0 then
      error("testing-pipeline: malformed-plan: " .. priority .. " cases must be non-empty")
    end
    for _, item in ipairs(cases) do
      if item.priority ~= priority or not review_statuses[item.review_status] or not evidence.text(item.reason, nil) then
        error("testing-pipeline: malformed-plan: invalid review gate case")
      end
    end
  end
  if type(plan.review_gate) ~= "table" or not evidence.dense_list(plan.review_gate.decisions) then
    error("testing-pipeline: malformed-plan: review_gate decisions must be dense")
  end
  return plan
end

return P
