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

local function local_origin(value)
  if type(value) ~= "string" or value == "" or #value > 512 then return nil end
  local scheme, authority = value:match("^(https?)://([^/%?#]+)")
  if scheme == nil then return nil end
  if authority == "localhost" or authority == "127.0.0.1" or authority == "[::1]" then
    return scheme .. "://" .. authority
  end
  local host, port = authority:match("^(localhost):(%d+)$")
  if host == nil then host, port = authority:match("^(127%.0%.0%.1):(%d+)$") end
  if host == nil then host, port = authority:match("^(%[::1%]):(%d+)$") end
  if host ~= nil and port ~= nil then
    return scheme .. "://" .. host .. ":" .. port
  end
  return nil
end

local function url_in_origins(url, origins)
  local origin = local_origin(url)
  if origin == nil then return false end
  for _, allowed in ipairs(origins or {}) do
    if origin == allowed then return true end
  end
  return false
end

local function safe_browser_text(value, fallback, limit)
  local text = tostring(value or fallback or "unknown")
  if text == "" then text = fallback or "unknown" end
  text = text:gsub("[%z\1-\31]", " ")
  if #text > (limit or 512) then text = text:sub(1, limit or 512) end
  return text
end

local function safe_pointer(value, fallback)
  local text = safe_browser_text(value, fallback, 512)
  if text:find("..", 1, true) ~= nil or text:find("\0", 1, true) ~= nil then
    return fallback
  end
  return text
end

local function priority_allowed(value)
  return value == "P0" or value == "P1"
end

local function contains_interactive_auth(value)
  local text = tostring(value or ""):lower()
  return text:find("login", 1, true) ~= nil
    or text:find("mfa", 1, true) ~= nil
    or text:find("captcha", 1, true) ~= nil
end

local function ready_browser_session(preflight, role)
  if type(preflight) ~= "table" or type(preflight.sessions) ~= "table" then return nil end
  for _, session in ipairs(preflight.sessions) do
    if type(session) == "table" and session.status == "ready" and session.role ~= "base_url" then
      if role == nil or role == "" or session.role == role then
        return session
      end
    end
  end
  return nil
end

local function stop_condition_hit(stop_condition, stop_conditions)
  if type(stop_condition) ~= "string" then return false end
  for _, value in ipairs(stop_conditions or {}) do
    if stop_condition == value then return true end
  end
  return false
end

local function exploration_executor(payload)
  local probe = type(payload.probe) == "table" and payload.probe or {}
  if type(probe.browser_harness_action) == "function" then
    return probe.browser_harness_action
  end
  if type(probe.cdp_action) == "function" then
    return probe.cdp_action
  end
  return nil
end

local function browser_action_summary(action, result, artifact_root, index)
  local fallback_pointer = artifact_root .. "/metadata.json#native_summary.actions." .. tostring(index)
  result = type(result) == "table" and result or {}
  return {
    intent = safe_browser_text(action.intent, "explore", 512),
    action = safe_label(action.action, "observe"),
    target = safe_browser_text(action.target, "unknown", 512),
    url = safe_target(result.url or action.url or "unknown") or "unknown",
    priority = safe_label(action.priority, "P0"),
    result = safe_label(result.result or result.status or "passed", "passed"),
    classification = safe_label(result.classification or "passed", "passed"),
    observation = safe_browser_text(result.observation, "completed", 512),
    evidence_pointer = safe_pointer(result.evidence_pointer, fallback_pointer),
  }
end

local function browser_exploration_summary(payload, status, classification, actions)
  local plan = payload.browser_exploration or {}
  return {
    schema = "testing-runner.browser-exploration-summary.v1",
    module = payload.module,
    driver = payload.e2e_driver,
    status = status,
    mode = "bounded-cdp-exploration",
    classification = classification,
    step_budget = tonumber(plan.step_budget) or 0,
    planned_actions = type(plan.actions) == "table" and #plan.actions or 0,
    executed_actions = #actions,
    actions = actions,
    readiness = readiness_summary(payload.preflight_result),
  }
end

local function blocked_browser_exploration(payload, context, classification, reason, actions)
  local result = context.result_payload("blocked", {
    adapter = adapter("browser-exploration"),
    stderr = reason,
  })
  result.native_summary = browser_exploration_summary(payload, "blocked", classification, actions or {})
  return result
end

