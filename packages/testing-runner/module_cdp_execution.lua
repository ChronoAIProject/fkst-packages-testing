local M = {}

local module_ai_generation = require("module_ai_generation")
local module_inventory = require("module_inventory")
local module_planning = require("module_planning")

M.request_schema = "testing-runner.module-cdp-execution.v1"
M.artifact_schema = "testing-runner.module-cdp-execution-result.v1"
M.summary_schema = "testing-runner.module-cdp-execution-summary.v1"

local max_string = 512
local max_list = 16
local max_steps = 32

local request_fields = {
  schema = true,
  step_budget = true,
  case_priorities = true,
  stop_conditions = true,
  mutation_fixtures = true,
  ai_generation = true,
  generated_cases = true,
}

local default_priorities = { "P0", "P1" }
local default_stop_conditions = {
  "origin-boundary",
  "module-boundary",
  "credential-login",
  "mfa",
  "captcha",
  "admin-destructive-billing",
  "external-notification",
  "unknown-generated-action",
  "fixture-evidence",
  "mutation-policy",
  "step-budget",
}

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

local function bounded_string(value, limit)
  return type(value) == "string" and value ~= "" and #value <= (limit or max_string) and value:find("[%z\1-\31]") == nil
end

local function dense_list(value)
  if type(value) ~= "table" then return false end
  local length = #value
  for index, _ in pairs(value) do
    if type(index) ~= "number" or index < 1 or math.floor(index) ~= index or index > length then
      return false
    end
  end
  for index = 1, length do
    if value[index] == nil then return false end
  end
  return true
end

local function strip_url_detail(url)
  if type(url) ~= "string" then return nil end
  local text = url:gsub("[#?].*$", "")
  if #text > max_string then text = text:sub(1, max_string) end
  return text
end

local blocked_route_segments = {
  admin = true,
  auth = true,
  billing = true,
  delete = true,
  login = true,
  logout = true,
  oauth = true,
  permissions = true,
  remove = true,
}

local function blocked_route_target(value)
  local text = tostring(value or ""):lower()
  for segment in text:gmatch("[^/%s]+") do
    if blocked_route_segments[segment] == true then return segment end
  end
  return nil
end

local function origin_of(url)
  local text = type(url) == "string" and url or ""
  return text:match("^(https?://[^/?#]+)")
end

local function path_of(url)
  if type(url) ~= "string" then return "/" end
  return url:match("^https?://[^/?#]+([^?#]*)") or "/"
end

local function scope_prefix(base_url)
  local path = path_of(base_url)
  if path == "" then return "/" end
  if path:sub(-1) ~= "/" then path = path .. "/" end
  return path
end

