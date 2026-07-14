local M = {}

local code_analysis = require("code_analysis.artifact")
local strings = require("contract.strings")

M.request_schema = "testing-runner.module-discovery.v1"
M.inventory_schema = "testing-runner.module-inventory.v1"
M.summary_schema = "testing-runner.module-inventory-summary.v1"

local max_string = 512
local max_id = 180
local max_modules = 64

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

local request_fields = {
  code_analysis = true,
  schema = true,
  observations = true,
  limitations = true,
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

local function has_no_control(value)
  return type(value) == "string" and value:find("[%z\1-\31]") == nil
end

local function bounded_field(value, limit)
  return strings.is_bounded_string(value, limit or max_string) and has_no_control(value)
end

local function dense_list(value)
  if type(value) ~= "table" then return false end
  local count, max_index = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return false end
    count = count + 1
    if key > max_index then max_index = key end
  end
  return count == max_index
end

local function origin_from_url(value)
  if not bounded_field(value, max_string) then return nil end
  local scheme, authority = value:match("^(https?)://([^/%?#]+)")
  if scheme == nil or authority == nil or authority == "" then return nil end
  if authority:find("%s") ~= nil or authority:find("\\", 1, true) ~= nil then return nil end
  if authority:find("@", 1, true) ~= nil then return nil end
  return scheme:lower() .. "://" .. authority:lower()
end
M.origin_from_url = origin_from_url

local function strip_url_detail(value)
  return tostring(value or ""):gsub("[#?].*$", "")
end

local function base_scope_from_url(value)
  if origin_from_url(value) == nil then return nil end
  return strip_url_detail(value)
end

local function within_base_scope(entry_url, base_scope)
  if not bounded_field(entry_url, max_string) or not bounded_field(base_scope, max_string) then return false end
  if base_scope:sub(-1) == "/" then
    return entry_url:sub(1, #base_scope) == base_scope
  end
  return entry_url == base_scope or entry_url:sub(1, #base_scope + 1) == base_scope .. "/"
end

local function route_from_url(value)
  local route = strip_url_detail(value):match("^https?://[^/%?#]+([^%?#]*)")
  if route == nil or route == "" then return "/" end
  return route
end

local function normalize_route(value)
  if not bounded_field(value, max_string) then return nil end
  if value:sub(1, 1) ~= "/" then return nil end
  return strip_url_detail(value)
end

local function configured_origins(ui_loop)
  local base_origin = origin_from_url(ui_loop.base_url)
  local origins, seen = {}, {}
  local function add(origin)
    if origin ~= nil and seen[origin] ~= true then
      table.insert(origins, origin)
      seen[origin] = true
    end
  end
  add(base_origin)
  for _, value in ipairs(ui_loop.allowed_origins or {}) do
    add(origin_from_url(value))
  end
  return origins, seen, base_origin
end

local function evidence_source(value)
  local source = value.discovery_source or value.source
  if not bounded_field(source, 80) or allowed_sources[source] ~= true then return nil end
  return source
end

local function safe_id(value, fallback)
  local id = strings.sanitize_key(value or fallback or "module", max_id):gsub("/", "-")
  if id == "" or id == "empty" then return "module" end
  return id
end

local function name_for(value, fallback)
  if bounded_field(value, max_string) then return value end
  if bounded_field(fallback, max_string) then return fallback end
  return "Module"
end

local function confidence_for(value)
  if allowed_confidence[value.confidence] == true then return value.confidence end
  local score = 0
  if bounded_field(value.visible_label, max_string) then score = score + 1 end
  if normalize_route(value.route) ~= nil then score = score + 1 end
  if bounded_field(value.evidence_pointer, max_string) then score = score + 1 end
  local source = evidence_source(value)
  if source == "accessibility" or source == "a11y-visible" then score = score + 1 end
  if score >= 3 then return "high" end
  if score >= 2 then return "medium" end
  return "low"
end

local function entry_url_for(value, base_origin)
  local explicit = strip_url_detail(value.entry_url)
  if origin_from_url(explicit) ~= nil then return explicit end
  local route = normalize_route(value.route)
  if route ~= nil and base_origin ~= nil then return base_origin .. route end
  return nil
end

local function module_from_observation(value, base_origin, base_scope, allowed_origin_map)
  if type(value) ~= "table" then return nil end
  local entry_url = entry_url_for(value, base_origin)
  if entry_url == nil then return nil end
  if not within_base_scope(entry_url, base_scope) then return nil end
  local origin = origin_from_url(entry_url)
  if allowed_origin_map[origin] ~= true then return nil end
  local source = evidence_source(value)
  if source == nil then return nil end
  if not bounded_field(value.evidence_pointer, max_string) then return nil end
  local route = normalize_route(value.route) or route_from_url(entry_url)
  local visible_label = bounded_field(value.visible_label, max_string) and value.visible_label or nil
  if visible_label == nil and route == nil then return nil end
  local id = safe_id(value.id, value.name or visible_label or route)
  local name = name_for(value.name, visible_label or id)
  return {
    id = id,
    name = name,
    entry_url = entry_url,
    visible_label = visible_label,
    route = route,
    discovery_source = source,
    confidence = confidence_for(value),
    evidence_pointer = value.evidence_pointer,
  }
end

local function validate_string_list(value, field, limit, max_items)
  if value == nil then return end
  if not dense_list(value) or #value > max_items then
    error("testing-runner: malformed-request: module_discovery." .. field .. " must be a bounded dense list")
  end
  for _, item in ipairs(value) do
    if not bounded_field(item, limit or max_string) then
      error("testing-runner: malformed-request: module_discovery." .. field .. " items must be bounded strings")
    end
  end
end

local function validate_observation(value)
  if type(value) ~= "table" then
    error("testing-runner: malformed-request: module_discovery.observations items must be tables")
  end
  for key, _ in pairs(value) do
    if observation_fields[key] ~= true then
      error("testing-runner: malformed-request: module_discovery.observations item has unsupported field")
    end
  end
  for key, item in pairs(value) do
    if key ~= "confidence" and key ~= "discovery_source" and key ~= "source" then
      if not bounded_field(item, key == "id" and max_id or max_string) then
        error("testing-runner: malformed-request: module_discovery." .. key .. " must be a bounded string")
      end
    end
  end
  if value.confidence ~= nil and allowed_confidence[value.confidence] ~= true then
    error("testing-runner: malformed-request: module_discovery.confidence is invalid")
  end
  if (value.source ~= nil and allowed_sources[value.source] ~= true)
    or (value.discovery_source ~= nil and allowed_sources[value.discovery_source] ~= true) then
    error("testing-runner: malformed-request: module_discovery.discovery_source is invalid")
  end
end

function M.validate_request(value)
  if type(value) ~= "table" then
    error("testing-runner: malformed-request: module_discovery must be a table")
  end
  for key, _ in pairs(value) do
    if request_fields[key] ~= true then
      error("testing-runner: malformed-request: module_discovery has unsupported field")
    end
  end
  if value.schema ~= M.request_schema then
    error("testing-runner: unknown-schema: expected " .. M.request_schema)
  end
  if value.observations ~= nil then
    if not dense_list(value.observations) or #value.observations > max_modules then
      error("testing-runner: malformed-request: module_discovery.observations must be a bounded dense list")
    end
    for _, observation in ipairs(value.observations) do
      validate_observation(observation)
    end
  end
  validate_string_list(value.limitations, "limitations", max_string, 16)
  if value.code_analysis ~= nil then code_analysis.validate_reference(value.code_analysis) end
  return value
end

local function limitations_for(request, rejected_count, module_count)
  local limitations = {
    "Inventory covers only modules visible to the current local session and accepted by the configured origin gate.",
    "Discovery uses bounded route, navigation, and accessibility-visible evidence supplied through the module discovery request.",
  }
  for _, item in ipairs(request.limitations or {}) do
    table.insert(limitations, item)
  end
  if rejected_count > 0 then
    table.insert(limitations, "Some observed entries were omitted because they were outside scope or lacked required evidence.")
  end
  if module_count == 0 then
    table.insert(limitations, "No modules were accepted by the discovery gate for this local session.")
  end
  return limitations
end

function M.inventory(request, ui_loop, artifact_root, opts)
  request = M.validate_request(request)
  opts = opts or {}
  ui_loop = ui_loop or {}
  local allowed_origins, allowed_origin_map, base_origin = configured_origins(ui_loop)
  local base_scope = base_scope_from_url(ui_loop.base_url)
  local modules, rejected_count = {}, 0
  local readiness = opts.readiness
  local degraded = readiness == nil or readiness.status ~= "ready"
  if degraded then
    rejected_count = #(request.observations or {})
  else
    for _, observation in ipairs(request.observations or {}) do
      local item = module_from_observation(observation, base_origin, base_scope, allowed_origin_map)
      if item ~= nil then
        table.insert(modules, item)
      else
        rejected_count = rejected_count + 1
      end
    end
  end
  local result = {
    schema = M.inventory_schema,
    artifact_kind = "module-inventory",
    discovery_status = (not degraded and #modules > 0) and "complete" or "degraded",
    artifact_root = artifact_root,
    base_url = strip_url_detail(ui_loop.base_url),
    allowed_origins = allowed_origins,
    modules = modules,
    module_count = #modules,
    limitations = limitations_for(request, rejected_count, #modules),
    coverage = "visible-session-only",
    readiness = readiness,
    provenance = {
      discovery_sources = { "route", "navigation", "accessibility", "browser", "browser-visible" },
      rejected_observation_count = rejected_count,
    },
  }
  if request.code_analysis ~= nil then result.code_analysis = code_analysis.copy_reference(request.code_analysis) end
  return result
end

function M.summary(inventory, artifact_root, module, status)
  return {
    schema = M.summary_schema,
    module = module,
    status = status,
    discovery_status = inventory.discovery_status,
    artifact_root = artifact_root,
    inventory_path = artifact_root .. "/module-inventory.json",
    module_count = inventory.module_count,
    coverage = inventory.coverage,
  }
end

return M
