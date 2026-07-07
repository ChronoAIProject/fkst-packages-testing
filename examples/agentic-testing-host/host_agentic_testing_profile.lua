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
    if tostring(value):find("agentic_testing.cli", 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function validate_argv(argv)
  local ok, count = dense_list(argv)
  if not ok or count == 0 then error("agentic-testing-host: native_argv must be a non-empty dense list") end
  for _, item in ipairs(argv) do
    if not bounded_string(item) then error("agentic-testing-host: native_argv items must be bounded strings") end
  end
  if targets_legacy_cli(argv) then error("agentic-testing-host: native_argv must not target agentic_testing.cli") end
end

local function validate_session(session)
  if type(session) ~= "table" then return false end
  if not bounded_string(session.role) then return false end
  return bounded_string(session.browser_harness_command)
    or bounded_string(session.browser_harness_command_env)
    or bounded_string(session.cdp_endpoint_env)
    or local_url(session.cdp_url)
end

local function validate_sessions(sessions)
  local ok, count = dense_list(sessions)
  if not ok or count == 0 then error("agentic-testing-host: sessions must be a non-empty dense list") end
  for _, session in ipairs(sessions) do
    if not validate_session(session) then error("agentic-testing-host: invalid browser readiness session") end
  end
end

local function validate_profile(profile)
  if type(profile) ~= "table" then error("agentic-testing-host: module profile must be a table") end
  if not bounded_string(profile.module) then error("agentic-testing-host: module must be a bounded string") end
  if not local_url(profile.base_url) then error("agentic-testing-host: base_url must be a local http URL") end
  if not bounded_string(profile.config_path) then error("agentic-testing-host: config_path must be a bounded string") end
  if not bounded_string(profile.wrapper) then error("agentic-testing-host: wrapper must be a bounded string") end
  if not bounded_string(profile.e2e_driver) then error("agentic-testing-host: e2e_driver must be a bounded string") end
  validate_sessions(profile.sessions)
  validate_argv(profile.native_argv)
  if not safe_artifact_root(profile.artifact_root) then error("agentic-testing-host: artifact_root must be under .testing/runs/") end
  if not bounded_string(profile.trace_id) then error("agentic-testing-host: trace_id must be a bounded string") end
  if not bounded_string(profile.dedup_key) then error("agentic-testing-host: dedup_key must be a bounded string") end
  return profile
end

local function validate_platform(platform)
  if type(platform) ~= "table" then error("agentic-testing-host: platform profile must be a table") end
  if not bounded_string(platform.platform) then error("agentic-testing-host: platform must be a bounded string") end
  if not safe_artifact_root(platform.artifact_root) then error("agentic-testing-host: platform artifact_root must be under .testing/runs/") end
  if not bounded_string(platform.trace_id) then error("agentic-testing-host: platform trace_id must be a bounded string") end
  if not bounded_string(platform.dedup_key) then error("agentic-testing-host: platform dedup_key must be a bounded string") end
  return platform
end

local function source_ref(profile)
  return { kind = "host-module", ref = profile.module }
end

local function platform_source_ref(platform)
  return { kind = "host-platform", ref = platform.platform }
end

M.host_config = {
  project = {
    id = "sample_project",
    name = "Sample Project",
    artifact_namespace = "sample-project",
    bug_repo = "ChronoAIProject/sample-project",
    loop_issue_repo = "ChronoAIProject/agentic-testing",
  },
  module_test_loop = {
    local_runtime = {
      repo_root_env = "PROJECT_LOCAL_REPO_ROOT",
      base_url_env = "PROJECT_LOCAL_BASE_URL",
      web_base_url_env = "PROJECT_WEB_BASE_URL",
      browser_harness_command_env = "PROJECT_BROWSER_HARNESS_COMMAND",
      base_url_default = "http://localhost:8080/",
      browser_harness_command_default = "true",
    },
    config_path = "config/generic-exploratory-functional.yaml",
    wrapper = "scripts/fkst-host-module-ui-check",
    e2e_driver = "browser_harness",
    modules = {
      {
        id = "project_public_navigation",
        name = "Public navigation",
        test_mode = "http_smoke",
        surface_routes = { "/" },
      },
    },
  },
  platform_test_loop = {
    platform = "sample-project",
    artifact_root = ".testing/runs/agentic-testing-host-platform",
    trace_id = "trace-agentic-testing-host-platform",
    dedup_key = "agentic-testing-host-platform",
  },
}

local function module_profile(config, module_config)
  local project = config.project or {}
  local loop = config.module_test_loop or {}
  local runtime = loop.local_runtime or {}
  local module_id = tostring(module_config.id or "")
  local base_url = tostring(module_config.base_url or runtime.web_base_url_default or runtime.base_url_default or "")
  local wrapper = tostring(module_config.wrapper or loop.wrapper or "")
  local config_path = tostring(module_config.config_path or loop.config_path or "")
  local artifact_namespace = tostring(project.artifact_namespace or project.id or "agentic-testing-host")
  return validate_profile({
    module = module_id,
    module_name = tostring(module_config.name or module_id),
    base_url = base_url,
    config_path = config_path,
    wrapper = wrapper,
    e2e_driver = tostring(module_config.e2e_driver or loop.e2e_driver or "browser_harness"),
    sessions = {
      {
        role = "default",
        browser_harness_command = tostring(runtime.browser_harness_command_default or "true"),
      },
    },
    native_argv = {
      wrapper,
      "--config",
      config_path,
      "--module",
      module_id,
      "--base-url",
      base_url,
    },
    artifact_root = ".testing/runs/" .. artifact_namespace .. "-" .. module_id,
    trace_id = "trace-" .. artifact_namespace .. "-" .. module_id,
    dedup_key = artifact_namespace .. "-" .. module_id,
  })
end

function M.modules(config)
  config = config or M.host_config
  local loop = config.module_test_loop or {}
  local modules = loop.modules or {}
  local ok, count = dense_list(modules)
  if not ok or count == 0 then error("agentic-testing-host: config modules must be a non-empty dense list") end
  local profiles = {}
  for _, module_config in ipairs(modules) do
    table.insert(profiles, module_profile(config, module_config))
  end
  return profiles
end

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
    queue = "testing-pipeline.module_start",
    payload = {
      schema = "testing-pipeline.module-start.v1",
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

function M.platform_aggregate(module_results, config)
  local ok = dense_list(module_results)
  if not ok then error("agentic-testing-host: module_results must be a dense list") end
  config = config or M.host_config
  local platform = validate_platform(config.platform_test_loop or {})
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
