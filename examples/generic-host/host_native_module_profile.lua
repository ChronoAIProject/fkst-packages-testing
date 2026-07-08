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

local function validate_profile(profile)
  if type(profile) ~= "table" then error("generic-host: native module profile must be a table") end
  if not bounded_string(profile.module) then error("generic-host: module must be a bounded string") end
  local ok, count = dense_list(profile.native_argv)
  if not ok or count == 0 then error("generic-host: native_argv must be a non-empty dense list") end
  for _, item in ipairs(profile.native_argv) do
    if not bounded_string(item) then error("generic-host: native_argv items must be bounded strings") end
  end
  if targets_legacy_cli(profile.native_argv) then error("generic-host: native_argv must not target the legacy agentic-testing host runner") end
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
    module = "module-a",
    native_argv = { "generic-module-a-check" },
    artifact_root = ".testing/runs/generic-host-module-a",
    trace_id = "trace-generic-host-module-a",
    dedup_key = "generic-host-module-a",
  }),
  validate_profile({
    module = "module-b",
    native_argv = { "generic-module-b-check", "--quick" },
    artifact_root = ".testing/runs/generic-host-module-b",
    trace_id = "trace-generic-host-module-b",
    dedup_key = "generic-host-module-b",
  }),
}

function M.readiness_check(profile)
  profile = validate_profile(profile)
  return {
    queue = "browser-readiness.browser_readiness_check",
    payload = {
      schema = "browser-readiness.check.v1",
      sessions = {
        { role = "default", browser_harness_command = "true" },
      },
      request_context = {
        no_browser = true,
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
      preflight_result = readiness,
      artifact_root = profile.artifact_root,
      source_ref = source_ref(profile),
      trace_id = profile.trace_id,
      dedup_key = profile.dedup_key,
    },
    source_ref = { kind = "external", reference = profile.module },
  }
end

return M
