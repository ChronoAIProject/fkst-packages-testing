local M = {}

local source_ref = require("contract.source_ref")
local strings = require("contract.strings")
local testing_contract = require("contract.testing")

M.scope_schema = "testing-discovery.app-scope.v1"
M.plan_schema = "testing-discovery.plan.v1"
M.plan_filename = "testing-discovery-plan.json"

local max_string = 512
local max_id = 180
local max_modules = 64
local max_observations = 64

local scope_fields = {
  allowed_origins = true,
  artifact_root = true,
  base_url = true,
  budgets = true,
  dedup_key = true,
  mutation_policy = true,
  observations = true,
  schema = true,
  sessions = true,
  source_ref = true,
  trace_id = true,
}

local budget_fields = {
  case_priorities = true,
  module_limit = true,
  observation_limit = true,
  step_budget = true,
}

local observation_fields = {
  confidence = true,
  discovery_source = true,
  entry_url = true,
  evidence_pointer = true,
  id = true,
  name = true,
  route = true,
  source = true,
  visible_label = true,
}

local session_fields = {
  browser_harness_command = true,
  browser_harness_command_env = true,
  cdp_endpoint_env = true,
  cdp_url = true,
  role = true,
}

local allowed_sources = {
  accessibility = true,
  ["a11y-visible"] = true,
  browser = true,
  ["browser-visible"] = true,
  navigation = true,
  ["nav-link"] = true,
  route = true,
  ["route-manifest"] = true,
}

local allowed_confidence = {
  high = true,
  medium = true,
  low = true,
}

local allowed_priorities = {
  P0 = true,
  P1 = true,
  P2 = true,
}

local function text_has_no_control(value)
  return type(value) == "string" and value:find("[%z\1-\31]") == nil
end

local function bounded_string(value, limit)
  return strings.is_bounded_string(value, limit or max_string) and text_has_no_control(value)
end

local function dense_list(value)
  if type(value) ~= "table" then return false end
  local count, max_index = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return false end
    count = count + 1
    if key > max_index then max_index = key end
  end
  return count == max_index, count
end

local function safe_artifact_root(value)
  return strings.is_artifact_root(value) and value:find("..", 1, true) == nil
end

local function strip_url_detail(value)
  return tostring(value or ""):gsub("[#?].*$", "")
end

local function origin_from_url(value)
  if not bounded_string(value, max_string) then return nil end
  local scheme, authority = value:match("^(https?)://([^/%?#]+)")
  if scheme == nil or authority == nil or authority == "" then return nil end
  if authority:find("%s") ~= nil or authority:find("\\", 1, true) ~= nil or authority:find("@", 1, true) ~= nil then return nil end
  return scheme:lower() .. "://" .. authority:lower()
end

local function host_from_url(value)
  local authority = tostring(value or ""):match("^https?://([^/%?#]+)")
  if authority == nil then return nil end
  local bracketed = authority:match("^%[([^%]]+)%]")
  if bracketed ~= nil then return bracketed:lower() end
  return (authority:match("^([^:]+)") or authority):lower()
end

local function local_http_url(value)
  local host = host_from_url(value)
  return host == "localhost" or host == "127.0.0.1" or host == "::1"
end

local function path_from_http_url(value)
  local clean = strip_url_detail(value)
  local path = clean:match("^https?://[^/%?#]+([^%?#]*)")
  if path == nil or path == "" then return "/" end
  return path
end

local function normalize_route(value)
  if not bounded_string(value, max_string) then return nil end
  local route = strip_url_detail(value)
  if route:sub(1, 1) ~= "/" then return nil end
  return route
end