local function validate_exploration_policy(payload)
  local plan = payload.browser_exploration
  if type(plan) ~= "table" then
    return nil, "boundary", "fkst-native browser_exploration is required"
  end
  if type(payload.e2e_driver) ~= "string"
    or (payload.e2e_driver:find("browser_harness", 1, true) == nil
      and payload.e2e_driver:find("browser-harness", 1, true) == nil
      and payload.e2e_driver:lower():find("cdp", 1, true) == nil)
  then
    return nil, "harness", "fkst-native browser exploration requires browser-harness/CDP driver"
  end
  if plan.module_boundary ~= payload.module then
    return nil, "boundary", "fkst-native browser exploration module boundary mismatch"
  end
  if type(plan.allowed_origins) ~= "table" or #plan.allowed_origins == 0 then
    return nil, "boundary", "fkst-native browser exploration allowed_origins are required"
  end
  local origins = {}
  for _, value in ipairs(plan.allowed_origins) do
    local origin = local_origin(value)
    if origin == nil then
      return nil, "boundary", "fkst-native browser exploration allowed origin is not local"
    end
    table.insert(origins, origin)
  end
  if type(plan.step_budget) ~= "number" or plan.step_budget < 1 or plan.step_budget > 16 then
    return nil, "boundary", "fkst-native browser exploration step_budget is required"
  end
  if type(plan.stop_conditions) ~= "table" or #plan.stop_conditions == 0 then
    return nil, "boundary", "fkst-native browser exploration stop_conditions are required"
  end
  if type(plan.actions) ~= "table" then
    return nil, "boundary", "fkst-native browser exploration actions are required"
  end
  if ready_browser_session(payload.preflight_result, plan.session_role) == nil then
    return nil, "missing-session", "fkst-native browser exploration requires an existing ready browser session"
  end
  return origins
end

local function run_browser_exploration(payload, context)
  local artifact_root = context.result_payload("planned", {}).artifact_root
  local origins, classification, reason = validate_exploration_policy(payload)
  if origins == nil then
    return blocked_browser_exploration(payload, context, classification, reason)
  end

  local execute = exploration_executor(payload)
  if execute == nil then
    return blocked_browser_exploration(payload, context, "harness", "fkst-native browser exploration harness action path is unavailable")
  end

  local plan = payload.browser_exploration
  local actions, status, overall_classification = {}, "passed", "passed"
  local budget = math.min(plan.step_budget, #plan.actions)
  for index = 1, budget do
    local action = plan.actions[index]
    if not priority_allowed(action.priority) then
      table.insert(actions, browser_action_summary(action, {
        result = "blocked",
        classification = "boundary",
        observation = "priority is outside safe P0/P1 exploration",
      }, artifact_root, index))
      status, overall_classification = "blocked", "boundary"
      break
    end
    if contains_interactive_auth(action.intent) or contains_interactive_auth(action.action) then
      table.insert(actions, browser_action_summary(action, {
        result = "blocked",
        classification = "boundary",
        observation = "interactive account challenge action is outside scope",
      }, artifact_root, index))
      status, overall_classification = "blocked", "boundary"
      break
    end
    if not url_in_origins(action.url, origins) then
      table.insert(actions, browser_action_summary(action, {
        result = "blocked",
        classification = "boundary",
        observation = "action URL is outside allowed origins",
      }, artifact_root, index))
      status, overall_classification = "blocked", "boundary"
      break
    end

    local ok, out = pcall(execute, action, {
      module = payload.module,
      driver = payload.e2e_driver,
      allowed_origins = origins,
      artifact_root = artifact_root,
      session_role = plan.session_role,
    })
    if not ok then
      out = {
        result = "blocked",
        classification = "harness",
        observation = tostring(out),
      }
    end
    if type(out) ~= "table" then
      out = {
        result = "blocked",
        classification = "harness",
        observation = "harness returned an unreliable action result",
      }
    end
    if not url_in_origins(out.url or action.url, origins) then
      out.result = "blocked"
      out.classification = "boundary"
      out.observation = "observed URL is outside allowed origins"
    end
    if type(out.evidence_pointer) ~= "string" or out.evidence_pointer == "" then
      out.result = "blocked"
      out.classification = "harness"
      out.observation = "harness did not return an evidence pointer"
    end

    local recorded = browser_action_summary(action, out, artifact_root, index)
    table.insert(actions, recorded)

    if recorded.result == "failed" and recorded.classification == "product" then
      status, overall_classification = "failed", "product"
      break
    end
    if recorded.result == "blocked" or recorded.classification == "harness" or recorded.classification == "boundary" then
      status, overall_classification = "blocked", recorded.classification
      break
    end
    if stop_condition_hit(out.stop_condition, plan.stop_conditions) then
      overall_classification = "stopped"
      break
    end
  end

  if status == "passed" and #plan.actions > plan.step_budget then
    status, overall_classification = "blocked", "budget"
  end

  local result = context.result_payload(status, {
    adapter = adapter("browser-exploration"),
    exit_code = status == "passed" and 0 or 1,
    stderr = status == "passed" and "" or "fkst-native browser exploration did not complete all safe actions",
  })
  result.native_summary = browser_exploration_summary(payload, status, overall_classification, actions)
  return result
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
    if payload.browser_exploration ~= nil then
      return with_metadata(run_browser_exploration(payload, context), payload, context)
    end
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
