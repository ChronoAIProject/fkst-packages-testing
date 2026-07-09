local M = {}

local strings = require("contract.strings")
local workflow_codex = require("workflow.codex")
local ai_agents = require("module_ai_agents")

M.request_schema = "testing-runner.ai-case-generation.request.v1"
M.context_schema = "testing-runner.ai-context-manifest.v1"
M.generated_cases_schema = "testing-runner.generated-test-cases.v1"
M.gate_schema = "testing-runner.generated-case-gate.v1"
M.agent_generation_schema = ai_agents.agent_generation_schema
M.agent_review_schema = ai_agents.agent_review_schema
M.review_closure_schema = "testing-runner.ai-test-design-loop.v1"
M.prompt_template_ref = "testing-runner.ai-case-generation.prompt.v1"

local max_string = 512
local max_id = 180
local max_modules = 64
local max_cases = 32
local max_actions = 8
local max_follow_ups = 16

local allowed_modes = {
  disabled = true,
  draft = true,
  ["autonomous-reviewed"] = true,
}

local allowed_priorities = {
  P0 = true,
  P1 = true,
  P2 = true,
}

local allowed_case_kinds = {
  ["entry-health"] = true,
  ["primary-interaction"] = true,
  ["read-only-interaction"] = true,
  ["module-transition"] = true,
  ["mutation-or-edge"] = true,
}

local allowed_action_kinds = {
  navigate = true,
  ["wait-for-load"] = true,
  ["inspect-visible-elements"] = true,
  ["collect-console-network-health"] = true,
  ["bounded-navigation"] = true,
  ["open-visible-surface"] = true,
  ["close-visible-surface"] = true,
  ["search-or-filter-readonly"] = true,
  ["clear-filter-readonly"] = true,
  ["module-transition"] = true,
  ["safe-mutation-fixture"] = true,
}

local generated_case_fields = {
  actions = true,
  case_kind = true,
  case_origin = true,
  expected_observable = true,
  evidence_pointer = true,
  evidence_pointers = true,
  flow_id = true,
  id = true,
  module_id = true,
  objective = true,
  priority = true,
  provenance = true,
  reason = true,
  review_status = true,
  title = true,
}

local generated_payload_fields = {
  artifact_kind = true,
  artifact_root = true,
  case_count = true,
  cases = true,
  context_manifest_path = true,
  generation_digest = true,
  generation_mode = true,
  prompt_template_ref = true,
  generated_cases_path = true,
  schema = true,
}

local request_fields = {
  allowed_action_kinds = true,
  allowed_case_kinds = true,
  case_budget = true,
  consensus_angles = true,
  context_manifest_path = true,
  dedup_key = true,
  generated_cases_path = true,
  mode = true,
  schema = true,
  source_ref = true,
  trace_id = true,
}

local action_fields = {
  action = true,
  evidence_pointer = true,
  expected = true,
  target = true,
  target_module_id = true,
}

local provenance_fields = {
  agent_generation_path = true,
  agent_review_path = true,
  context_manifest_path = true,
  model_invocation_digest = true,
  origin = true,
  prompt_template_ref = true,
}

local forbidden_terms = {
  "raw_dom",
  "screenshot_body",
  "model_transcript",
  "browser_" .. "storage",
  "local" .. "storage",
  "session" .. "storage",
  "coo" .. "kie",
  "to" .. "ken",
  "pass" .. "word",
  "credential",
  "raw_prompt",
  "raw_response",
  "raw_report",
}

local blocked_route_terms = {
  "admin",
  "auth",
  "billing",
  "delete",
  "login",
  "logout",
  "oauth",
  "permissions",
  "remove",
}

local function bounded_string(value, limit)
  if type(value) ~= "string" or value == "" then return false end
  if #value > (limit or max_string) then return false end
  return value:find("[%z\1-\31]") == nil
end

local function dense_list(value)
  if type(value) ~= "table" then return false, 0 end
  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" then return false, 0 end
    if key < 1 or math.floor(key) ~= key then return false, 0 end
    count = count + 1
  end
  return count == #value, count
end

local function validate_fields(value, allowed, context)
  local prefix = context or "testing-runner: malformed-ai-payload"
  for key, _ in pairs(value or {}) do
    if allowed[key] ~= true then error(prefix .. ": unsupported field") end
  end
end

local function bounded_id(value)
  return bounded_string(value, max_id)
end

local function strip_url_detail(value)
  local text = tostring(value or ""):gsub("[#?].*$", "")
  if #text > max_string then text = text:sub(1, max_string) end
  return text
