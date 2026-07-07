local M = {}

local max_string = 512

local function bounded_string(value)
  return type(value) == "string" and value ~= "" and #value <= max_string
end

local function dense_list(value)
  if type(value) ~= "table" then return false end
  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
    if key > count then count = key end
  end
  for index = 1, count do
    if value[index] == nil then return false end
  end
  return true, count
end

local function safe_artifact_root(value)
  return bounded_string(value)
    and value:match("^%.testing/runs/[^%z]+$") ~= nil
    and value:find("..", 1, true) == nil
end

local function local_url(value)
  return bounded_string(value)
    and (value:match("^https?://localhost[:/%?]") ~= nil
      or value:match("^https?://127%.0%.0%.1[:/%?]") ~= nil
      or value:match("^https?://%[::1%][:/%?]") ~= nil)
end

local function origin_from_url(value)
  if not bounded_string(value) then return nil end
  local scheme, authority = value:match("^(https?)://([^/%?#]+)")
  if scheme == nil or authority == nil or authority == "" then return nil end
  if authority:find("%s") ~= nil or authority:find("\\", 1, true) ~= nil or authority:find("@", 1, true) ~= nil then return nil end
  return scheme:lower() .. "://" .. authority:lower()
end

local function base_scope(value)
  if origin_from_url(value) == nil then return nil end
  return tostring(value):gsub("[#?].*$", "")
end

