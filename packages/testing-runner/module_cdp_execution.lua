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
      fixture_lifecycle_path = true,
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
    validate_pointer(fixture.fixture_lifecycle_path, "fixture_lifecycle_path")
    if not bounded_string(fixture.fixture_lifecycle_path, max_string)
      or fixture.fixture_lifecycle_path:sub(1, 14) ~= ".testing/runs/" then
      error("testing-runner: malformed-request: cdp_execution.mutation_fixtures.fixture_lifecycle_path must be a safe artifact pointer")
    end
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

local function action_kind(case)
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
    return module.name or module.visible_label or module.id or "module"
  end
  return module.entry_url or module.id or "module"
end

local function generated_action_descriptors(module, case)
  if case.case_origin ~= "ai-generated" or not dense_list(case.actions) then return nil end
  local out = {}
  for index, item in ipairs(case.actions) do
    if type(item) == "table" and bounded_string(item.action, 80) then
      table.insert(out, {
        index = index,
        action = item.action,
        target = type(item.target) == "table"
          and item.target or strip_url_detail(item.target or module.entry_url or module.id or "module"),
        expected = bounded_string(item.expected, max_string) and item.expected or case.expected_observable,
        evidence_pointer = item.evidence_pointer,
      })
      if type(item.expected) == "table" then out[#out].expected = item.expected end
    end
  end
  return #out > 0 and out or nil
end

local function action_descriptors(module, case)
  local generated = generated_action_descriptors(module, case)
  if generated ~= nil then return generated end
  return {
    {
      action = action_kind(case),
      target = action_target(module, case),
      expected = case.expected_observable,
      evidence_pointer = case.evidence_pointer,
    },
  }
end

local function append_action(actions, artifact_root, module, case, step, descriptor, ui_loop)
  descriptor = descriptor or {}
  local url = strip_url_detail(module.entry_url)
  local target = descriptor.target or action_target(module, case)
  local kind = descriptor.action or action_kind(case)
  if case.case_origin == "ai-generated" and type(target) == "string" and target:match("^https?://") then
    url = strip_url_detail(target)
  end
  local evidence_key = case.id
  if case.case_origin == "ai-generated" and descriptor.index ~= nil then
    evidence_key = tostring(case.id) .. "-" .. tostring(descriptor.index)
  end
  local action = {
    step = step,
    module_id = module.id,
    case_id = case.id,
    priority = case.priority,
    intent = case.title,
    action = kind,
    target = target,
    url = url,
    execution_status = kind == "safe-mutation-fixture" and "blocked" or "planned",
    assertion_status = "not-run",
    observation = "bounded CDP action planned; no browser command or assertion has executed",
    planned_evidence_pointer = artifact_root .. "/evidence/cdp/" .. safe_key(evidence_key) .. ".json",
  }
  if case.case_origin == "ai-generated" then
    action.case_origin = "ai-generated"
    action.provenance_digest = ((case.provenance or {}).model_invocation_digest)
    action.observation = "AI-generated read-only action planned through the FKST bounded action schema"
    if type(descriptor.expected) == "table" then
      action.expected = descriptor.expected
    else
      action.expected_observable = descriptor.expected or case.expected_observable
    end
    local blocked_segment = blocked_route_target(target)
    if blocked_segment ~= nil then
      action.execution_status = "blocked"
      action.observation = "blocked route segment " .. blocked_segment .. " stopped before execution"
    elseif type(target) == "string" and target:match("^https?://") and not within_scope(target, ui_loop or {}) then
      action.execution_status = "blocked"
      action.observation = "generated action target left allowed origin or module scope"
    end
  end
  local gate = case.mutation_gate
  if type(gate) == "table" and gate.classification == "safe-local-test-data" then
    action.execution_status = "planned"
    action.observation = "host-approved fixture mutation is planned through the typed fixture lifecycle"
    action.mutation_kind = gate.mutation_kind
    action.fixture_lifecycle_path = gate.fixture_lifecycle_path
  end
  table.insert(actions, action)
end

local function read_artifact_json(path, opts)
  local reader = opts and opts.artifact_reader
  local body
  if reader ~= nil then
    body = reader(path)
  elseif type(file) == "table" and type(file.read) == "function" then
    body = file.read(path)
  else
    local handle, err = io.open(path, "r")
    if handle == nil then error(err or "testing-runner: ai-artifact-missing") end
    body = handle:read("*a")
    handle:close()
  end
  if type(body) ~= "string" or body == "" then
    error("testing-runner: ai-artifact-missing: artifact body is empty")
  end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    error("testing-runner: ai-artifact-decoder-unavailable: json.decode is required")
  end
  return json.decode(body)
end

local function required_ai_pointer(ai_request, key)
  local value = type(ai_request) == "table" and ai_request[key] or nil
  if not bounded_string(value, max_string) or value:sub(1, 14) ~= ".testing/runs/" then
    error("testing-runner: ai-artifact-missing: " .. key)
  end
  return value
end

local function load_ai_artifacts(request, opts)
  local ai_request = request.ai_generation
  if not module_ai_generation.enabled(ai_request) then return nil end
  local context_path = required_ai_pointer(ai_request, "context_manifest_path")
  local generated_path = required_ai_pointer(ai_request, "generated_cases_path")
  local gate_path = required_ai_pointer(ai_request, "generated_case_gate_path")
  local generation_review_path = required_ai_pointer(ai_request, "ai_agent_generation_path")
  local execution_review_path = required_ai_pointer(ai_request, "generated_case_agent_review_path")
  local closure_path = required_ai_pointer(ai_request, "ai_test_design_loop_path")

  local context = read_artifact_json(context_path, opts)
  local generated = module_ai_generation.validate_generated_cases(read_artifact_json(generated_path, opts))
  local gate = read_artifact_json(gate_path, opts)
  local generation_review = module_ai_generation.validate_agent_generation(read_artifact_json(generation_review_path, opts))
  local execution_review = module_ai_generation.validate_agent_review(read_artifact_json(execution_review_path, opts))
  local closure = read_artifact_json(closure_path, opts)

  if type(context) ~= "table" or context.schema ~= module_ai_generation.context_schema then error("testing-runner: ai-artifact-corrupt: context") end
  if type(gate) ~= "table" or gate.schema ~= module_ai_generation.gate_schema then error("testing-runner: ai-artifact-corrupt: gate") end
  if type(closure) ~= "table" or closure.schema ~= module_ai_generation.review_closure_schema then error("testing-runner: ai-artifact-corrupt: closure") end
  if context.context_manifest_path ~= context_path
    or generated.context_manifest_path ~= context_path
    or generated.generated_cases_path ~= generated_path
    or gate.context_manifest_path ~= context_path
    or gate.generated_cases_path ~= generated_path
    or gate.generated_case_gate_path ~= gate_path
    or generation_review.context_manifest_path ~= context_path
    or generation_review.generated_cases_path ~= generated_path
    or execution_review.context_manifest_path ~= context_path
    or execution_review.generated_cases_path ~= generated_path
    or execution_review.generated_case_gate_path ~= gate_path
    or closure.context_manifest_path ~= context_path
    or closure.generated_cases_path ~= generated_path
    or closure.generated_case_gate_path ~= gate_path then
    error("testing-runner: ai-artifact-mismatch: pointer binding")
  end
  if gate.generation_digest ~= generated.generation_digest
    or generation_review.candidate_generation_digest ~= generated.generation_digest
    or execution_review.candidate_generation_digest ~= generated.generation_digest
    or execution_review.gate_digest ~= gate.gate_digest
    or closure.generation_digest ~= generated.generation_digest
    or closure.gate_digest ~= gate.gate_digest then
    error("testing-runner: ai-artifact-mismatch: digest binding")
  end
  if generation_review.status ~= "approved" or execution_review.status ~= "approved" or closure.status ~= "reviewed" then
    error("testing-runner: ai-artifact-blocked: adversarial review did not approve execution")
  end
  return {
    context = context,
    generated_cases = generated,
    gate = gate,
    agent_generation = generation_review,
    agent_review = execution_review,
    closure = closure,
  }
end

local function planning_for(payload, artifact_root, readiness, request, ai_artifacts)
  if payload.module_discovery == nil then return nil, nil end
  local inventory = module_inventory.inventory(payload.module_discovery, payload.ui_loop, artifact_root, {
    readiness = readiness,
  })
  return inventory, module_planning.build(inventory, payload.ui_loop, artifact_root, {
    mutation_fixtures = (request or {}).mutation_fixtures,
    ai_generation = (request or {}).ai_generation,
    ai_agent_generation = ai_artifacts and ai_artifacts.agent_generation or nil,
    generated_cases = ai_artifacts and ai_artifacts.generated_cases or nil,
    generated_case_gate = ai_artifacts and ai_artifacts.gate or nil,
    generated_case_agent_review = ai_artifacts and ai_artifacts.agent_review or nil,
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
    planned_action_count = 0,
    blocked_action_count = 0,
    executed_action_count = 0,
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

  local ai_artifacts
  if module_ai_generation.enabled(request.ai_generation) then
    local ok, loaded = pcall(load_ai_artifacts, request, opts)
    if not ok then
      return blocked_artifact(payload, artifact_root, request, "ai-artifact-invalid", tostring(loaded):sub(1, max_string), readiness)
    end
    ai_artifacts = loaded
  end

  local inventory, planning = planning_for(payload, artifact_root, readiness, request, ai_artifacts)
  if planning == nil then
    return blocked_artifact(payload, artifact_root, request, "missing-test-plan", "requires module discovery test plan for bounded selected execution", readiness)
  end

  local priorities, priority_set = selected_priorities(request)
  local budget = request.step_budget or 8
  local actions = {}
  local selected_case_count = 0
  local selected_action_count = 0
  local boundary_violation = false

  for _, module in ipairs(planning.test_plan.modules or {}) do
    if not within_scope(module.entry_url, payload.ui_loop or {}) then
      boundary_violation = true
      break
    end
    for _, case in ipairs(module.cases or {}) do
      if priority_set[case.priority] and case.review_status == "executable" then
        selected_case_count = selected_case_count + 1
        for _, descriptor in ipairs(action_descriptors(module, case)) do
          selected_action_count = selected_action_count + 1
          if #actions < budget then
            append_action(actions, artifact_root, module, case, #actions + 1, descriptor, payload.ui_loop or {})
          end
        end
      end
    end
  end

  if boundary_violation then
    local artifact = blocked_artifact(payload, artifact_root, request, "module-boundary-violation", "planned module entry URL left allowed origin or module scope", readiness)
    artifact.inventory_path = artifact_root .. "/module-inventory.json"
    artifact.feature_inventory_path = artifact_root .. "/feature-inventory.json"
    artifact.test_plan_path = artifact_root .. "/test-plan.json"
    return artifact, planning
  end

  local planned_action_count = 0
  local blocked_action_count = 0
  for _, action in ipairs(actions) do
    if action.execution_status == "blocked" then
      blocked_action_count = blocked_action_count + 1
    else
      planned_action_count = planned_action_count + 1
    end
  end

  local status, classification = "planned", "bounded-exploration-planned"
  local limitations = { "actions are planning records until a validated browser execution receipt is attached" }
  if selected_action_count == 0 then
    status = "degraded"
    classification = "no-executable-safe-cases"
    limitations = { "no executable selected cases were available for bounded CDP planning" }
  elseif selected_action_count > budget then
    status = "degraded"
    classification = "step-budget-exhausted"
    limitations = { "step budget stopped planning before all executable selected cases were recorded" }
  elseif blocked_action_count == #actions and blocked_action_count > 0 then
    status = "degraded"
    classification = "mutation-execution-not-supported"
    limitations = { "selected mutation cases remain blocked because no mutation executor is implemented" }
  elseif blocked_action_count > 0 then
    status = "degraded"
    classification = "planned-with-blocked-actions"
    limitations = { "read-only actions are planned and mutation or unsafe-route actions remain blocked" }
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
    ai_agent_generation_path = planning.ai_agent_generation and (planning.ai_context and planning.ai_context.ai_agent_generation_path or nil) or nil,
    generated_case_agent_review_path = planning.generated_case_agent_review and (planning.ai_context and planning.ai_context.generated_case_agent_review_path or nil) or nil,
    ai_generation = planning.test_plan.ai_generation,
    base_url = strip_url_detail(payload.ui_loop.base_url),
    allowed_origins = payload.ui_loop.allowed_origins,
    cdp_readiness_ref = payload.ui_loop.cdp_readiness_ref,
    step_budget = budget,
    case_priorities = priorities,
    stop_conditions = stop_conditions(request),
    planned_case_count = selected_case_count,
    action_count = #actions,
    planned_action_count = planned_action_count,
    blocked_action_count = blocked_action_count,
    executed_action_count = 0,
    actions = actions,
    coverage = inventory.coverage,
    readiness = readiness,
    limitations = limitations,
  }, planning
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
    planned_action_count = artifact.planned_action_count or 0,
    blocked_action_count = artifact.blocked_action_count or 0,
    executed_action_count = artifact.executed_action_count or 0,
    failed_action_count = artifact.failed_action_count or 0,
  }
  if artifact.test_plan_path ~= nil then summary.test_plan_path = artifact.test_plan_path end
  if artifact.ai_context_manifest_path ~= nil then summary.ai_context_manifest_path = artifact.ai_context_manifest_path end
  if artifact.generated_cases_path ~= nil then summary.generated_cases_path = artifact.generated_cases_path end
  if artifact.generated_case_gate_path ~= nil then summary.generated_case_gate_path = artifact.generated_case_gate_path end
  if artifact.ai_agent_generation_path ~= nil then summary.ai_agent_generation_path = artifact.ai_agent_generation_path end
  if artifact.generated_case_agent_review_path ~= nil then summary.generated_case_agent_review_path = artifact.generated_case_agent_review_path end
  if artifact.ai_generation ~= nil then summary.ai_generation = artifact.ai_generation end
  if artifact.cdp_readiness_ref ~= nil then summary.cdp_readiness_ref = artifact.cdp_readiness_ref end
  return summary
end

return M