end

local function origin_from_url(value)
  if not bounded_string(value, max_string) then return nil end
  local scheme, authority = value:match("^(https?)://([^/%?#]+)")
  if scheme == nil then return nil end
  if authority == nil or authority == "" then return nil end
  if authority:find("%s") ~= nil then return nil end
  if authority:find("\\", 1, true) ~= nil then return nil end
  if authority:find("@", 1, true) ~= nil then return nil end
  return scheme:lower() .. "://" .. authority:lower()
end

local function local_http_url(value)
  local authority = tostring(value or ""):match("^http://([^/%?#]+)")
  if authority == nil then return false end
  local bracketed = authority:match("^%[([^%]]+)%]")
  local host = bracketed ~= nil and bracketed or (authority:match("^([^:]+)") or authority)
  local normalized = host:lower()
  if normalized == "localhost" then return true end
  if normalized == "127.0.0.1" then return true end
  return normalized == "::1"
end

local function safe_artifact_pointer(value)
  return bounded_string(value, max_string)
    and strings.is_path_safe_key(value, max_string)
    and value:sub(1, 14) == ".testing/runs/"
end

local function copy_string_list(value, fallback, allowed, context, max_items)
  local source = value or fallback or {}
  local ok, count = dense_list(source)
  if not ok or count > (max_items or max_actions) then error(context .. " must be a bounded dense list") end
  local out = {}
  for _, item in ipairs(source) do
    if not bounded_string(item, max_string) or (allowed ~= nil and allowed[item] ~= true) then
      error(context .. " contains unsupported item")
    end
    table.insert(out, item)
  end
  return out
end

local function set_from_list(value)
  local set = {}
  for _, item in ipairs(value or {}) do set[item] = true end
  return set
end

local function contains_forbidden(value)
  local kind = type(value)
  if kind == "string" then
    local text = value:lower()
    for _, term in ipairs(forbidden_terms) do
      if text:find(term, 1, true) ~= nil then return term end
    end
  elseif kind == "table" then
    for key, item in pairs(value) do
      local bad = contains_forbidden(key)
      if bad ~= nil then return bad end
      bad = contains_forbidden(item)
      if bad ~= nil then return bad end
    end
  end
  return nil
end
M.contains_forbidden = contains_forbidden

local function module_label(module)
  return module.name or module.visible_label or module.route or module.id or "module"
end

local function sanitize_module(module)
  local feature_signals = {}
  for _, signal in ipairs(module.feature_signals or {}) do
    if bounded_string(signal, 80) then table.insert(feature_signals, signal) end
    if #feature_signals >= 8 then break end
  end
  return {
    id = bounded_id(module.id) and module.id or strings.sanitize_key(module_label(module), max_id),
    name = bounded_string(module_label(module), max_string) and module_label(module) or "Module",
    entry_url = strip_url_detail(module.entry_url),
    route = bounded_string(module.route, max_string) and strip_url_detail(module.route) or nil,
    visible_label = bounded_string(module.visible_label, max_string) and module.visible_label or nil,
    discovery_source = bounded_string(module.discovery_source, 80) and module.discovery_source or nil,
    confidence = bounded_string(module.confidence, 80) and module.confidence or nil,
    evidence_pointer = safe_artifact_pointer(module.evidence_pointer) and module.evidence_pointer or nil,
    feature_signals = feature_signals,
  }
end

local function module_has_signal(module, signal)
  for _, item in ipairs(module.feature_signals or {}) do
    if item == signal then return true end
  end
  return false
end

local function allowed_origin_map(origins)
  local map = {}
  for _, origin in ipairs(origins or {}) do
    map[origin] = true
  end
  return map
end

local function blocked_route_target(value)
  local text = tostring(value or ""):lower():gsub("[^%w]+", "/")
  for segment in text:gmatch("[^/]+") do
    for _, term in ipairs(blocked_route_terms) do
      if segment == term then return term end
    end
  end
  return nil
end

local function target_within_scope(target, context)
  if blocked_route_target(target) ~= nil then return false end
  if type(target) ~= "string" or target:match("^https?://") == nil then return true end
  local clean = strip_url_detail(target)
  local origin = origin_from_url(clean)
  return origin ~= nil and allowed_origin_map(context.allowed_origins)[origin] == true and local_http_url(clean)
end

local function default_request(value)
  if value ~= nil then return value end
  return { schema = M.request_schema, mode = "disabled" }
end