local function within_base_scope(entry_url, base_url)
  local scope = base_scope(base_url)
  if scope == nil or not bounded_string(entry_url) then return false end
  local clean = entry_url:gsub("[#?].*$", "")
  if scope:sub(-1) == "/" then return clean:sub(1, #scope) == scope end
  return clean == scope or clean:sub(1, #scope + 1) == scope .. "/"
end

local function validate_allowed_origins(base_url, origins)
  local ok, count = dense_list(origins)
  if not ok or count == 0 or count > 16 then error("generic-host: allowed_origins must be a non-empty bounded dense list") end
  local base_origin = origin_from_url(base_url)
  local includes_base = false
  for _, origin in ipairs(origins) do
    if not local_url(origin) then error("generic-host: allowed_origins must contain local http origins") end
    if origin_from_url(origin) == base_origin then includes_base = true end
  end
  if not includes_base then error("generic-host: allowed_origins must include base_url origin") end
end

local function validate_sessions(sessions)
  local ok, count = dense_list(sessions)
  if not ok or count == 0 then error("generic-host: sessions must be a non-empty dense list") end
  for _, session in ipairs(sessions) do
    if type(session) ~= "table" or not bounded_string(session.role) then error("generic-host: invalid readiness session") end
    if not bounded_string(session.browser_harness_command)
      and not bounded_string(session.browser_harness_command_env)
      and not bounded_string(session.cdp_endpoint_env)
      and not local_url(session.cdp_url) then
      error("generic-host: invalid readiness session")
    end
  end
end

local function validate_observations(base_url, observations)
  local ok, count = dense_list(observations)
  if not ok or count == 0 or count > 64 then error("generic-host: observations must be a non-empty bounded dense list") end
  for _, item in ipairs(observations) do
    if type(item) ~= "table" then error("generic-host: observation must be a table") end
    if not bounded_string(item.id) or not bounded_string(item.name) then error("generic-host: observation id/name must be bounded strings") end
    if not within_base_scope(item.entry_url, base_url) then error("generic-host: observation entry_url must stay within base_url scope") end
    if not bounded_string(item.evidence_pointer) then error("generic-host: observation evidence_pointer must be a bounded string") end
  end
end

local function validate_cdp_execution(value)
  if type(value) ~= "table" then error("generic-host: cdp_execution must be a table") end
  if value.schema ~= "testing-runner.module-cdp-execution.v1" then error("generic-host: cdp_execution schema is invalid") end
  if type(value.step_budget) ~= "number" or value.step_budget < 1 or value.step_budget > 32 or value.step_budget % 1 ~= 0 then
    error("generic-host: cdp_execution.step_budget must be an integer from 1 to 32")
  end
  local ok, count = dense_list(value.case_priorities)
  if not ok or count == 0 or count > 3 then error("generic-host: cdp_execution.case_priorities must be a bounded dense list") end
  for _, priority in ipairs(value.case_priorities) do
    if priority ~= "P0" and priority ~= "P1" and priority ~= "P2" then error("generic-host: cdp_execution.case_priorities is invalid") end
  end
end

local function validate_profile(profile)
  if type(profile) ~= "table" then error("generic-host: native ui loop profile must be a table") end
  if not bounded_string(profile.module) then error("generic-host: module must be a bounded string") end
  if not local_url(profile.base_url) then error("generic-host: base_url must be a local http URL") end
  validate_allowed_origins(profile.base_url, profile.allowed_origins)
  validate_sessions(profile.sessions)
  validate_observations(profile.base_url, profile.observations)
  if profile.mutation_policy ~= nil and profile.mutation_policy ~= "read-only" and profile.mutation_policy ~= "dry-run" and profile.mutation_policy ~= "host-approved" then
    error("generic-host: mutation_policy is invalid")
  end
  validate_cdp_execution(profile.cdp_execution)
  if not safe_artifact_root(profile.artifact_root) then error("generic-host: artifact_root must be under .testing/runs/") end
  if not bounded_string(profile.trace_id) then error("generic-host: trace_id must be a bounded string") end
  if not bounded_string(profile.dedup_key) then error("generic-host: dedup_key must be a bounded string") end
  return profile
end

local function source_ref(profile)
  if profile.source_ref ~= nil then return profile.source_ref end
  return { kind = "host-module", ref = profile.module }
end

M.modules = {
  validate_profile({
    module = "catalog",
    base_url = "http://localhost:4173/catalog",
    allowed_origins = { "http://localhost:4173" },
    sessions = {
      { role = "base", browser_harness_command = "true" },
      { role = "cdp", cdp_url = "http://127.0.0.1:9222" },
    },
    observations = {
      {
        id = "catalog-list",
        name = "Catalog list",
        entry_url = "http://localhost:4173/catalog/list?token=redacted#state",
        visible_label = "Catalog list",
        discovery_source = "navigation",
        confidence = "high",
        evidence_pointer = ".testing/runs/generic-host-ui-loop/evidence/catalog-list",
      },
    },
    cdp_execution = {
      schema = "testing-runner.module-cdp-execution.v1",
      step_budget = 8,
      case_priorities = { "P0", "P1" },
    },
    mutation_policy = "read-only",
    artifact_root = ".testing/runs/generic-host-ui-loop",
    trace_id = "trace-generic-host-ui-loop",
    dedup_key = "generic-host-ui-loop",
  }),
}

function M.readiness_check(profile)
  profile = validate_profile(profile)
  return {
    queue = "browser-readiness.browser_readiness_check",
    payload = {
      schema = "browser-readiness.check.v1",
      base_url = profile.base_url,
      sessions = profile.sessions,
      request_context = {
        no_browser = false,
        dry_run = false,
      },
      source_ref = source_ref(profile),
    },
    source_ref = { kind = "external", reference = profile.module },
  }
end

function M.ready_result(profile)
  profile = validate_profile(profile)
  return {
    schema = "browser-readiness.result.v1",
    status = "ready",
    sessions = {
      { role = "base_url", status = "ready" },
      { role = "base", status = "ready" },
      { role = "cdp", status = "ready" },
    },
    source_ref = source_ref(profile),
    request_context = {
      no_browser = false,
      dry_run = false,
    },
  }
end

function M.module_start(profile, readiness)
  profile = validate_profile(profile)
  return {
    queue = "testing-pipeline.module_start",
    payload = {
      schema = "testing-pipeline.module-start.v1",
      module = profile.module,
      backend = "fkst-native",
      dry_run = false,
      preflight_result = readiness,
      ui_loop = {
        base_url = profile.base_url,
        allowed_origins = profile.allowed_origins,
        browser_readiness_ref = profile.artifact_root .. "/readiness.json",
        cdp_readiness_ref = "cdp-ready",
        mutation_policy = profile.mutation_policy or "read-only",
      },
      module_discovery = {
        schema = "testing-runner.module-discovery.v1",
        observations = profile.observations,
      },
      cdp_execution = profile.cdp_execution,
      artifact_root = profile.artifact_root,
      source_ref = source_ref(profile),
      trace_id = profile.trace_id,
      dedup_key = profile.dedup_key,
    },
    source_ref = { kind = "external", reference = profile.module },
  }
end

function M.validate(profile)
  return validate_profile(profile)
end

return M