local function within_scope(url, ui_loop)
  local origin = origin_of(url)
  if origin == nil or not dense_list(ui_loop.allowed_origins) then return false end
  local allowed = false
  for _, item in ipairs(ui_loop.allowed_origins) do
    if item == origin then
      allowed = true
      break
    end
  end
  if not allowed then return false end
  local base_origin = origin_of(ui_loop.base_url)
  if origin ~= base_origin then return false end
  local path = path_of(url)
  local prefix = scope_prefix(ui_loop.base_url)
  if prefix == "/" then return true end
  return path == prefix:sub(1, -2) or path:sub(1, #prefix) == prefix
end

local function safe_key(value)
  local text = tostring(value or "step")
  text = text:gsub("[^%w%._%-]", "-")
  text = text:gsub("%.+", ".")
  text = text:gsub("^%.", "")
  if text == "" then text = "step" end
  if #text > 120 then text = text:sub(1, 120) end
  return text
end

local function copy_list(value, fallback, validate)
  if value == nil then
    local copy = {}
    for _, item in ipairs(fallback) do table.insert(copy, item) end
    return copy
  end
  if not dense_list(value) or #value == 0 or #value > max_list then
    error("testing-runner: malformed-request: cdp_execution list fields must be bounded dense lists")
  end
  local copy = {}
  for _, item in ipairs(value) do
    if not bounded_string(item, 80) or not validate(item) then
      error("testing-runner: malformed-request: cdp_execution list item is unsupported")
    end
    table.insert(copy, item)
  end
  return copy
end

local function priority_ok(value)
  return value == "P0" or value == "P1" or value == "P2"
end

local function stop_condition_ok(value)
  return bounded_string(value, 80)
end

local function validate_pointer(value, field)
  if value ~= nil and not bounded_string(value, max_string) then
    error("testing-runner: malformed-request: cdp_execution.mutation_fixtures." .. field .. " must be a bounded pointer")
  end
end

local function validate_mutation_fixtures(value)
  if value == nil then return end
  if not dense_list(value) or #value == 0 or #value > max_list then
    error("testing-runner: malformed-request: cdp_execution.mutation_fixtures must be a non-empty bounded dense list")
  end
  for _, fixture in ipairs(value) do
    if type(fixture) ~= "table" then
      error("testing-runner: malformed-request: cdp_execution.mutation_fixtures items must be tables")
    end
    local fields = {
      case_id = true,
      mutation_kind = true,
      fixture_ref = true,
      cleanup_ref = true,
      rollback_ref = true,
      evidence_pointer = true,
    }
    for key, _ in pairs(fixture) do
      if fields[key] ~= true then
        error("testing-runner: malformed-request: cdp_execution.mutation_fixtures contains unsupported field")
      end
    end
    if not bounded_string(fixture.case_id, 180) then
      error("testing-runner: malformed-request: cdp_execution.mutation_fixtures.case_id is required")
    end
    if not bounded_string(fixture.mutation_kind, 80) then
      error("testing-runner: malformed-request: cdp_execution.mutation_fixtures.mutation_kind is required")
    end
    if not safe_mutation_kinds[fixture.mutation_kind] and not blocked_mutation_kinds[fixture.mutation_kind] then
      error("testing-runner: malformed-request: cdp_execution.mutation_fixtures.mutation_kind is unsupported")
    end
    validate_pointer(fixture.fixture_ref, "fixture_ref")
    validate_pointer(fixture.cleanup_ref, "cleanup_ref")
    validate_pointer(fixture.rollback_ref, "rollback_ref")
    validate_pointer(fixture.evidence_pointer, "evidence_pointer")
  end
end

function M.validate_request(value)
  if value == nil then return nil end
  if type(value) ~= "table" then
    error("testing-runner: malformed-request: cdp_execution must be a table")
  end
  for key, _ in pairs(value) do
    if request_fields[key] ~= true then
      error("testing-runner: malformed-request: cdp_execution contains unsupported field")
    end
  end
  if value.schema ~= M.request_schema then
    error("testing-runner: unknown-schema: expected " .. M.request_schema)
  end
  if value.step_budget ~= nil then
    if type(value.step_budget) ~= "number" or value.step_budget < 1 or value.step_budget > max_steps or math.floor(value.step_budget) ~= value.step_budget then
      error("testing-runner: malformed-request: cdp_execution.step_budget must be an integer from 1 to 32")
    end
  end
  copy_list(value.case_priorities, default_priorities, priority_ok)
  copy_list(value.stop_conditions, default_stop_conditions, stop_condition_ok)
  validate_mutation_fixtures(value.mutation_fixtures)
  module_ai_generation.validate_request(value.ai_generation)
  if value.generated_cases ~= nil then
    module_ai_generation.validate_generated_cases(value.generated_cases)
  end
  return value
end

local function has_ready_session(preflight)
  if type(preflight) ~= "table" or preflight.status ~= "ready" then return false end
  if not dense_list(preflight.sessions) then return false end
  for _, session in ipairs(preflight.sessions) do
    if type(session) == "table" and session.status == "ready" and session.role ~= "base_url" then
      return true
    end
  end
  return false
end

local function selected_priorities(request)
  local priorities = copy_list((request or {}).case_priorities, default_priorities, priority_ok)
  local set = {}
  for _, priority in ipairs(priorities) do set[priority] = true end
  return priorities, set
end

local function stop_conditions(request)
  return copy_list((request or {}).stop_conditions, default_stop_conditions, stop_condition_ok)
end

local function generated_action_kind(case)
  if case.case_origin ~= "ai-generated" or type(case.actions) ~= "table" or type(case.actions[1]) ~= "table" then return nil end
  return case.actions[1].action
end

local function action_kind(case)
  local generated = generated_action_kind(case)
  if generated ~= nil then return generated end
  local id = tostring(case.id or "")
  if id:find("reachability", 1, true) then return "navigate" end
  if id:find("page-load", 1, true) then return "wait-for-load" end
  if id:find("visible-elements", 1, true) then return "inspect-visible-elements" end
  if id:find("console-network-health", 1, true) then return "collect-console-network-health" end
  if id:find("navigation", 1, true) then return "bounded-navigation" end
  if id:find("write-flow", 1, true) or id:find("state-change", 1, true) then return "safe-mutation-fixture"
  end
  return "observe"
end

local function action_target(module, case)
  local kind = action_kind(case)
  if case.case_origin == "ai-generated" and type(case.actions) == "table" and type(case.actions[1]) == "table" then
    return case.actions[1].target or module.entry_url or module.id or "module"
  end
  if kind == "inspect-visible-elements" then
    return module.name or module.id or "module"
  end
  if kind == "collect-console-network-health" then
    return "console-network-health"
  end
  if kind == "safe-mutation-fixture" then
    return ((case.mutation_gate or {}).fixture_ref) or module.entry_url or module.id or "module"
  end
  return module.entry_url or module.id or "module"
end

local function append_action(actions, artifact_root, module, case, step)
  local url = strip_url_detail(module.entry_url)
  local target = action_target(module, case)
  local action = {
    step = step,
    module_id = module.id,
    case_id = case.id,
    priority = case.priority,
    intent = case.title,
    action = action_kind(case),
    target = target,
    url = url,
    observation = "bounded CDP step recorded without credential, MFA, CAPTCHA, or unsafe mutation handling",
    evidence_pointer = artifact_root .. "/evidence/cdp/" .. safe_key(case.id) .. ".json",
  }
  if case.case_origin == "ai-generated" then
    action.case_origin = "ai-generated"
    action.provenance_digest = ((case.provenance or {}).model_invocation_digest)
    action.observation = "AI-generated read-only case executed through FKST bounded action schema"
    action.expected_observable = case.expected_observable
    local blocked_segment = blocked_route_target(target)
    if blocked_segment ~= nil then
      action.observation = "blocked route segment " .. blocked_segment .. " stopped before execution"
    end
  end
  local gate = case.mutation_gate
  if type(gate) == "table" and gate.classification == "safe-local-test-data" then
    action.observation = "safe local test-data mutation recorded with host fixture and cleanup or rollback evidence"
    action.mutation_kind = gate.mutation_kind
    action.fixture_ref = gate.fixture_ref
    action.cleanup_ref = gate.cleanup_ref
    action.rollback_ref = gate.rollback_ref
    action.fixture_evidence_pointer = gate.evidence_pointer
  end
  table.insert(actions, action)
end

local function planning_for(payload, artifact_root, readiness, request)
  if payload.module_discovery == nil then return nil, nil end
  local inventory = module_inventory.inventory(payload.module_discovery, payload.ui_loop, artifact_root, {
    readiness = readiness,
  })
  return inventory, module_planning.build(inventory, payload.ui_loop, artifact_root, {
    mutation_fixtures = (request or {}).mutation_fixtures,
    ai_generation = (request or {}).ai_generation,
    generated_cases = (request or {}).generated_cases,
    step_budget = (request or {}).step_budget,
    case_priorities = (request or {}).case_priorities,
  })
end

local function blocked_artifact(payload, artifact_root, request, classification, reason, readiness)
  return {
    schema = M.artifact_schema,
    artifact_kind = "module-cdp-execution",
    module = payload.module,
    execution_status = "blocked",
    classification = classification,
    mode = "bounded-cdp-controller",
    artifact_root = artifact_root,
    execution_path = artifact_root .. "/cdp-execution.json",
    metadata_path = artifact_root .. "/metadata.json",
    base_url = strip_url_detail((payload.ui_loop or {}).base_url),
    allowed_origins = (payload.ui_loop or {}).allowed_origins,
    cdp_readiness_ref = (payload.ui_loop or {}).cdp_readiness_ref,
    step_budget = request.step_budget or 8,
    case_priorities = copy_list(request.case_priorities, default_priorities, priority_ok),
    stop_conditions = stop_conditions(request),
    action_count = 0,
    actions = {},
    readiness = readiness,
    limitations = { reason },
  }
end

function M.build(payload, artifact_root, opts)
  opts = opts or {}
  local request = M.validate_request(payload.cdp_execution or { schema = M.request_schema })
  local readiness = opts.readiness
  if not has_ready_session(payload.preflight_result) or not bounded_string((payload.ui_loop or {}).cdp_readiness_ref, max_string) then
    return blocked_artifact(payload, artifact_root, request, "missing-cdp-session", "requires ready reused local CDP/browser session", readiness)
  end

  local inventory, planning = planning_for(payload, artifact_root, readiness, request)
  if planning == nil then
    return blocked_artifact(payload, artifact_root, request, "missing-test-plan", "requires module discovery test plan for bounded selected execution", readiness)
  end

  local priorities, priority_set = selected_priorities(request)
  local budget = request.step_budget or 8
  local actions = {}
  local selected_count = 0
  local boundary_violation = false

  for _, module in ipairs(planning.test_plan.modules or {}) do
    if not within_scope(module.entry_url, payload.ui_loop or {}) then
      boundary_violation = true
      break
    end
    for _, case in ipairs(module.cases or {}) do
      if priority_set[case.priority] and case.review_status == "executable" then
        selected_count = selected_count + 1
        if #actions < budget then
          append_action(actions, artifact_root, module, case, #actions + 1)
        end
      end
    end
  end

  if boundary_violation then
    local artifact = blocked_artifact(payload, artifact_root, request, "module-boundary-violation", "planned module entry URL left allowed origin or module scope", readiness)
    artifact.inventory_path = artifact_root .. "/module-inventory.json"
    artifact.feature_inventory_path = artifact_root .. "/feature-inventory.json"
    artifact.test_plan_path = artifact_root .. "/test-plan.json"
    return artifact
  end

  local status, classification = "passed", "bounded-exploration-complete"
  local limitations = {}
  if selected_count == 0 then
    status = "degraded"
    classification = "no-executable-safe-cases"
    limitations = { "no executable selected cases were available for bounded CDP execution" }
  elseif selected_count > budget then
    status = "degraded"
    classification = "step-budget-exhausted"
    limitations = { "step budget stopped exploration before all executable selected cases ran" }
  end

  return {
    schema = M.artifact_schema,
    artifact_kind = "module-cdp-execution",
    module = payload.module,
    execution_status = status,
    classification = classification,
    mode = "bounded-cdp-controller",
    artifact_root = artifact_root,
    execution_path = artifact_root .. "/cdp-execution.json",
    metadata_path = artifact_root .. "/metadata.json",
    inventory_path = artifact_root .. "/module-inventory.json",
    feature_inventory_path = artifact_root .. "/feature-inventory.json",
    test_plan_path = artifact_root .. "/test-plan.json",
    ai_context_manifest_path = planning.ai_context and planning.ai_context.context_manifest_path or nil,
    generated_cases_path = planning.generated_cases and planning.generated_cases.generated_cases_path or (planning.ai_context and planning.ai_context.generated_cases_path or nil),
    generated_case_gate_path = planning.generated_case_gate and planning.generated_case_gate.generated_case_gate_path or (planning.ai_context and planning.ai_context.generated_case_gate_path or nil),
    ai_generation = planning.test_plan.ai_generation,
    base_url = strip_url_detail(payload.ui_loop.base_url),
    allowed_origins = payload.ui_loop.allowed_origins,
    cdp_readiness_ref = payload.ui_loop.cdp_readiness_ref,
    step_budget = budget,
    case_priorities = priorities,
    stop_conditions = stop_conditions(request),
    planned_case_count = selected_count,
    action_count = #actions,
    actions = actions,
    coverage = inventory.coverage,
    readiness = readiness,
    limitations = limitations,
  }
end

function M.summary(artifact, module, status)
  local summary = {
    schema = M.summary_schema,
    module = module,
    status = status,
    execution_status = artifact.execution_status,
    classification = artifact.classification,
    mode = artifact.mode,
    artifact_root = artifact.artifact_root,
    execution_path = artifact.execution_path,
    metadata_path = artifact.metadata_path,
    action_count = artifact.action_count,
  }
  if artifact.test_plan_path ~= nil then summary.test_plan_path = artifact.test_plan_path end
  if artifact.ai_context_manifest_path ~= nil then summary.ai_context_manifest_path = artifact.ai_context_manifest_path end
  if artifact.generated_cases_path ~= nil then summary.generated_cases_path = artifact.generated_cases_path end
  if artifact.generated_case_gate_path ~= nil then summary.generated_case_gate_path = artifact.generated_case_gate_path end
  if artifact.ai_generation ~= nil then summary.ai_generation = artifact.ai_generation end
  if artifact.cdp_readiness_ref ~= nil then summary.cdp_readiness_ref = artifact.cdp_readiness_ref end
  return summary
end

return M
