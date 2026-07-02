local M = {}

local function bounded_string(value, limit)
  return type(value) == "string" and value ~= "" and #value <= (limit or 512)
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

local function copy_list(value)
  if value == nil then return nil end
  if not dense_list(value) then
    error("generic-host: malformed-profile: expected a dense list")
  end
  local copy = {}
  for _, item in ipairs(value) do
    if type(item) == "table" then
      local item_copy = {}
      for key, child in pairs(item) do
        item_copy[key] = child
      end
      table.insert(copy, item_copy)
    else
      table.insert(copy, item)
    end
  end
  return copy
end

local function safe_artifact_root(value)
  return bounded_string(value, 4096)
    and value:sub(1, 14) == ".testing/runs/"
    and value:find("..", 1, true) == nil
    and value:find("\0", 1, true) == nil
end

local function validate_string_list(value, name)
  if value == nil then return end
  if not dense_list(value) or #value == 0 then
    error("generic-host: malformed-profile: " .. name .. " must be a non-empty dense list")
  end
  for _, item in ipairs(value) do
    if not bounded_string(item, 512) then
      error("generic-host: malformed-profile: " .. name .. " items must be bounded strings")
    end
  end
end

function M.validate(profile)
  if type(profile) ~= "table" then
    error("generic-host: malformed-profile: profile must be a table")
  end
  if not bounded_string(profile.module, 256) then
    error("generic-host: malformed-profile: module is required")
  end
  if not bounded_string(profile.base_url, 512) then
    error("generic-host: malformed-profile: base_url is required")
  end
  if not dense_list(profile.allowed_origins) or #profile.allowed_origins == 0 then
    error("generic-host: malformed-profile: allowed_origins is required")
  end
  if not dense_list(profile.sessions) or #profile.sessions == 0 then
    error("generic-host: malformed-profile: sessions is required")
  end
  validate_string_list(profile.allowed_origins, "allowed_origins")
  validate_string_list(profile.native_argv, "native_argv")
  if not safe_artifact_root(profile.artifact_root) then
    error("generic-host: malformed-profile: artifact_root must be a safe .testing/runs/... path")
  end
  return profile
end

function M.readiness_check(profile)
  profile = M.validate(profile)
  return {
    queue = "browser-readiness.browser_readiness_check",
    payload = {
      schema = "browser-readiness.check.v1",
      base_url = profile.base_url,
      allowed_origins = copy_list(profile.allowed_origins),
      sessions = copy_list(profile.sessions),
      request_context = {
        no_browser = profile.no_browser,
        dry_run = profile.dry_run,
        native_argv = copy_list(profile.native_argv),
      },
      source_ref = { kind = "host-module", ref = profile.module },
    },
    source_ref = { kind = "external", reference = profile.module },
  }
end

function M.module_start(profile, readiness)
  profile = M.validate(profile)
  return {
    queue = "testing-pipeline.module_start",
    payload = {
      schema = "testing-pipeline.module-start.v1",
      module = profile.module,
      backend = "fkst-native",
      preflight_result = readiness,
      artifact_root = profile.artifact_root,
      source_ref = { kind = "host-module", ref = profile.module },
      trace_id = profile.trace_id,
      dedup_key = profile.dedup_key,
    },
    source_ref = { kind = "external", reference = profile.module },
  }
end

return M