local function within_base_scope(entry_url, base_url)
  local scope = strip_url_detail(base_url)
  local clean = strip_url_detail(entry_url)
  if not bounded_string(scope, max_string) or not bounded_string(clean, max_string) then return false end
  if scope:sub(-1) == "/" then return clean:sub(1, #scope) == scope end
  return clean == scope or clean:sub(1, #scope + 1) == scope .. "/"
end

local function copy_list(value)
  local copy = {}
  for _, item in ipairs(value or {}) do table.insert(copy, item) end
  return copy
end

local function validate_has_only(value, allowed, context)
  for key, _ in pairs(value or {}) do
    if allowed[key] ~= true then error(context .. " has unsupported field") end
  end
end

local function validate_session(session)
  if type(session) ~= "table" then error("testing-discovery: malformed-request: sessions items must be tables") end
  validate_has_only(session, session_fields, "testing-discovery: malformed-request: sessions item")
  if not bounded_string(session.role, 80) then error("testing-discovery: malformed-request: sessions.role is required") end
  local has_harness = bounded_string(session.browser_harness_command, 256) or bounded_string(session.browser_harness_command_env, 128)
  local has_cdp = bounded_string(session.cdp_endpoint_env, 128) or bounded_string(session.cdp_url, max_string)
  if not has_harness and not has_cdp then error("testing-discovery: malformed-request: sessions item lacks readiness source") end
  if session.cdp_url ~= nil and not local_http_url(session.cdp_url) then error("testing-discovery: malformed-request: sessions.cdp_url must be local http") end
end

local function validate_string_list(value, context, max_items)
  local ok, count = dense_list(value)
  if not ok or count == 0 or count > max_items then error(context .. " must be a non-empty bounded dense list") end
  for _, item in ipairs(value) do
    if not bounded_string(item, max_string) then error(context .. " items must be bounded strings") end
  end
end

local function validate_budgets(value)
  local budgets = value or {}
  if type(budgets) ~= "table" then error("testing-discovery: malformed-request: budgets must be a table") end
  validate_has_only(budgets, budget_fields, "testing-discovery: malformed-request: budgets")
  local module_limit = budgets.module_limit or 16
  local observation_limit = budgets.observation_limit or max_observations
  local step_budget = budgets.step_budget or 8
  if type(module_limit) ~= "number" or module_limit < 1 or module_limit > max_modules or math.floor(module_limit) ~= module_limit then
    error("testing-discovery: malformed-request: budgets.module_limit must be an integer from 1 to 64")
  end
  if type(observation_limit) ~= "number" or observation_limit < 1 or observation_limit > max_observations or math.floor(observation_limit) ~= observation_limit then
    error("testing-discovery: malformed-request: budgets.observation_limit must be an integer from 1 to 64")
  end
  if type(step_budget) ~= "number" or step_budget < 1 or step_budget > 32 or math.floor(step_budget) ~= step_budget then
    error("testing-discovery: malformed-request: budgets.step_budget must be an integer from 1 to 32")
  end
  local priorities = budgets.case_priorities or { "P0", "P1" }
  local ok, count = dense_list(priorities)
  if not ok or count == 0 or count > 3 then error("testing-discovery: malformed-request: budgets.case_priorities must be a bounded dense list") end
  for _, priority in ipairs(priorities) do
    if allowed_priorities[priority] ~= true then error("testing-discovery: malformed-request: budgets.case_priorities is invalid") end
  end
  return {
    module_limit = module_limit,
    observation_limit = observation_limit,
    step_budget = step_budget,
    case_priorities = copy_list(priorities),
  }
end

local function validate_observation(value)
  if type(value) ~= "table" then error("testing-discovery: malformed-request: observations items must be tables") end
  validate_has_only(value, observation_fields, "testing-discovery: malformed-request: observations item")
  for key, item in pairs(value) do
    if key ~= "confidence" and key ~= "discovery_source" and key ~= "source" then
      if not bounded_string(item, key == "id" and max_id or max_string) then
        error("testing-discovery: malformed-request: observations." .. key .. " must be a bounded string")
      end
    end
  end
  if value.confidence ~= nil and allowed_confidence[value.confidence] ~= true then
    error("testing-discovery: malformed-request: observations.confidence is invalid")
  end
  local source = value.discovery_source or value.source
  if source ~= nil and allowed_sources[source] ~= true then
    error("testing-discovery: malformed-request: observations.source is invalid")
  end
end

local function configured_origins(payload)
  local base_origin = origin_from_url(payload.base_url)
  local origins, seen = {}, {}
  local includes_base = false
  local function add(origin)
    if origin ~= nil and seen[origin] ~= true then
      table.insert(origins, origin)
      seen[origin] = true
    end
  end
  for _, origin in ipairs(payload.allowed_origins or {}) do
    local normalized = origin_from_url(origin)
    if normalized == base_origin then includes_base = true end
    add(normalized)
  end
  return origins, seen, base_origin, includes_base
end

function M.validate_scope(payload)
  if type(payload) ~= "table" then error("testing-discovery: malformed-request: payload must be a table") end
  validate_has_only(payload, scope_fields, "testing-discovery: malformed-request: payload")
  if payload.schema ~= M.scope_schema then error("testing-discovery: unknown-schema: expected " .. M.scope_schema) end
  if not bounded_string(payload.base_url, max_string) or not local_http_url(payload.base_url) then
    error("testing-discovery: malformed-request: base_url must be local http")
  end
  validate_string_list(payload.allowed_origins, "testing-discovery: malformed-request: allowed_origins", 16)
  local _, _, base_origin, includes_base = configured_origins(payload)
  if base_origin == nil or includes_base ~= true then
    error("testing-discovery: malformed-request: allowed_origins must include base_url origin")
  end
  for _, origin in ipairs(payload.allowed_origins) do
    local normalized = origin_from_url(origin)
    if normalized == nil or not local_http_url(origin) or strip_url_detail(origin):gsub("/+$", "") ~= normalized then
      error("testing-discovery: malformed-request: allowed_origins must be local http origins")
    end
  end
  local sessions_ok, session_count = dense_list(payload.sessions)
  if not sessions_ok or session_count == 0 or session_count > 16 then error("testing-discovery: malformed-request: sessions must be a non-empty bounded dense list") end
  for _, session in ipairs(payload.sessions) do validate_session(session) end
  if payload.mutation_policy ~= nil and payload.mutation_policy ~= "read-only" and payload.mutation_policy ~= "dry-run" and payload.mutation_policy ~= "host-approved" then
    error("testing-discovery: malformed-request: mutation_policy is unknown")
  end
  local observations_ok, observation_count = dense_list(payload.observations or {})
  if not observations_ok or observation_count > max_observations then error("testing-discovery: malformed-request: observations must be a bounded dense list") end
  for _, observation in ipairs(payload.observations or {}) do validate_observation(observation) end
  if not safe_artifact_root(payload.artifact_root) then error("testing-discovery: malformed-request: artifact_root must be a safe .testing/runs/... path") end
  if payload.source_ref ~= nil and not source_ref.has_bounded_source_ref(payload.source_ref, max_string) then error("testing-discovery: malformed-request: source_ref must be bounded") end
  if payload.trace_id ~= nil and not testing_contract.is_bounded_id(payload.trace_id) then error("testing-discovery: malformed-request: trace_id must be bounded") end
  if payload.dedup_key ~= nil and not testing_contract.is_bounded_id(payload.dedup_key) then error("testing-discovery: malformed-request: dedup_key must be bounded") end
  return payload
end

local function entry_url_for(observation, base_origin)
  local explicit = strip_url_detail(observation.entry_url)
  if origin_from_url(explicit) ~= nil then return explicit end
  local route = normalize_route(observation.route)
  if route ~= nil and base_origin ~= nil then return base_origin .. route end
  return nil
end

local function confidence_for(observation)
  if allowed_confidence[observation.confidence] == true then return observation.confidence end
  if bounded_string(observation.visible_label, max_string) and bounded_string(observation.evidence_pointer, max_string) then return "high" end
  if bounded_string(observation.evidence_pointer, max_string) then return "medium" end
  return "low"
end

local function discovery_id(value, fallback)
  local text = strings.sanitize_key(value or fallback or "module", max_id)
  text = text:gsub("/", "-")
  if text == "" or text == "empty" then return "module" end
  return text
end

local function base_route_prefix(base_url)
  local route = path_from_http_url(base_url)
  if route == nil or route == "" then return "/" end
  return route:gsub("/+$", "")
end

local function cluster_key(route, label, base_url)
  local base_route = base_route_prefix(base_url)
  local rest = tostring(route or "/")
  if base_route ~= "/" and rest == base_route then
    rest = "/"
  elseif base_route ~= "/" and rest:sub(1, #base_route + 1) == base_route .. "/" then
    rest = rest:sub(#base_route + 2)
  else
    rest = rest:gsub("^/+", "")
  end
  local segment = rest:match("^([^/]+)")
  if segment == nil or segment == "" then segment = label or "root" end
  return discovery_id(segment, label or "module")
end

local function normalize_observation(observation, payload, base_origin, allowed_origin_map)
  local entry_url = entry_url_for(observation, base_origin)
  if entry_url == nil or not within_base_scope(entry_url, payload.base_url) then return nil end
  if allowed_origin_map[origin_from_url(entry_url)] ~= true then return nil end
  if not bounded_string(observation.evidence_pointer, max_string) then return nil end
  local source = observation.discovery_source or observation.source or "browser-visible"
  if allowed_sources[source] ~= true then return nil end
  local route = normalize_route(observation.route) or path_from_http_url(entry_url)
  local visible_label = bounded_string(observation.visible_label, max_string) and observation.visible_label or nil
  local name = bounded_string(observation.name, max_string) and observation.name or visible_label or route
  local id = discovery_id(observation.id, name or route)
  return {
    id = id,
    name = name,
    entry_url = entry_url,
    visible_label = visible_label,
    route = route,
    discovery_source = source,
    confidence = confidence_for(observation),
    evidence_pointer = observation.evidence_pointer,
  }
end

local function module_artifact_root(root, id)
  return root .. "/modules/" .. strings.runtime_safe_segment(id)
end

local function module_identity(plan, id)
  local safe = strings.runtime_safe_segment(id)
  local base_trace = plan.trace_id or testing_contract.trace_id(nil, plan.source_ref, plan.artifact_root)
  local base_dedup = plan.dedup_key or testing_contract.dedup_key(nil, { "testing-discovery", plan.source_ref.kind, plan.source_ref.ref, plan.artifact_root })
  return {
    trace_id = testing_contract.safe_key(base_trace .. "-" .. safe, "trace-" .. safe),
    dedup_key = testing_contract.safe_key(base_dedup .. "-" .. safe, "dedup-" .. safe),
  }
end

function M.plan(payload, _opts)
  payload = M.validate_scope(payload)
  local budgets = validate_budgets(payload.budgets)
  local _, allowed_origin_map, base_origin = configured_origins(payload)
  local src = testing_contract.copy_source_ref(payload.source_ref, "host-app", "local-app")
  local plan = {
    schema = M.plan_schema,
    artifact_root = payload.artifact_root,
    plan_path = payload.artifact_root .. "/" .. M.plan_filename,
    base_url = strip_url_detail(payload.base_url),
    allowed_origins = copy_list(payload.allowed_origins),
    sessions = copy_list(payload.sessions),
    mutation_policy = payload.mutation_policy or "read-only",
    budgets = budgets,
    source_ref = src,
    trace_id = payload.trace_id or testing_contract.trace_id(nil, src, payload.artifact_root),
    dedup_key = payload.dedup_key or testing_contract.dedup_key(nil, { "testing-discovery", src.kind, src.ref, payload.artifact_root }),
    modules = {},
    module_count = 0,
    rejected_observation_count = 0,
    limitations = {
      "Discovery is bounded to local origins and the current ready browser session.",
      "Only sanitized route, navigation, accessibility, and browser-visible facts are used for module starts.",
    },
  }

  local clusters, order = {}, {}
  local limit = math.min(budgets.observation_limit, #(payload.observations or {}))
  for index = 1, limit do
    local normalized = normalize_observation(payload.observations[index], payload, base_origin, allowed_origin_map)
    if normalized == nil then
      plan.rejected_observation_count = plan.rejected_observation_count + 1
    else
      local key = cluster_key(normalized.route, normalized.visible_label or normalized.name, payload.base_url)
      if clusters[key] == nil then
        clusters[key] = {
          id = key,
          name = normalized.visible_label or normalized.name or key,
          entry_url = normalized.entry_url,
          route = normalized.route,
          observations = {},
        }
        table.insert(order, key)
      end
      table.insert(clusters[key].observations, normalized)
    end
  end
  if #(payload.observations or {}) > limit then
    plan.rejected_observation_count = plan.rejected_observation_count + (#(payload.observations or {}) - limit)
  end

  for _, key in ipairs(order) do
    if #plan.modules >= budgets.module_limit then
      plan.rejected_observation_count = plan.rejected_observation_count + #clusters[key].observations
    else
      local module = clusters[key]
      local identity = module_identity(plan, module.id)
      module.artifact_root = module_artifact_root(payload.artifact_root, module.id)
      module.source_ref = { kind = "discovered-module", ref = testing_contract.safe_key(src.ref .. "-" .. module.id, module.id) }
      module.trace_id = identity.trace_id
      module.dedup_key = identity.dedup_key
      table.insert(plan.modules, module)
    end
  end

  if #plan.modules == 0 then
    local id = "app-discovery"
    local identity = module_identity(plan, id)
    table.insert(plan.modules, {
      id = id,
      name = "App discovery",
      entry_url = plan.base_url,
      route = path_from_http_url(plan.base_url),
      observations = {},
      artifact_root = module_artifact_root(payload.artifact_root, id),
      source_ref = { kind = "discovered-module", ref = testing_contract.safe_key(src.ref .. "-" .. id, id) },
      trace_id = identity.trace_id,
      dedup_key = identity.dedup_key,
    })
    table.insert(plan.limitations, "No observations were accepted by the discovery gate; a gap module was emitted.")
  end
  if plan.rejected_observation_count > 0 then
    table.insert(plan.limitations, "Some observed entries were omitted because they were outside scope or lacked required evidence.")
  end
  plan.module_count = #plan.modules
  return plan
end

function M.readiness_check(plan)
  return {
    schema = "browser-readiness.check.v1",
    base_url = plan.base_url,
    sessions = plan.sessions,
    request_context = { dry_run = false },
    source_ref = { kind = "testing-discovery-plan", ref = plan.artifact_root },
  }
end

function M.module_starts(plan, readiness_result)
  if type(plan) ~= "table" or plan.schema ~= M.plan_schema then error("testing-discovery: malformed-plan: invalid plan") end
  if type(readiness_result) ~= "table" or not bounded_string(readiness_result.status, 80) then error("testing-discovery: malformed-result: readiness status is required") end
  local starts = {}
  for _, module in ipairs(plan.modules or {}) do
    table.insert(starts, {
      schema = "testing-pipeline.module-start.v1",
      module = module.id,
      backend = "fkst-native",
      dry_run = false,
      preflight_result = readiness_result,
      ui_loop = {
        base_url = plan.base_url,
        allowed_origins = plan.allowed_origins,
        browser_readiness_ref = plan.artifact_root .. "/readiness.json",
        cdp_readiness_ref = plan.artifact_root .. "/cdp-ready",
        mutation_policy = plan.mutation_policy,
        gap_ref = module.artifact_root .. "/gap-backlog.json",
      },
      module_discovery = {
        schema = "testing-runner.module-discovery.v1",
        observations = module.observations or {},
        limitations = plan.limitations,
      },
      cdp_execution = {
        schema = "testing-runner.module-cdp-execution.v1",
        step_budget = plan.budgets.step_budget,
        case_priorities = plan.budgets.case_priorities,
      },
      artifact_root = module.artifact_root,
      source_ref = module.source_ref,
      trace_id = module.trace_id,
      dedup_key = module.dedup_key,
    })
  end
  return starts
end

local function json_escape(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\b", "\\b")
  text = text:gsub("\f", "\\f")
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  text = text:gsub("[%z\1-\31]", function(char) return string.format("\\u%04x", char:byte()) end)
  return text
end

local function is_array(value)
  local ok = dense_list(value)
  return ok
end

local function json_encode(value)
  local kind = type(value)
  if kind == "nil" then return "null" end
  if kind == "boolean" then return value and "true" or "false" end
  if kind == "number" then return tostring(value) end
  if kind == "string" then return '"' .. json_escape(value) .. '"' end
  if kind ~= "table" then return '"' .. json_escape(value) .. '"' end
  local parts = {}
  if is_array(value) then
    for _, item in ipairs(value) do table.insert(parts, json_encode(item)) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  local keys = {}
  for key, _ in pairs(value) do table.insert(keys, tostring(key)) end
  table.sort(keys)
  for _, key in ipairs(keys) do table.insert(parts, '"' .. json_escape(key) .. '":' .. json_encode(value[key])) end
  return "{" .. table.concat(parts, ",") .. "}"
end
M.json_encode = json_encode

local function skip_ws(text, pos)
  while true do
    local char = text:sub(pos, pos)
    if char ~= " " and char ~= "\n" and char ~= "\r" and char ~= "\t" then return pos end
    pos = pos + 1
  end
end

local parse_value

local function parse_string(text, pos)
  pos = pos + 1
  local parts = {}
  while pos <= #text do
    local char = text:sub(pos, pos)
    if char == '"' then return table.concat(parts), pos + 1 end
    if char == "\\" then
      local esc = text:sub(pos + 1, pos + 1)
      if esc == '"' or esc == "\\" or esc == "/" then table.insert(parts, esc)
      elseif esc == "b" then table.insert(parts, "\b")
      elseif esc == "f" then table.insert(parts, "\f")
      elseif esc == "n" then table.insert(parts, "\n")
      elseif esc == "r" then table.insert(parts, "\r")
      elseif esc == "t" then table.insert(parts, "\t")
      elseif esc == "u" then table.insert(parts, "?"); pos = pos + 4
      else error("testing-discovery: malformed-plan: invalid json escape") end
      pos = pos + 2
    else
      table.insert(parts, char)
      pos = pos + 1
    end
  end
  error("testing-discovery: malformed-plan: unterminated json string")
end

local function parse_array(text, pos)
  local out = {}
  pos = skip_ws(text, pos + 1)
  if text:sub(pos, pos) == "]" then return out, pos + 1 end
  while true do
    local value
    value, pos = parse_value(text, pos)
    table.insert(out, value)
    pos = skip_ws(text, pos)
    local char = text:sub(pos, pos)
    if char == "]" then return out, pos + 1 end
    if char ~= "," then error("testing-discovery: malformed-plan: expected array separator") end
    pos = skip_ws(text, pos + 1)
  end
end

local function parse_object(text, pos)
  local out = {}
  pos = skip_ws(text, pos + 1)
  if text:sub(pos, pos) == "}" then return out, pos + 1 end
  while true do
    if text:sub(pos, pos) ~= '"' then error("testing-discovery: malformed-plan: expected object key") end
    local key
    key, pos = parse_string(text, pos)
    pos = skip_ws(text, pos)
    if text:sub(pos, pos) ~= ":" then error("testing-discovery: malformed-plan: expected key separator") end
    out[key], pos = parse_value(text, skip_ws(text, pos + 1))
    pos = skip_ws(text, pos)
    local char = text:sub(pos, pos)
    if char == "}" then return out, pos + 1 end
    if char ~= "," then error("testing-discovery: malformed-plan: expected object separator") end
    pos = skip_ws(text, pos + 1)
  end
end

function parse_value(text, pos)
  pos = skip_ws(text, pos)
  local char = text:sub(pos, pos)
  if char == '"' then return parse_string(text, pos) end
  if char == "{" then return parse_object(text, pos) end
  if char == "[" then return parse_array(text, pos) end
  if text:sub(pos, pos + 3) == "true" then return true, pos + 4 end
  if text:sub(pos, pos + 4) == "false" then return false, pos + 5 end
  if text:sub(pos, pos + 3) == "null" then return nil, pos + 4 end
  local number_text = text:sub(pos):match("^-?%d+%.?%d*")
  if number_text ~= nil then return tonumber(number_text), pos + #number_text end
  error("testing-discovery: malformed-plan: invalid json value")
end

local function json_decode(text)
  local value, pos = parse_value(text, 1)
  pos = skip_ws(text, pos)
  if pos <= #text then error("testing-discovery: malformed-plan: trailing json data") end
  return value
end
M.json_decode = json_decode

local function shell_quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function write_file(path, body)
  local dir = path:match("^(.*)/[^/]+$")
  if not dir or dir == "" then return nil, "missing artifact directory" end
  if not safe_artifact_root(dir) and dir:sub(1, 14) ~= ".testing/runs/" then return nil, "unsafe artifact directory" end
  local ok = os.execute("mkdir -p " .. shell_quote(dir))
  if ok ~= true and ok ~= 0 then return nil, "failed to create artifact directory" end
  local file, err = io.open(path, "w")
  if not file then return nil, err or "failed to open artifact file" end
  local wrote, write_err = file:write(body)
  file:close()
  if not wrote then return nil, write_err or "failed to write artifact file" end
  return true
end

function M.write_plan(plan, writer)
  if type(plan) ~= "table" or plan.schema ~= M.plan_schema then error("testing-discovery: malformed-plan: invalid plan") end
  local path = plan.plan_path or (plan.artifact_root .. "/" .. M.plan_filename)
  if path ~= plan.artifact_root .. "/" .. M.plan_filename then error("testing-discovery: malformed-plan: invalid plan path") end
  local write = writer or write_file
  return write(path, json_encode(plan) .. "\n")
end

function M.read_plan(artifact_root, reader)
  if not safe_artifact_root(artifact_root) then error("testing-discovery: malformed-plan: unsafe artifact root") end
  local path = artifact_root .. "/" .. M.plan_filename
  local body
  if reader ~= nil then
    body = reader(path)
  else
    local file, err = io.open(path, "r")
    if not file then error(err or "testing-discovery: malformed-plan: missing plan") end
    body = file:read("*a")
    file:close()
  end
  local plan = json_decode(body or "")
  if type(plan) ~= "table" or plan.schema ~= M.plan_schema then error("testing-discovery: malformed-plan: invalid plan schema") end
  return plan
end

local function add_error(errors, id, message)
  table.insert(errors, { id = id, message = message })
end

function M.saga_conformance_errors()
  local errors = {}
  local ok, plan_or_err = pcall(M.plan, {
    schema = M.scope_schema,
    base_url = "http://localhost/app",
    allowed_origins = { "http://localhost" },
    sessions = {
      { role = "base", browser_harness_command = "true" },
      { role = "cdp", cdp_url = "http://127.0.0.1:9222" },
    },
    observations = {
      {
        id = "dashboard",
        name = "Dashboard",
        entry_url = "http://localhost/app/dashboard",
        visible_label = "Dashboard",
        discovery_source = "navigation",
        confidence = "high",
        evidence_pointer = ".testing/runs/discovery/evidence/dashboard",
      },
    },
    artifact_root = ".testing/runs/discovery",
    source_ref = { kind = "host-app", ref = "local-app" },
    trace_id = "trace-discovery",
    dedup_key = "dedup-discovery",
  })
  if not ok then
    add_error(errors, "testing-discovery.saga.plan", tostring(plan_or_err))
    return errors
  end
  local readiness = M.readiness_check(plan_or_err)
  if readiness.schema ~= "browser-readiness.check.v1" then add_error(errors, "testing-discovery.saga.readiness-schema", "invalid readiness schema") end
  local starts = M.module_starts(plan_or_err, { schema = "browser-readiness.result.v1", status = "ready", sessions = { { role = "base", status = "ready" } } })
  if #starts ~= 1 then add_error(errors, "testing-discovery.saga.module-count", "expected one module start") end
  if starts[1] ~= nil and starts[1].schema ~= "testing-pipeline.module-start.v1" then add_error(errors, "testing-discovery.saga.module-schema", "invalid module start schema") end
  return errors
end

return M
