local M = {}

local function adapter(mode)
  return {
    name = "fkst-native",
    mode = mode,
  }
end

local function preflight_status(payload)
  local value = payload.preflight_result
  if type(value) ~= "table" then return nil end
  return tostring(value.status or "")
end

local function command_probe(payload)
  if type(payload.probe) == "table" and type(payload.probe.http_ready) == "function" then
    return payload.probe.http_ready
  end
  return function(url, quote)
    local ok = os.execute("curl -fsS --max-time 5 " .. quote(url) .. " >/dev/null 2>&1")
    return ok == true or ok == 0
  end
end

local function shell_argv(argv, quote)
  local parts = {}
  for _, value in ipairs(argv) do
    table.insert(parts, quote(value))
  end
  return table.concat(parts, " ")
end

local function native_exec(payload, context, exec)
  if type(payload.probe) == "table" and type(payload.probe.run_argv) == "function" then
    return payload.probe.run_argv(payload.native_argv)
  end
  local run = exec or exec_sync
  if type(run) ~= "function" then
    return { exit_code = -1, stderr = "fkst-native exec is unavailable" }
  end
  local ok, out = pcall(run, shell_argv(payload.native_argv, context.quote))
  if not ok then
    return { exit_code = -1, stderr = tostring(out) }
  end
  return out
end

local function targets_legacy_cli(argv)
  for _, value in ipairs(argv or {}) do
    if tostring(value):find("agentic_testing.cli", 1, true) ~= nil then
      return true
    end
  end
  return false
end

local function safe_target(url)
  if type(url) ~= "string" then return nil end
  local text = url:gsub("[#?].*$", "")
  if #text > 512 then text = text:sub(1, 512) end
  return text
end

local function origin_of(url)
  if type(url) ~= "string" then return nil end
  return url:match("^(https?://[^/?#]+)")
end

local function local_http_url(url)
  if type(url) ~= "string" then return false end
  local host = url:match("^https?://([^/:?#]+)")
  return host == "localhost" or host == "127.0.0.1" or host == "::1"
end

local function origin_allowed(base_url, allowed_origins)
  local origin = origin_of(base_url)
  if origin == nil or type(allowed_origins) ~= "table" then return false end
  for _, allowed in ipairs(allowed_origins) do
    if allowed == origin then return true end
  end
  return false
end

local function safe_label(value, fallback)
  local text = tostring(value or fallback or "unknown")
  if text == "" then text = fallback or "unknown" end
  text = text:gsub("[^%w%._%-%/#]", "-")
  if #text > 80 then text = text:sub(1, 80) end
  return text
end

local function module_ui_loop_summary(payload, result, classification)
  local root = result.artifact_root
  local ui_loop = payload.ui_loop or {}
  local summary = {
    schema = "testing-runner.module-ui-loop-summary.v1",
    module = payload.module,
    status = result.status,
    classification = classification,
    mode = "contract-envelope",
    artifact_root = root,
    metadata_path = root .. "/metadata.json",
  }
  if type(ui_loop.gap_ref) == "string" then summary.gap_ref = ui_loop.gap_ref end
  if type(ui_loop.backlog_ref) == "string" then summary.backlog_ref = ui_loop.backlog_ref end
  return summary
end

local function readiness_summary(preflight)
  if type(preflight) ~= "table" then return nil end
  local summary = { status = safe_label(preflight.status, "unknown") }
  local sessions = {}
  if type(preflight.sessions) == "table" then
    for _, session in ipairs(preflight.sessions) do
      if type(session) == "table" then
        table.insert(sessions, {
          role = safe_label(session.role, "unknown"),
          status = safe_label(session.status, "unknown"),
        })
        if #sessions >= 16 then break end
      end
    end
  end
  if #sessions > 0 then summary.sessions = sessions end
  return summary
end

