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
  for i = 1, count do
    if value[i] == nil then return false end
  end
  return true, count
end

local function safe_artifact_root(value)
  return type(value) == "string"
    and value:match("^%.testing/runs/[^%z]+$") ~= nil
    and value:find("..", 1, true) == nil
end

local function local_url(value)
  return bounded_string(value)
    and (value:match("^https?://localhost[:/%?]") ~= nil
      or value:match("^https?://127%.0%.0%.1[:/%?]") ~= nil
      or value:match("^https?://%[::1%][:/%?]") ~= nil)
end

local function targets_legacy_cli(argv)
  for _, value in ipairs(argv or {}) do
    local text = tostring(value)
    if text:find("agentic_testing", 1, true) ~= nil
      or text:find("scripts/fkst-host-module-ui-check", 1, true) ~= nil
      or text == "fkst-host-module-ui-check"
      or text:match("/fkst%-host%-module%-ui%-check$") ~= nil then
      return true
    end
  end
  return false
end

local function valid_session(session)
  if type(session) ~= "table" then return false end
  if not bounded_string(session.role) then return false end
  return bounded_string(session.browser_harness_command)
    or bounded_string(session.browser_harness_command_env)
    or bounded_string(session.cdp_endpoint_env)
    or local_url(session.cdp_url)
end

local function validate_sessions(sessions)
  local ok, count = dense_list(sessions)
  if not ok or count == 0 then error("generic-host: sessions must be a non-empty dense list") end
  for _, session in ipairs(sessions) do
    if not valid_session(session) then error("generic-host: invalid browser readiness session") end
  end
end

local function validate_argv(argv)
  local ok, count = dense_list(argv)
  if not ok or count == 0 then error("generic-host: native_argv must be a non-empty dense list") end
  for _, item in ipairs(argv) do
    if not bounded_string(item) then error("generic-host: native_argv items must be bounded strings") end
  end
  if targets_legacy_cli(argv) then error("generic-host: native_argv must not target the legacy agentic-testing host runner") end
end

local function validate_profile(profile)
  if type(profile) ~= "table" then error("generic-host: native browser module profile must be a table") end
  if not bounded_string(profile.module) then error("generic-host: module must be a bounded string") end
  if not local_url(profile.base_url) then error("generic-host: base_url must be a local http URL") end
  if not bounded_string(profile.e2e_driver) then error("generic-host: e2e_driver must be a bounded string") end
  validate_sessions(profile.sessions)
  validate_argv(profile.native_argv)
  if not safe_artifact_root(profile.artifact_root) then error("generic-host: artifact_root must be under .testing/runs/") end
  if not bounded_string(profile.trace_id) then error("generic-host: trace_id must be a bounded string") end
  if not bounded_string(profile.dedup_key) then error("generic-host: dedup_key must be a bounded string") end
  return profile
end

local function validate_platform(platform)
  if type(platform) ~= "table" then error("generic-host: platform profile must be a table") end
  if not bounded_string(platform.platform) then error("generic-host: platform must be a bounded string") end
  if not safe_artifact_root(platform.artifact_root) then error("generic-host: platform artifact_root must be under .testing/runs/") end
  if not bounded_string(platform.trace_id) then error("generic-host: platform trace_id must be a bounded string") end
  if not bounded_string(platform.dedup_key) then error("generic-host: platform dedup_key must be a bounded string") end
  return platform
end

local function source_ref(profile)
  if profile.source_ref ~= nil then return profile.source_ref end
  return { kind = "host-module", ref = profile.module }
end

local function platform_source_ref(platform)
  if platform.source_ref ~= nil then return platform.source_ref end
  return { kind = "host-platform", ref = platform.platform }
end

M.modules = {
  validate_profile({
    module = "module-a",
    base_url = "http://localhost:4173/module-a",
    e2e_driver = "generic-ai-browser-driver",
    sessions = {
      { role = "default", browser_harness_command = "true" },
    },
    native_argv = { "generic-ai-browser-check", "--module", "module-a", "--base-url", "http://localhost:4173/module-a" },
    artifact_root = ".testing/runs/generic-host-browser-module-a",
    trace_id = "trace-generic-host-browser-module-a",
    dedup_key = "generic-host-browser-module-a",
  }),
  validate_profile({
    module = "module-b",
    base_url = "http://127.0.0.1:4174/module-b",
    e2e_driver = "generic-ai-browser-driver",
    sessions = {
      { role = "default", browser_harness_command = "true" },
    },
    native_argv = { "generic-ai-browser-check", "--module", "module-b", "--base-url", "http://127.0.0.1:4174/module-b" },
    artifact_root = ".testing/runs/generic-host-browser-module-b",
    trace_id = "trace-generic-host-browser-module-b",
    dedup_key = "generic-host-browser-module-b",
  }),
}

M.platform = validate_platform({
  platform = "generic-host-browser-platform",
  artifact_root = ".testing/runs/generic-host-browser-platform",
  trace_id = "trace-generic-host-browser-platform",
  dedup_key = "generic-host-browser-platform",
})

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
        native_argv = profile.native_argv,
      },
      source_ref = source_ref(profile),
    },
    source_ref = { kind = "external", reference = profile.module },
  }
end

function M.module_start(profile, readiness)
  profile = validate_profile(profile)
  return {
    queue = "module-testing-pipeline.module_start",
    payload = {
      schema = "module-testing-pipeline.module-start.v1",
      module = profile.module,
      backend = "fkst-native",
      e2e_driver = profile.e2e_driver,
      no_browser = false,
      dry_run = false,
      preflight_result = readiness,
      artifact_root = profile.artifact_root,
      source_ref = source_ref(profile),
      trace_id = profile.trace_id,
      dedup_key = profile.dedup_key,
    },
    source_ref = { kind = "external", reference = profile.module },
  }
end

function M.platform_aggregate(module_results)
  local ok = dense_list(module_results)
  if not ok then error("generic-host: module_results must be a dense list") end
  local platform = validate_platform(M.platform)
  return {
    schema = "platform-test-loop.aggregate.v1",
    platform = platform.platform,
    module_results = module_results,
    artifact_root = platform.artifact_root,
    source_ref = platform_source_ref(platform),
    trace_id = platform.trace_id,
    dedup_key = platform.dedup_key,
  }
end

return M
