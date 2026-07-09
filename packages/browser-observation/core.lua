local M = {}

local strings = require("contract.strings")

M.manifest_schema = "browser-observation.observations.v1"
M.result_schema = "browser-observation.result.v1"
M.evidence_schema = "browser-observation.evidence.v1"

local max_string = 512
local max_id = 180
local max_observations = 64

local observe_fields = {
  artifact_root = true,
  base_url = true,
  dedup_key = true,
  observation_path = true,
  schema = true,
  source_ref = true,
  trace_id = true,
}

local result_fields = {
  artifact_root = true,
  base_url = true,
  dedup_key = true,
  observation_count = true,
  observation_path = true,
  schema = true,
  source_ref = true,
  status = true,
  trace_id = true,
}

local manifest_fields = {
  artifact_root = true,
  base_url = true,
  observation_count = true,
  observations = true,
  schema = true,
}

local observation_fields = {
  confidence = true,
  discovery_source = true,
  entry_url = true,
  evidence_pointer = true,
  id = true,
  name = true,
  route = true,
  visible_label = true,
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

local forbidden_terms = {
  "raw_dom",
  "screenshot_body",
  "model_transcript",
  "browser_storage",
  "localstorage",
  "sessionstorage",
  "cookie",
  "token",
  "password",
}

local function bounded_string(value, limit)
  return strings.is_bounded_string(value, limit or max_string) and value:find("[%z\1-\31]") == nil
end

local function dense_list(value)
  if type(value) ~= "table" then return false, 0 end
  local count, max_index = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then return false, 0 end
    count = count + 1
    if key > max_index then max_index = key end
  end
  return count == max_index, count
end

local function validate_fields(value, allowed, context)
  for key, _ in pairs(value or {}) do
    if allowed[key] ~= true then error(context .. " has unsupported field") end
  end
end

local function local_http_url(value)
  local authority = tostring(value or ""):match("^http://([^/%?#]+)")
  if authority == nil then return false end
  local bracketed = authority:match("^%[([^%]]+)%]")
  local host = bracketed or authority:match("^([^:]+)") or authority
  host = host:lower()
  return host == "localhost" or host == "127.0.0.1" or host == "::1"
end
M.local_http_url = local_http_url

local function contains_forbidden_term(value)
  local text = tostring(value or ""):lower()
  for _, term in ipairs(forbidden_terms) do
    if text:find(term, 1, true) ~= nil then return true end
  end
  return false
end
M.contains_forbidden_term = contains_forbidden_term

local function inspect_pointer_only(value, context)
  local kind = type(value)
  if kind == "string" then
    if contains_forbidden_term(value) then error(context .. " contains forbidden payload term") end
  elseif kind == "table" then
    for key, item in pairs(value) do
      inspect_pointer_only(key, context)
      inspect_pointer_only(item, context)
    end
  end
end

local function route_is_clean(value)
  return bounded_string(value, max_string)
    and value:sub(1, 1) == "/"
    and value:find("?", 1, true) == nil
    and value:find("#", 1, true) == nil
end

local function path_under_artifact_root(value, artifact_root)
  return bounded_string(value, max_string)
    and strings.is_path_safe_key(value, max_string)
    and value:sub(1, #artifact_root + 1) == artifact_root .. "/"
end

local function source_ref(value, artifact_root)
  if value == nil then return { kind = "browser-observation", ref = artifact_root } end
  if type(value) ~= "table" or not bounded_string(value.kind, 80) or not bounded_string(value.ref, max_string) then
    error("browser-observation: malformed-source-ref: source_ref must contain bounded kind and ref")
  end
  return { kind = value.kind, ref = value.ref }
end

function M.validate_observation(observation, artifact_root)
  if type(observation) ~= "table" then error("browser-observation: malformed-observation: observations items must be tables") end
  validate_fields(observation, observation_fields, "browser-observation: malformed-observation: observations item")
  if not bounded_string(observation.id, max_id) then error("browser-observation: malformed-observation: id is required") end
  if not bounded_string(observation.name, max_string) then error("browser-observation: malformed-observation: name is required") end
  if not bounded_string(observation.entry_url, max_string) or not local_http_url(observation.entry_url) then error("browser-observation: malformed-observation: entry_url must be local http") end
  if not route_is_clean(observation.route) then error("browser-observation: malformed-observation: route must be a clean local route") end
  if not bounded_string(observation.visible_label, max_string) then error("browser-observation: malformed-observation: visible_label is required") end
  if allowed_sources[observation.discovery_source] ~= true then error("browser-observation: malformed-observation: discovery_source is invalid") end
  if allowed_confidence[observation.confidence] ~= true then error("browser-observation: malformed-observation: confidence is invalid") end
  if not path_under_artifact_root(observation.evidence_pointer, artifact_root) then error("browser-observation: malformed-observation: evidence_pointer must be under artifact_root") end
  inspect_pointer_only(observation, "browser-observation: malformed-observation")
  return observation
end

function M.validate_manifest(manifest)
  if type(manifest) ~= "table" then error("browser-observation: malformed-manifest: manifest must be a table") end
  validate_fields(manifest, manifest_fields, "browser-observation: malformed-manifest")
  if not bounded_string(manifest.schema, max_string) then error("browser-observation: malformed-manifest: schema is required") end
  if not bounded_string(manifest.base_url, max_string) or not local_http_url(manifest.base_url) then error("browser-observation: malformed-manifest: base_url must be local http") end
  if not strings.is_artifact_root(manifest.artifact_root) then error("browser-observation: malformed-manifest: artifact_root must be under .testing/runs") end
  local ok, count = dense_list(manifest.observations)
  if not ok or count > max_observations then error("browser-observation: malformed-manifest: observations must be a bounded dense list") end
  if type(manifest.observation_count) ~= "number" or manifest.observation_count ~= count then error("browser-observation: malformed-manifest: observation_count must match observations") end
  for _, observation in ipairs(manifest.observations) do
    M.validate_observation(observation, manifest.artifact_root)
  end
  inspect_pointer_only(manifest, "browser-observation: malformed-manifest")
  return manifest
end

function M.limit_observations(observations, limit)
  local ok, count = dense_list(observations)
  if not ok then error("browser-observation: malformed-observations: observations must be dense") end
  local selected = {}
  local max_count = limit or max_observations
  for index = 1, math.min(count, max_count) do
    selected[index] = observations[index]
  end
  return selected
end

function M.result(payload, read_file)
  if type(payload) ~= "table" then error("browser-observation: malformed-request: payload must be a table") end
  validate_fields(payload, observe_fields, "browser-observation: malformed-request")
  if payload.schema ~= "browser-observation.observe.v1" then error("browser-observation: unknown-schema: expected browser-observation.observe.v1") end
  if not bounded_string(payload.base_url, max_string) or not local_http_url(payload.base_url) then error("browser-observation: malformed-request: base_url must be local http") end
  if not strings.is_artifact_root(payload.artifact_root) then error("browser-observation: malformed-request: artifact_root must be under .testing/runs") end
  local observation_path = payload.observation_path or (payload.artifact_root .. "/observer/observations.json")
  if not path_under_artifact_root(observation_path, payload.artifact_root) then error("browser-observation: malformed-request: observation_path must be under artifact_root") end
  local status = "blocked"
  local count = 0
  if read_file ~= nil then
    local body = read_file(observation_path)
    if bounded_string(body, 65536) and body:find('"observations"', 1, true) ~= nil then
      status = "passed"
      local observed_count = tonumber(body:match('"observation_count"%s*:%s*(%d+)'))
      if observed_count ~= nil and observed_count >= 0 and observed_count <= max_observations then
        count = observed_count
      end
    end
  end
  return {
    schema = M.result_schema,
    status = status,
    base_url = payload.base_url,
    artifact_root = payload.artifact_root,
    observation_path = observation_path,
    observation_count = count,
    source_ref = source_ref(payload.source_ref, payload.artifact_root),
    trace_id = payload.trace_id,
    dedup_key = payload.dedup_key,
  }
end

function M.validate_result(result)
  if type(result) ~= "table" then error("browser-observation: malformed-result: result must be a table") end
  validate_fields(result, result_fields, "browser-observation: malformed-result")
  if result.schema ~= M.result_schema then error("browser-observation: unknown-result-schema: expected browser-observation.result.v1") end
  if result.status ~= "passed" and result.status ~= "blocked" and result.status ~= "degraded" then error("browser-observation: malformed-result: status is invalid") end
  if not bounded_string(result.base_url, max_string) or not local_http_url(result.base_url) then error("browser-observation: malformed-result: base_url must be local http") end
  if not strings.is_artifact_root(result.artifact_root) then error("browser-observation: malformed-result: artifact_root must be under .testing/runs") end
  if not path_under_artifact_root(result.observation_path, result.artifact_root) then error("browser-observation: malformed-result: observation_path must be under artifact_root") end
  if type(result.observation_count) ~= "number" or result.observation_count < 0 or result.observation_count > max_observations then error("browser-observation: malformed-result: observation_count is invalid") end
  source_ref(result.source_ref, result.artifact_root)
  inspect_pointer_only(result, "browser-observation: malformed-result")
  return result
end

return M