local function json_escape(value)
  local text = tostring(value or "")
  text = text:gsub("\\", "\\\\")
  text = text:gsub('"', '\\"')
  text = text:gsub("\n", "\\n")
  text = text:gsub("\r", "\\r")
  text = text:gsub("\t", "\\t")
  return text
end

local function is_array(value)
  local count, max_index = 0, 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or math.floor(key) ~= key then
      return false
    end
    count = count + 1
    if key > max_index then max_index = key end
  end
  return count == max_index
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
    for _, item in ipairs(value) do
      table.insert(parts, json_encode(item))
    end
    return "[" .. table.concat(parts, ",") .. "]"
  end

  local keys = {}
  for key, _ in pairs(value) do
    table.insert(keys, tostring(key))
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    table.insert(parts, '"' .. json_escape(key) .. '":' .. json_encode(value[key]))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end
M.json_encode = json_encode

local function safe_artifact_root(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  if path:sub(1, 14) ~= ".testing/runs/" then
    return false
  end
  if path:find("..", 1, true) ~= nil or path:find("\0", 1, true) ~= nil then
    return false
  end
  return true
end
M.safe_artifact_root = safe_artifact_root

local function write_file(path, body, quote)
  local dir = path:match("^(.*)/[^/]+$")
  if not dir or dir == "" then
    return nil, "missing artifact directory"
  end
  local ok = os.execute("mkdir -p " .. quote(dir))
  if ok ~= true and ok ~= 0 then
    return nil, "failed to create artifact directory"
  end
  local file, err = io.open(path, "w")
  if not file then
    return nil, err or "failed to open artifact file"
  end
  local wrote, write_err = file:write(body)
  file:close()
  if not wrote then
    return nil, write_err or "failed to write artifact file"
  end
  return true
end

local function metadata_for(result)
  local metadata = {
    schema = "testing-runner.native-metadata.v1",
    job = result.job,
    status = result.status,
    artifact_root = result.artifact_root,
    source_ref = result.source_ref,
    trace_id = result.trace_id,
    dedup_key = result.dedup_key,
    adapter = result.adapter,
  }
  if result.native_summary ~= nil then
    metadata.native_summary = result.native_summary
  end
  return metadata
end

local function write_metadata(result, payload, context)
  if not safe_artifact_root(result.artifact_root) then
    return nil, "unsafe artifact_root for fkst-native metadata"
  end
  local writer = payload.artifact_writer
  if writer == nil then
    writer = function(path, body)
      return write_file(path, body, context.quote)
    end
  end
  local body = json_encode(metadata_for(result)) .. "\n"
  return writer(result.artifact_root .. "/metadata.json", body)
end

local function with_metadata(result, payload, context)
  local ok, err = write_metadata(result, payload, context)
  if ok then
    return result
  end
  return context.result_payload("blocked", {
    adapter = result.adapter,
    stderr = "fkst-native artifact write failed: " .. tostring(err),
  })
end

function M.run(job, payload, context, _exec)
  local readiness = preflight_status(payload)
  if readiness ~= nil and readiness ~= "ready" then
    return with_metadata(context.result_payload("blocked", {
      adapter = adapter("readiness-blocked"),
      stderr = "fkst-native preflight is " .. readiness,
    }), payload, context)
  end
  if payload.dry_run ~= false then
    return with_metadata(context.result_payload("planned", { adapter = adapter("planning-envelope") }), payload, context)
  end
  if job == "module" and payload.ui_loop ~= nil then
    if targets_legacy_cli(payload.native_argv) then
      return with_metadata(context.result_payload("blocked", {
        adapter = adapter("legacy-cli-blocked"),
        stderr = "fkst-native native_argv must not target agentic_testing.cli",
      }), payload, context)
    end
    local ui_loop = payload.ui_loop
    if not local_http_url(ui_loop.base_url) or not origin_allowed(ui_loop.base_url, ui_loop.allowed_origins) then
      local result = context.result_payload("blocked", {
        adapter = adapter("module-ui-loop-blocked"),
        stderr = "fkst-native module ui loop blocked unsafe runtime input",
      })
      result.native_summary = module_ui_loop_summary(payload, result, "unsafe-runtime-input")
      return with_metadata(result, payload, context)
    end
    local result = context.result_payload("degraded", {
      adapter = adapter("module-ui-loop-contract"),
      stderr = "fkst-native module ui loop contract accepted; browser exploration is not implemented in this slice",
    })
    result.native_summary = module_ui_loop_summary(payload, result, "browser-exploration-deferred")
    return with_metadata(result, payload, context)
  end
  if job == "online_regression" and payload.no_browser == true and payload.heartbeat_url ~= nil then
    local ok = command_probe(payload)(payload.heartbeat_url, context.quote)
    local result = context.result_payload(ok and "passed" or "failed", {
      adapter = adapter("online-heartbeat"),
      exit_code = ok and 0 or 1,
      stderr = ok and "" or "fkst-native online heartbeat failed",
    })
    result.native_summary = {
      schema = "testing-runner.online-heartbeat-summary.v1",
      target = safe_target(payload.heartbeat_url),
      status = result.status,
      mode = "no-browser-http",
    }
    return with_metadata(result, payload, context)
  end
  if job == "module" and payload.no_browser == true and payload.native_argv ~= nil then
    if targets_legacy_cli(payload.native_argv) then
      return with_metadata(context.result_payload("blocked", {
        adapter = adapter("legacy-cli-blocked"),
        stderr = "fkst-native native_argv must not target agentic_testing.cli",
      }), payload, context)
    end
    local out = native_exec(payload, context, _exec)
    local code = type(out) == "table" and tonumber(out.exit_code) or nil
    local status = code == 0 and "passed" or "failed"
    local result = context.result_payload(status, {
      adapter = adapter("module-no-browser"),
      exit_code = code or -1,
      stderr = type(out) == "table" and out.stderr or "",
    })
    result.native_summary = {
      schema = "testing-runner.module-no-browser-summary.v1",
      module = payload.module,
      status = result.status,
      mode = "argv",
    }
    return with_metadata(result, payload, context)
  end
  if payload.no_browser == true then
    return with_metadata(context.result_payload("planned", { adapter = adapter("no-browser-plan") }), payload, context)
  end
  if job == "module" and payload.e2e_driver ~= nil then
    if payload.native_argv == nil then
      local result = context.result_payload("planned", { adapter = adapter("browser-driver-plan") })
      result.native_summary = {
        schema = "testing-runner.browser-driver-summary.v1",
        module = payload.module,
        driver = payload.e2e_driver,
        status = result.status,
        mode = "readiness-gated-plan",
        readiness = readiness_summary(payload.preflight_result),
      }
      return with_metadata(result, payload, context)
    end
    if targets_legacy_cli(payload.native_argv) then
      return with_metadata(context.result_payload("blocked", {
        adapter = adapter("legacy-cli-blocked"),
        stderr = "fkst-native native_argv must not target agentic_testing.cli",
      }), payload, context)
    end
    local out = native_exec(payload, context, _exec)
    local code = type(out) == "table" and tonumber(out.exit_code) or nil
    local status = code == 0 and "passed" or "failed"
    local result = context.result_payload(status, {
      adapter = adapter("browser-driver"),
      exit_code = code or -1,
      stderr = type(out) == "table" and out.stderr or "",
    })
    result.native_summary = {
      schema = "testing-runner.browser-driver-summary.v1",
      module = payload.module,
      driver = payload.e2e_driver,
      status = result.status,
      mode = "argv",
      readiness = readiness_summary(payload.preflight_result),
    }
    return with_metadata(result, payload, context)
  end
  return with_metadata(context.result_payload("blocked", {
    adapter = adapter("capability-gap"),
    stderr = "fkst-native live execution for " .. tostring(job) .. " is not implemented beyond the planning envelope",
  }), payload, context)
end

return M