function M.validate_request(value)
  if value == nil then return nil end
  if type(value) ~= "table" then error("testing-runner: malformed-request: ai_generation must be a table") end
  validate_fields(value, request_fields, "testing-runner: malformed-request: ai_generation")
  if value.schema ~= M.request_schema then error("testing-runner: unknown-schema: expected " .. M.request_schema) end
  local mode = value.mode or "disabled"
  if allowed_modes[mode] ~= true then error("testing-runner: malformed-request: ai_generation.mode is invalid") end
  if value.case_budget ~= nil then
    if type(value.case_budget) ~= "number" or value.case_budget < 0 or value.case_budget > max_cases or math.floor(value.case_budget) ~= value.case_budget then
      error("testing-runner: malformed-request: ai_generation.case_budget must be an integer from 0 to 32")
    end
  end
  copy_string_list(value.allowed_case_kinds, nil, allowed_case_kinds, "testing-runner: malformed-request: ai_generation.allowed_case_kinds", max_actions)
  copy_string_list(value.allowed_action_kinds, nil, allowed_action_kinds, "testing-runner: malformed-request: ai_generation.allowed_action_kinds", max_actions)
  copy_string_list(value.consensus_angles, nil, nil, "testing-runner: malformed-request: ai_generation.consensus_angles", 4)
  if value.context_manifest_path ~= nil and not safe_artifact_pointer(value.context_manifest_path) then
    error("testing-runner: malformed-request: ai_generation.context_manifest_path must be a safe artifact pointer")
  end
  if value.generated_cases_path ~= nil and not safe_artifact_pointer(value.generated_cases_path) then
    error("testing-runner: malformed-request: ai_generation.generated_cases_path must be a safe artifact pointer")
  end
  if contains_forbidden(value) ~= nil then error("testing-runner: malformed-request: ai_generation contains forbidden payload term") end
  return value
end

function M.enabled(request)
  request = default_request(request)
  M.validate_request(request)
  return (request.mode or "disabled") ~= "disabled"
end

local function context_paths(artifact_root)
  return {
    context = artifact_root .. "/ai-context-manifest.json",
    generated = artifact_root .. "/generated-test-cases.json",
    gate = artifact_root .. "/generated-case-gate.json",
    agent_generation = artifact_root .. "/ai-agent-generation.json",
    agent_review = artifact_root .. "/generated-case-agent-review.json",
    review_closure = artifact_root .. "/ai-test-design-loop.json",
  }
end

