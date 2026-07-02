local M = {}

local testing_contract = require("contract.testing")

local max_evidence_records = 64
local max_evidence_string = 1024

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
  text = text:gsub("[%z\1-\31]", "")
  if #text > 512 then text = text:sub(1, 512) end
  return text
end

local function safe_label(value, fallback)
  local text = tostring(value or fallback or "unknown")
  if text == "" then text = fallback or "unknown" end
  text = text:gsub("[^%w%._%-%/#]", "-")
  if #text > 80 then text = text:sub(1, 80) end
  return text
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

local function safe_evidence_text(value)
  if type(value) ~= "string" and type(value) ~= "number" and type(value) ~= "boolean" then
    return nil
  end
  local text = tostring(value or "")
  text = text:gsub("[%z\1-\31]", " ")
  if text == "" then return nil end
  if #text > max_evidence_string then text = text:sub(1, max_evidence_string) end
  return text
end

local function safe_artifact_path(value, artifact_root)
  if type(value) ~= "string" or value == "" or #value > 4096 then return nil end
  if value:sub(1, 1) == "/" or value:find("\\", 1, true) ~= nil or value:find("%s") ~= nil then return nil end
  if value:find("[^%w%._%-%/#]", 1) ~= nil then return nil end
  for segment in value:gmatch("[^/]+") do
    if segment == "." or segment == ".." then return nil end
  end
  if value:sub(1, #artifact_root + 1) == artifact_root .. "/" then return value end
  if value:sub(1, 9) == "evidence/" or value:sub(1, 12) == "screenshots/" or value:sub(1, 4) == "dom/" then
    return artifact_root .. "/" .. value
  end
  return nil
end

local function copy_record(record, allowed, artifact_root)
  if type(record) == "string" then
    local summary = safe_evidence_text(record)
    if summary == nil then return nil end
    return { summary = summary }
  end
  if type(record) ~= "table" then return nil end
  local copy = {}
  for _, key in ipairs(allowed) do
    local value = record[key]
    if value ~= nil then
      if key == "url" or key == "target" then
        copy[key] = safe_target(value)
      elseif key == "path" or key:sub(-5) == "_path" then
        copy[key] = safe_artifact_path(value, artifact_root)
      elseif type(value) == "number" or type(value) == "boolean" then
        copy[key] = value
      else
        copy[key] = safe_evidence_text(value)
      end
    end
  end
  for _, value in pairs(copy) do
    if value ~= nil then return copy end
  end
  return nil
end

local function append_items(target, value, allowed, artifact_root)
  if value == nil then return end
  local source = value
  if type(value) ~= "table" or is_array(value) then
    source = value
  else
    source = { value }
  end
  if type(source) == "table" and is_array(source) then
    for _, item in ipairs(source) do
      local copy = copy_record(item, allowed, artifact_root)
      if copy ~= nil then
        table.insert(target, copy)
        if #target >= max_evidence_records then return end
      end
    end
    return
  end
  local copy = copy_record(source, allowed, artifact_root)
  if copy ~= nil then table.insert(target, copy) end
end

local evidence_allowed = {
  stage = { "summary", "status", "mode", "module", "driver", "reason", "path", "url" },
  action = { "at", "kind", "label", "selector_ref", "target", "status", "summary", "path", "url" },
  url = { "url", "role", "status", "summary" },
  observation = { "at", "kind", "summary", "status", "path", "url" },
  console = { "level", "source", "summary", "count", "path" },
  network = { "method", "url", "status", "status_text", "summary", "count", "path" },
  trace = { "at", "kind", "summary", "status", "path" },
  screenshot = { "path", "role", "label", "sha256", "mime", "width", "height", "summary" },
  dom_state = { "path", "role", "summary", "state", "url" },
}

local function evidence_sources(payload, opts)
  local sources = {}
  if type(opts) == "table" and type(opts.native_evidence) == "table" then table.insert(sources, opts.native_evidence) end
  return sources
end

local function section_from_sources(sources, name, allowed, artifact_root)
  local items = {}
  for _, source in ipairs(sources) do
    append_items(items, source[name], allowed, artifact_root)
    if #items >= max_evidence_records then break end
  end
  return items
end

local function add_item(items, item)
  if item ~= nil and #items < max_evidence_records then table.insert(items, item) end
end

local function evidence_sections(result, payload, opts)
  opts = opts or {}
  local artifact_root = result.artifact_root
  local sources = evidence_sources(payload, opts)
  local sections = {
    discovery = section_from_sources(sources, "discovery", evidence_allowed.stage, artifact_root),
    planning = section_from_sources(sources, "planning", evidence_allowed.stage, artifact_root),
    execution = section_from_sources(sources, "execution", evidence_allowed.stage, artifact_root),
    skipped = section_from_sources(sources, "skipped", evidence_allowed.stage, artifact_root),
    failures = section_from_sources(sources, "failures", evidence_allowed.stage, artifact_root),
    actions = section_from_sources(sources, "actions", evidence_allowed.action, artifact_root),
    urls = section_from_sources(sources, "urls", evidence_allowed.url, artifact_root),
    observations = section_from_sources(sources, "observations", evidence_allowed.observation, artifact_root),
    console = section_from_sources(sources, "console", evidence_allowed.console, artifact_root),
    network = section_from_sources(sources, "network", evidence_allowed.network, artifact_root),
    trace = section_from_sources(sources, "traces", evidence_allowed.trace, artifact_root),
    screenshots = section_from_sources(sources, "screenshots", evidence_allowed.screenshot, artifact_root),
    dom_state = section_from_sources(sources, "dom_state", evidence_allowed.dom_state, artifact_root),
  }
  add_item(sections.discovery, copy_record({
    module = payload.module,
    driver = payload.e2e_driver or payload.driver,
    status = result.status,
    summary = result.job,
  }, evidence_allowed.stage, artifact_root))
  add_item(sections.planning, copy_record({
    mode = result.adapter and result.adapter.mode,
    status = result.status,
    summary = payload.dry_run == false and "native execution requested" or "planning envelope",
  }, evidence_allowed.stage, artifact_root))
  add_item(sections.execution, copy_record({
    mode = result.adapter and result.adapter.mode,
    status = result.status,
    summary = result.exit_code ~= nil and ("exit code " .. tostring(result.exit_code)) or result.job,
  }, evidence_allowed.stage, artifact_root))
  if payload.heartbeat_url ~= nil then
    add_item(sections.urls, copy_record({
      role = "heartbeat",
      url = payload.heartbeat_url,
      status = result.status,
    }, evidence_allowed.url, artifact_root))
  end
  if result.status == "planned" or result.status == "blocked" then
    add_item(sections.skipped, copy_record({
      reason = result.adapter and result.adapter.mode,
      status = result.status,
    }, evidence_allowed.stage, artifact_root))
  end
  if result.status == "failed" or result.status == "blocked" then
    add_item(sections.failures, copy_record({
      status = result.status,
      summary = result.stderr_excerpt or (result.adapter and result.adapter.mode),
    }, evidence_allowed.stage, artifact_root))
  end
  return sections
end

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

local function artifact_writer(payload, context)
  if payload.artifact_writer ~= nil then return payload.artifact_writer end
  return function(path, body)
    return write_file(path, body, context.quote)
  end
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
  if result.evidence_bundle ~= nil then
    metadata.evidence_bundle = result.evidence_bundle
  end
  return metadata
end

local function write_metadata(result, payload, context, writer)
  if not safe_artifact_root(result.artifact_root) then
    return nil, "unsafe artifact_root for fkst-native metadata"
  end
  local body = json_encode(metadata_for(result)) .. "\n"
  return writer(result.artifact_root .. "/metadata.json", body)
end

local function write_json_artifact(writer, path, value)
  return writer(path, json_encode(value) .. "\n")
end

local function write_evidence_bundle(result, payload, context, opts, writer)
  if not safe_artifact_root(result.artifact_root) then
    return nil, "unsafe artifact_root for fkst-native evidence"
  end
  local pointers = testing_contract.evidence_bundle_pointers(result.artifact_root)
  if pointers == nil then
    return nil, "failed to derive fkst-native evidence pointers"
  end
  result.evidence_bundle = pointers
  local sections = evidence_sections(result, payload, opts)
  local files = {
    discovery_path = { schema = "testing-runner.native-evidence-section.v1", section = "discovery", items = sections.discovery },
    planning_path = { schema = "testing-runner.native-evidence-section.v1", section = "planning", items = sections.planning },
    execution_path = { schema = "testing-runner.native-evidence-section.v1", section = "execution", items = sections.execution },
    skipped_path = { schema = "testing-runner.native-evidence-section.v1", section = "skipped", items = sections.skipped },
    failures_path = { schema = "testing-runner.native-evidence-section.v1", section = "failures", items = sections.failures },
    actions_path = { schema = "testing-runner.native-evidence-section.v1", section = "actions", items = sections.actions },
    urls_path = { schema = "testing-runner.native-evidence-section.v1", section = "urls", items = sections.urls },
    observations_path = { schema = "testing-runner.native-evidence-section.v1", section = "observations", items = sections.observations },
    console_path = { schema = "testing-runner.native-evidence-section.v1", section = "console", items = sections.console },
    network_path = { schema = "testing-runner.native-evidence-section.v1", section = "network", items = sections.network },
    trace_path = { schema = "testing-runner.native-evidence-section.v1", section = "trace", items = sections.trace },
    screenshots_path = { schema = "testing-runner.native-evidence-section.v1", section = "screenshots", items = sections.screenshots },
    dom_state_path = { schema = "testing-runner.native-evidence-section.v1", section = "dom_state", items = sections.dom_state },
  }
  local order = {
    "discovery_path",
    "planning_path",
    "execution_path",
    "skipped_path",
    "failures_path",
    "actions_path",
    "urls_path",
    "observations_path",
    "console_path",
    "network_path",
    "trace_path",
    "screenshots_path",
    "dom_state_path",
  }
  for _, key in ipairs(order) do
    local ok, err = write_json_artifact(writer, pointers[key], files[key])
    if not ok then return nil, err end
  end
  local manifest = {
    schema = testing_contract.schemas.native_evidence_bundle,
    job = result.job,
    status = result.status,
    artifact_root = result.artifact_root,
    source_ref = result.source_ref,
    trace_id = result.trace_id,
    dedup_key = result.dedup_key,
    pointers = pointers,
  }
  return write_json_artifact(writer, pointers.bundle_path, manifest)
end

local function with_artifacts(result, payload, context, opts)
  local writer = artifact_writer(payload, context)
  local ok, err = write_evidence_bundle(result, payload, context, opts, writer)
  if not ok then
    return context.result_payload("blocked", {
      adapter = result.adapter,
      stderr = "fkst-native artifact write failed: " .. tostring(err),
    })
  end
  ok, err = write_metadata(result, payload, context, writer)
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
    return with_artifacts(context.result_payload("blocked", {
      adapter = adapter("readiness-blocked"),
      stderr = "fkst-native preflight is " .. readiness,
    }), payload, context)
  end
  if payload.dry_run ~= false then
    return with_artifacts(context.result_payload("planned", { adapter = adapter("planning-envelope") }), payload, context)
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
    return with_artifacts(result, payload, context)
  end
  if job == "module" and payload.no_browser == true and payload.native_argv ~= nil then
    if targets_legacy_cli(payload.native_argv) then
      return with_artifacts(context.result_payload("blocked", {
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
    return with_artifacts(result, payload, context, { native_evidence = type(out) == "table" and out.native_evidence or nil })
  end
  if payload.no_browser == true then
    return with_artifacts(context.result_payload("planned", { adapter = adapter("no-browser-plan") }), payload, context)
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
      return with_artifacts(result, payload, context)
    end
    if targets_legacy_cli(payload.native_argv) then
      return with_artifacts(context.result_payload("blocked", {
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
    return with_artifacts(result, payload, context, { native_evidence = type(out) == "table" and out.native_evidence or nil })
  end
  return with_artifacts(context.result_payload("blocked", {
    adapter = adapter("capability-gap"),
    stderr = "fkst-native live execution for " .. tostring(job) .. " is not implemented beyond the planning envelope",
  }), payload, context)
end

return M