function M.build_context(inventory, ui_loop, artifact_root, opts)
  opts = opts or {}
  local request = default_request(opts.ai_generation)
  M.validate_request(request)
  if not strings.is_artifact_root(artifact_root) then error("testing-runner: malformed-ai-context: artifact_root must be safe") end
  local paths = context_paths(artifact_root)
  local modules = {}
  for _, module in ipairs((inventory or {}).modules or {}) do
    local item = sanitize_module(module)
    if bounded_id(item.id) and bounded_string(item.entry_url, max_string) and local_http_url(item.entry_url) then
      table.insert(modules, item)
    end
    if #modules >= max_modules then break end
  end
  local base_url = strip_url_detail((ui_loop or {}).base_url)
  local origins = copy_string_list((ui_loop or {}).allowed_origins, {}, nil, "testing-runner: malformed-ai-context: allowed_origins", 16)
  local seed = base_url .. ":" .. tostring(#modules) .. ":" .. tostring((inventory or {}).coverage or "") .. ":" .. tostring(request.mode or "disabled")
  return {
    schema = M.context_schema,
    artifact_kind = "ai-context-manifest",
    artifact_root = artifact_root,
    context_manifest_path = request.context_manifest_path or paths.context,
    generated_cases_path = request.generated_cases_path or paths.generated,
    generated_case_gate_path = paths.gate,
    ai_agent_generation_path = paths.agent_generation,
    generated_case_agent_review_path = paths.agent_review,
    ai_test_design_loop_path = paths.review_closure,
    base_url = base_url,
    allowed_origins = origins,
    mutation_policy = (ui_loop or {}).mutation_policy or "read-only",
    readiness = (inventory or {}).readiness or { status = "unknown" },
    budgets = {
      case_budget = request.case_budget or 4,
      step_budget = opts.step_budget or 8,
      case_priorities = copy_string_list(opts.case_priorities, { "P0", "P1" }, allowed_priorities, "testing-runner: malformed-ai-context: case_priorities", 3),
    },
    modules = modules,
    module_count = #modules,
    known_gaps = copy_string_list((inventory or {}).limitations, {}, nil, "testing-runner: malformed-ai-context: known_gaps", 16),
    untrusted_context_notice = "AI case generation treats discovered labels and routes as untrusted sanitized context; FKST schemas and safety gates decide executability.",
    prompt_template_ref = M.prompt_template_ref,
    input_digest = "ctx-" .. strings.decimal_checksum(seed),
    generation_mode = request.mode or "disabled",
  }
end

function M.build_generation_proposal(context, request)
  request = default_request(request)
  M.validate_request(request)
  return ai_agents.build_generation_proposal(context, request)
end

function M.build_review_proposal(context, generated, gate, request)
  request = default_request(request)
  M.validate_request(request)
  return ai_agents.build_review_proposal(context, generated, gate, request)
end

local function generated_case(context, module, suffix, title, action_items, blocked_expected)
  return {
    id = module.id .. ":ai-" .. suffix,
    module_id = module.id,
    priority = "P1",
    title = title,
    objective = title,
    case_kind = blocked_expected and "read-only-interaction" or "primary-interaction",
    actions = action_items,
    expected_observable = blocked_expected or "The local page remains same-origin, visible, and stable after the interaction.",
    evidence_pointers = module.evidence_pointer and { module.evidence_pointer } or {},
    provenance = {
      origin = "ai-generated",
      context_manifest_path = context.context_manifest_path,
      prompt_template_ref = context.prompt_template_ref,
      model_invocation_digest = "local-reviewed-" .. strings.decimal_checksum(context.input_digest .. module.id .. suffix),
    },
  }
end

function M.generate_cases(context, request)
  request = default_request(request)
  M.validate_request(request)
  local cases = {}
  local mode = request.mode or "disabled"
  if mode ~= "disabled" then
    local budget = request.case_budget or (((context or {}).budgets or {}).case_budget) or 4
    for _, module in ipairs((context or {}).modules or {}) do
      if #cases >= budget then break end
      table.insert(cases, generated_case(context, module, "visible-surface", "Exercise visible read-only surface for " .. module_label(module), {
        { action = "open-visible-surface", target = module.visible_label or module.route or module.id, expected = "visible surface can be opened without leaving local scope", evidence_pointer = module.evidence_pointer },
        { action = "close-visible-surface", target = module.visible_label or module.route or module.id, expected = "visible surface can be closed or safely returned", evidence_pointer = module.evidence_pointer },
      }))
      if #cases >= budget then break end
      table.insert(cases, generated_case(context, module, "search-filter", "Probe read-only search or filter behavior for " .. module_label(module), {
        { action = "search-or-filter-readonly", target = module.visible_label or module.route or module.id, expected = "filter input changes visible results without mutation", evidence_pointer = module.evidence_pointer },
        { action = "clear-filter-readonly", target = module.visible_label or module.route or module.id, expected = "clearing the filter restores visible results", evidence_pointer = module.evidence_pointer },
      }, "Requires visible search/filter control evidence before execution."))
    end
  end
  return {
    schema = M.generated_cases_schema,
    artifact_kind = "generated-test-cases",
    artifact_root = context.artifact_root,
    context_manifest_path = context.context_manifest_path,
    prompt_template_ref = context.prompt_template_ref,
    generation_mode = mode,
    generation_digest = "gen-" .. strings.decimal_checksum((context.input_digest or "context") .. ":" .. tostring(#cases)),
    generated_cases_path = context.generated_cases_path,
    cases = cases,
    case_count = #cases,
  }
end

local function module_index(context)
  local modules = {}
  for _, module in ipairs((context or {}).modules or {}) do modules[module.id] = module end
  return modules
end

local function validate_provenance(value, context)
  if value == nil then
    return {
      origin = "ai-generated",
      context_manifest_path = context.context_manifest_path,
      prompt_template_ref = context.prompt_template_ref,
      model_invocation_digest = "missing-provenance-" .. strings.decimal_checksum(context.input_digest or "context"),
    }
  end
  if type(value) ~= "table" then error("testing-runner: malformed-generated-case: provenance must be a table") end
  validate_fields(value, provenance_fields, "generated case provenance")
  if value.origin ~= "ai-generated" then error("testing-runner: malformed-generated-case: provenance.origin must be ai-generated") end
  if value.context_manifest_path ~= nil and not safe_artifact_pointer(value.context_manifest_path) then error("testing-runner: malformed-generated-case: provenance.context_manifest_path must be a pointer") end
  if value.prompt_template_ref ~= nil and not bounded_string(value.prompt_template_ref, max_string) then error("testing-runner: malformed-generated-case: provenance.prompt_template_ref must be bounded") end
  if value.model_invocation_digest ~= nil and not bounded_id(value.model_invocation_digest) then error("testing-runner: malformed-generated-case: provenance.model_invocation_digest must be bounded") end
  return {
    origin = "ai-generated",
    context_manifest_path = value.context_manifest_path or context.context_manifest_path,
    prompt_template_ref = value.prompt_template_ref or context.prompt_template_ref,
    model_invocation_digest = value.model_invocation_digest or ("missing-digest-" .. strings.decimal_checksum(context.input_digest or "context")),
  }
end

local function validate_action(action, context, module, request_sets)
  if type(action) ~= "table" then error("testing-runner: malformed-generated-case: actions items must be tables") end
  validate_fields(action, action_fields, "generated case action")
  if allowed_action_kinds[action.action] ~= true or request_sets.actions[action.action] ~= true then error("testing-runner: malformed-generated-case: action kind is unsupported") end
  if not bounded_string(action.target, max_string) then error("testing-runner: malformed-generated-case: action.target is required") end
  if not target_within_scope(action.target, context) then error("testing-runner: malformed-generated-case: action target leaves local allowed origins") end
  local item = {
    action = action.action,
    target = strip_url_detail(action.target),
    expected = bounded_string(action.expected, max_string) and action.expected or "bounded observable outcome",
  }
  if action.target_module_id ~= nil then
    if not bounded_id(action.target_module_id) then error("testing-runner: malformed-generated-case: action.target_module_id must be bounded") end
    item.target_module_id = action.target_module_id
  end
  if action.evidence_pointer ~= nil then
    if not safe_artifact_pointer(action.evidence_pointer) then error("testing-runner: malformed-generated-case: action.evidence_pointer must be safe") end
    item.evidence_pointer = action.evidence_pointer
  elseif module.evidence_pointer ~= nil then
    item.evidence_pointer = module.evidence_pointer
  end
  return item
end

local function normalized_status(case, actions, context, module, request)
  local mutation_policy = context.mutation_policy or "read-only"
  local saw_search = false
  for _, action in ipairs(actions) do
    if action.action == "safe-mutation-fixture" then
      if mutation_policy ~= "host-approved" then
        return "not-executed-risk", "mutation_policy " .. mutation_policy .. " records generated mutation as a gap", "read-only-policy"
      end
      return "blocked", "generated safe mutation requires host fixture and cleanup or rollback evidence", "fixture-data-gap"
    end
    if action.action == "search-or-filter-readonly" or action.action == "clear-filter-readonly" then saw_search = true end
  end
  if saw_search and not module_has_signal(module, "search-or-filter-control") then
    return "blocked", "requires visible search/filter control evidence", "missing-control-evidence"
  end
  if case.review_status == "blocked" or case.review_status == "not-executed-risk" then
    return case.review_status, case.reason or "generated case supplied as non-executable", "supplied-review-status"
  end
  return "executable", "generated read-only case passed FKST schema and safety gates", "schema-and-scope-approved"
end

local function normalize_case(case, context, request, request_sets)
  if type(case) ~= "table" then error("testing-runner: malformed-generated-case: case items must be tables") end
  validate_fields(case, generated_case_fields, "generated case")
  local bad = contains_forbidden(case)
  if bad ~= nil then error("testing-runner: malformed-generated-case: contains forbidden payload term: " .. bad) end
  if not bounded_id(case.id) then error("testing-runner: malformed-generated-case: id is required") end
  if not bounded_id(case.module_id) then error("testing-runner: malformed-generated-case: module_id is required") end
  local modules = module_index(context)
  local module = modules[case.module_id]
  if module == nil then error("testing-runner: malformed-generated-case: module_id is unknown") end
  if allowed_priorities[case.priority] ~= true then error("testing-runner: malformed-generated-case: priority is invalid") end
  if allowed_case_kinds[case.case_kind] ~= true or request_sets.kinds[case.case_kind] ~= true then error("testing-runner: malformed-generated-case: case_kind is unsupported") end
  if not bounded_string(case.title, max_string) or not bounded_string(case.objective, max_string) then error("testing-runner: malformed-generated-case: title and objective are required") end
  local ok_actions, action_count = dense_list(case.actions)
  if not ok_actions or action_count == 0 or action_count > max_actions then error("testing-runner: malformed-generated-case: actions must be a non-empty dense list") end
  local actions = {}
  for _, action in ipairs(case.actions) do table.insert(actions, validate_action(action, context, module, request_sets)) end
  local evidence_pointers = {}
  if case.evidence_pointers ~= nil then
    local ok_refs, ref_count = dense_list(case.evidence_pointers)
    if not ok_refs or ref_count > max_actions then error("testing-runner: malformed-generated-case: evidence_pointers must be dense") end
    for _, pointer in ipairs(case.evidence_pointers) do
      if not safe_artifact_pointer(pointer) then error("testing-runner: malformed-generated-case: evidence_pointers items must be safe") end
      table.insert(evidence_pointers, pointer)
    end
  elseif module.evidence_pointer ~= nil then
    table.insert(evidence_pointers, module.evidence_pointer)
  end
  local status, reason, classification = normalized_status(case, actions, context, module, request)
  return {
    id = case.id,
    module_id = case.module_id,
    priority = case.priority,
    title = case.title,
    objective = case.objective,
    case_kind = case.case_kind,
    case_origin = "ai-generated",
    actions = actions,
    expected_observable = bounded_string(case.expected_observable, max_string) and case.expected_observable or "bounded observable outcome",
    evidence_pointer = case.evidence_pointer or evidence_pointers[1] or module.evidence_pointer,
    evidence_pointers = evidence_pointers,
    provenance = validate_provenance(case.provenance, context),
    review_status = status,
    reason = reason,
    ai_gate = {
      status = status,
      classification = classification,
    },
  }
end

function M.validate_generated_cases(value)
  if type(value) ~= "table" then error("testing-runner: malformed-generated-cases: payload must be a table") end
  validate_fields(value, generated_payload_fields, "testing-runner: malformed-generated-cases")
  if value.schema ~= M.generated_cases_schema then error("testing-runner: unknown-generated-cases-schema: expected " .. M.generated_cases_schema) end
  if not strings.is_artifact_root(value.artifact_root) then error("testing-runner: malformed-generated-cases: artifact_root must be safe") end
  if not safe_artifact_pointer(value.context_manifest_path) then error("testing-runner: malformed-generated-cases: context_manifest_path must be a safe pointer") end
  if value.generated_cases_path ~= nil and not safe_artifact_pointer(value.generated_cases_path) then error("testing-runner: malformed-generated-cases: generated_cases_path must be a safe pointer") end
  local ok_cases, case_count = dense_list(value.cases)
  if not ok_cases or case_count > max_cases then error("testing-runner: malformed-generated-cases: cases must be a bounded dense list") end
  if type(value.case_count) ~= "number" or value.case_count ~= case_count then error("testing-runner: malformed-generated-cases: case_count must match cases") end
  return value
end

function M.generation_from_agent_results(context, agent_result)
  return ai_agents.generation_from_agent_results(context, agent_result)
end

function M.validate_agent_generation(value)
  return ai_agents.validate_agent_generation(value)
end

function M.review_from_agent_results(context, gate, agent_result)
  return ai_agents.review_from_agent_results(context, gate, agent_result)
end

function M.validate_agent_review(value)
  return ai_agents.validate_agent_review(value)
end

function M.gate_generated_cases(generated, context, request)
  request = default_request(request)
  M.validate_request(request)
  M.validate_generated_cases(generated)
  local request_sets = {
    kinds = set_from_list(copy_string_list(request.allowed_case_kinds, { "entry-health", "primary-interaction", "read-only-interaction", "module-transition", "mutation-or-edge" }, allowed_case_kinds, "testing-runner: malformed-request: ai_generation.allowed_case_kinds", max_actions)),
    actions = set_from_list(copy_string_list(request.allowed_action_kinds, { "bounded-navigation", "open-visible-surface", "close-visible-surface", "search-or-filter-readonly", "clear-filter-readonly", "module-transition", "safe-mutation-fixture" }, allowed_action_kinds, "testing-runner: malformed-request: ai_generation.allowed_action_kinds", max_actions)),
  }
  local decisions, cases = {}, {}
  local counts = { accepted = 0, executable = 0, blocked = 0, rejected = 0, ["not-executed-risk"] = 0 }
  for _, case in ipairs(generated.cases or {}) do
    local ok, normalized_or_error = pcall(normalize_case, case, context, request, request_sets)
    if ok then
      local normalized = normalized_or_error
      table.insert(cases, normalized)
      counts.accepted = counts.accepted + 1
      counts[normalized.review_status] = (counts[normalized.review_status] or 0) + 1
      table.insert(decisions, {
        case_id = normalized.id,
        module_id = normalized.module_id,
        review_status = normalized.review_status,
        classification = normalized.ai_gate.classification,
        reason = normalized.reason,
      })
    else
      counts.rejected = counts.rejected + 1
      table.insert(decisions, {
        case_id = bounded_string(type(case) == "table" and case.id or nil, max_id) and case.id or "rejected-generated-case",
        review_status = "rejected",
        classification = "schema-or-safety-rejected",
        reason = tostring(normalized_or_error):sub(1, max_string),
      })
    end
  end
  local status = counts.rejected > 0 and "degraded" or "reviewed"
  if counts.accepted == 0 and generated.case_count > 0 then status = "blocked" end
  return {
    schema = M.gate_schema,
    artifact_kind = "generated-case-gate",
    artifact_root = context.artifact_root,
    context_manifest_path = context.context_manifest_path,
    generated_cases_path = context.generated_cases_path,
    generated_case_gate_path = context.generated_case_gate_path,
    status = status,
    mode = request.mode or "disabled",
    accepted_count = counts.accepted,
    executable_count = counts.executable,
    blocked_count = counts.blocked,
    not_executed_risk_count = counts["not-executed-risk"],
    rejected_count = counts.rejected,
    decisions = decisions,
    cases = cases,
  }
end

function M.agent_review_allows_merge(review, case)
  return ai_agents.agent_review_allows_merge(review, case)
end

function M.merge_generated_cases(plan_modules, gate, agent_review)
  local by_module = {}
  for _, module in ipairs(plan_modules or {}) do by_module[module.id] = module end
  for _, case in ipairs((gate or {}).cases or {}) do
    local module = by_module[case.module_id]
    if module ~= nil and M.agent_review_allows_merge(agent_review, case) then table.insert(module.cases, case) end
  end
  return plan_modules
end

local function append_unique(list, seen, value)
  if value == nil or seen[value] == true then return end
  if #list >= max_follow_ups then return end
  table.insert(list, value)
  seen[value] = true
end

local function follow_up_for(classification, final_status)
  if final_status == "execution-eligible" then return "Generated case is eligible for bounded deterministic execution." end
  if classification == "missing-control-evidence" then return "Add bounded local evidence for the visible control before execution."
  elseif classification == "read-only-policy" then return "Keep mutation or write paths recorded as not-executed risk, or provide host-approved safe fixtures."
  elseif classification == "fixture-data-gap" then return "Provide host-approved fixture, evidence, and cleanup or rollback pointers."
  elseif classification == "schema-or-safety-rejected" then return "Drop or repair the generated case; deterministic schema and safety rejection is authoritative."
  elseif classification == "agent-review-required" then return "Run agent review before merging autonomous-reviewed generated cases."
  elseif classification == "agent-review-blocked" then return "Generated case remains blocked until agent review approves it."
  end
  return "Review bounded local evidence before promoting this generated case to execution."
end

function M.build_review_closure(context, generated, gate, agent_generation, agent_review)
  if context == nil or generated == nil or gate == nil then return nil end
  local mode = context.generation_mode or "disabled"
  local approved_ids = set_from_list(agent_review and agent_review.approved_case_ids or {})
  local rows, follow_ups, seen_follow_up = {}, {}, {}
  local counts = {
    deterministic_executable = 0,
    execution_eligible = 0,
    blocked = 0,
    rejected = 0,
    ["not-executed-risk"] = 0,
  }

  for _, decision in ipairs(gate.decisions or {}) do
    local deterministic_status = decision.review_status or "blocked"
    local classification = decision.classification or "unknown"
    local agent_status = agent_review and agent_review.status or (mode == "autonomous-reviewed" and "missing" or "not-required")
    local final_status = "blocked"
    if deterministic_status == "executable" then
      counts.deterministic_executable = counts.deterministic_executable + 1
      if mode == "autonomous-reviewed" then
        if agent_review ~= nil and agent_review.status == "approved" and approved_ids[decision.case_id] == true then
          final_status = "execution-eligible"
          counts.execution_eligible = counts.execution_eligible + 1
        else
          classification = agent_review == nil and "agent-review-required" or "agent-review-blocked"
          counts.blocked = counts.blocked + 1
        end
      else
        final_status = "execution-eligible"
        counts.execution_eligible = counts.execution_eligible + 1
      end
    elseif deterministic_status == "not-executed-risk" then
      final_status = "not-executed-risk"
      counts["not-executed-risk"] = counts["not-executed-risk"] + 1
    elseif deterministic_status == "rejected" then
      final_status = "rejected"
      counts.rejected = counts.rejected + 1
    else
      final_status = "blocked"
      counts.blocked = counts.blocked + 1
    end
    local follow_up = follow_up_for(classification, final_status)
    if final_status ~= "execution-eligible" then append_unique(follow_ups, seen_follow_up, follow_up) end
    table.insert(rows, {
      case_id = bounded_id(decision.case_id) and decision.case_id or "generated-case",
      module_id = bounded_id(decision.module_id) and decision.module_id or nil,
      deterministic_status = deterministic_status,
      classification = classification,
      agent_review_status = agent_status,
      final_status = final_status,
      required_follow_up = follow_up,
    })
    if #rows >= max_cases then break end
  end

  local status = "reviewed"
  if counts.rejected > 0 then status = "degraded" end
  if (generated.case_count or 0) > 0 and counts.execution_eligible == 0 then status = "blocked" end
  if mode == "autonomous-reviewed" and (agent_review == nil or agent_review.status ~= "approved") then status = "blocked" end

  return {
    schema = M.review_closure_schema,
    artifact_kind = "ai-test-design-loop",
    artifact_root = context.artifact_root,
    context_manifest_path = context.context_manifest_path,
    generated_cases_path = context.generated_cases_path,
    generated_case_gate_path = context.generated_case_gate_path,
    ai_agent_generation_path = agent_generation and context.ai_agent_generation_path or nil,
    generated_case_agent_review_path = agent_review and context.generated_case_agent_review_path or nil,
    ai_test_design_loop_path = context.ai_test_design_loop_path,
    status = status,
    mode = mode,
    generated_case_count = generated.case_count or 0,
    reviewed_case_count = #rows,
    deterministic_executable_generated_case_count = counts.deterministic_executable,
    execution_eligible_generated_case_count = counts.execution_eligible,
    blocked_generated_case_count = counts.blocked,
    not_executed_risk_generated_case_count = counts["not-executed-risk"],
    rejected_generated_case_count = counts.rejected,
    agent_approved_generated_case_count = agent_review and agent_review.approved_case_count or 0,
    required_follow_up = follow_ups,
    required_follow_up_count = #follow_ups,
    reviewed_cases = rows,
  }
end

function M.summary(context, generated, gate, agent_generation, agent_review)
  if context == nil then
    return { status = "disabled", mode = "disabled", generated_case_count = 0, executable_generated_case_count = 0, blocked_generated_case_count = 0 }
  end
  local status = gate and gate.status or "disabled"
  if agent_review ~= nil then
    if agent_review.status == "approved" then
      status = status == "reviewed" and "reviewed" or status
    elseif agent_review.status == "rejected" or agent_review.status == "converged" or agent_review.status == "unavailable" then
      status = "blocked"
    end
  end
  return {
    status = status,
    mode = context.generation_mode or "disabled",
    context_manifest_path = context.context_manifest_path,
    generated_cases_path = context.generated_cases_path,
    generated_case_gate_path = context.generated_case_gate_path,
    ai_agent_generation_path = agent_generation and context.ai_agent_generation_path or nil,
    generated_case_agent_review_path = agent_review and context.generated_case_agent_review_path or nil,
    ai_test_design_loop_path = context.ai_test_design_loop_path,
    prompt_template_ref = context.prompt_template_ref,
    input_digest = context.input_digest,
    generated_case_count = generated and generated.case_count or 0,
    accepted_generated_case_count = gate and gate.accepted_count or 0,
    executable_generated_case_count = gate and gate.executable_count or 0,
    blocked_generated_case_count = gate and gate.blocked_count or 0,
    rejected_generated_case_count = gate and gate.rejected_count or 0,
    agent_generation_status = agent_generation and agent_generation.status or nil,
    agent_generation_seat_count = agent_generation and agent_generation.seat_count or nil,
    agent_review_status = agent_review and agent_review.status or nil,
    agent_review_seat_count = agent_review and agent_review.seat_count or nil,
    agent_approved_generated_case_count = agent_review and agent_review.approved_case_count or nil,
  }
end

function M.prompt_for_context(context)
  return table.concat({
    "Generate bounded read-only UI test cases from the FKST AI context manifest.",
    "Use only FKST action enums and local same-origin scope.",
    "Do not request raw DOM, screenshots, browser state, session secrets, credentials, or raw reports.",
    "Context manifest pointer: " .. tostring((context or {}).context_manifest_path or "not-recorded"),
    "Return normalized generated-test-cases JSON only.",
  }, "\n")
end

function M.read_only_generation_opts(context, worktree)
  return workflow_codex.judgment_codex_opts(M.prompt_for_context(context), worktree)
end

return M
