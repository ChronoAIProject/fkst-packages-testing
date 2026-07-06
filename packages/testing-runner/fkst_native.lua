local M = {}

local module_cdp_execution = require("module_cdp_execution")
local module_inventory = require("module_inventory")
local module_planning = require("module_planning")
local outcome = require("outcome")

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

local function writer_for(payload, context)
  if payload.artifact_writer ~= nil then return payload.artifact_writer end
  return function(path, body)
    return write_file(path, body, context.quote)
  end
end

local function bounded_ref(value)
  return type(value) == "string" and value ~= "" and #value <= 512 and value:find("[%z\1-\31]") == nil and value or nil
end

local function section_path(root, name)
  return root .. "/evidence/" .. name .. ".json"
end

local function evidence_bundle_path(root)
  return root .. "/evidence-bundle.json"
end

local function add_if_present(record, key, value)
  if value ~= nil then record[key] = value end
end

local function discovery_evidence(payload, root)
  local observations = {}
  local discovery = payload.module_discovery or {}
  for _, observation in ipairs(discovery.observations or {}) do
    if type(observation) == "table" then
      local item = {
        id = safe_label(observation.id, "observation"),
        entry_url = safe_target(observation.entry_url),
      }
      add_if_present(item, "name", bounded_ref(observation.name))
      add_if_present(item, "visible_label", bounded_ref(observation.visible_label))
      add_if_present(item, "route", bounded_ref(observation.route))
      add_if_present(item, "discovery_source", bounded_ref(observation.discovery_source or observation.source))
      add_if_present(item, "confidence", bounded_ref(observation.confidence))
      add_if_present(item, "evidence_pointer", bounded_ref(observation.evidence_pointer))
      table.insert(observations, item)
      if #observations >= 16 then break end
    end
  end
  return {
    schema = "testing-runner.native-evidence-discovery.v1",
    artifact_kind = "native-evidence-discovery",
    artifact_root = root,
    observations = observations,
    observation_count = #observations,
  }
end

local function planning_evidence(planning, root)
  local evidence = {
    schema = "testing-runner.native-evidence-planning.v1",
    artifact_kind = "native-evidence-planning",
    artifact_root = root,
    plan_status = type(planning) == "table" and planning.plan_status or "not-available",
  }
  if type(planning) == "table" then
    evidence.feature_inventory_path = planning.feature_inventory_path
    evidence.test_plan_path = planning.test_plan_path
    if type(planning.test_plan) == "table" then evidence.review_gate = planning.test_plan.review_gate end
  end
  return evidence
end

local function action_trace_evidence(artifact, root)
  local actions = {}
  if type(artifact) == "table" then
    for _, action in ipairs(artifact.actions or {}) do
      if type(action) == "table" then
        local item = {
          step = action.step,
          module_id = bounded_ref(action.module_id),
          case_id = bounded_ref(action.case_id),
          priority = bounded_ref(action.priority),
          action = bounded_ref(action.action),
          target = bounded_ref(action.target),
          url = safe_target(action.url),
          observation = bounded_ref(action.observation),
          evidence_pointer = bounded_ref(action.evidence_pointer),
        }
        add_if_present(item, "mutation_kind", bounded_ref(action.mutation_kind))
        add_if_present(item, "fixture_ref", bounded_ref(action.fixture_ref))
        add_if_present(item, "cleanup_ref", bounded_ref(action.cleanup_ref))
        add_if_present(item, "rollback_ref", bounded_ref(action.rollback_ref))
        add_if_present(item, "fixture_evidence_pointer", bounded_ref(action.fixture_evidence_pointer))
        table.insert(actions, item)
        if #actions >= 32 then break end
      end
    end
  end
  return {
    schema = "testing-runner.native-evidence-action-trace.v1",
    artifact_kind = "native-evidence-action-trace",
    artifact_root = root,
    execution_path = root .. "/cdp-execution.json",
    actions = actions,
    action_count = #actions,
  }
end

local function skipped_cases_evidence(planning, root)
  local skipped = {}
  if type(planning) == "table" and type(planning.test_plan) == "table" then
    for _, module in ipairs(planning.test_plan.modules or {}) do
      for _, case in ipairs(module.cases or {}) do
        if type(case) == "table" and case.review_status ~= "executable" then
          local item = {
            module_id = bounded_ref(case.module_id or module.id),
            case_id = bounded_ref(case.id),
            priority = bounded_ref(case.priority),
            review_status = bounded_ref(case.review_status),
            reason = bounded_ref(case.reason),
            evidence_pointer = bounded_ref(case.evidence_pointer),
          }
          if type(case.mutation_gate) == "table" then
            item.mutation_gate = {
              status = bounded_ref(case.mutation_gate.status),
              classification = bounded_ref(case.mutation_gate.classification),
              mutation_kind = bounded_ref(case.mutation_gate.mutation_kind),
            }
          end
          table.insert(skipped, item)
          if #skipped >= 64 then break end
        end
      end
      if #skipped >= 64 then break end
    end
  end
  return {
    schema = "testing-runner.native-evidence-skipped-cases.v1",
    artifact_kind = "native-evidence-skipped-cases",
    artifact_root = root,
    skipped_cases = skipped,
    skipped_count = #skipped,
  }
end

local function failures_evidence(result, artifact, root)
  local limitations = type(artifact) == "table" and artifact.limitations or nil
  return {
    schema = "testing-runner.native-evidence-failures.v1",
    artifact_kind = "native-evidence-failures",
    artifact_root = root,
    status = result.status,
    classification = result.native_summary and result.native_summary.classification or nil,
    limitations = limitations or {},
  }
end

local function console_network_evidence(artifact, root)
  local checks = {}
  if type(artifact) == "table" then
    for _, action in ipairs(artifact.actions or {}) do
      if type(action) == "table" and action.action == "collect-console-network-health" then
        table.insert(checks, {
          case_id = bounded_ref(action.case_id),
          url = safe_target(action.url),
          observation = bounded_ref(action.observation),
          evidence_pointer = bounded_ref(action.evidence_pointer),
        })
      end
    end
  end
  return {
    schema = "testing-runner.native-evidence-console-network.v1",
    artifact_kind = "native-evidence-console-network",
    artifact_root = root,
    status = #checks > 0 and "bounded-summary" or "not-collected",
    checks = checks,
    check_count = #checks,
  }
end

local function pointer_index(schema, kind, root, refs)
  return {
    schema = schema,
    artifact_kind = kind,
    artifact_root = root,
    refs = refs or {},
    ref_count = #(refs or {}),
  }
end

local function write_json(writer, path, value)
  return writer(path, json_encode(value) .. "\n")
end

local function supports_evidence_bundle(summary)
  local schema = type(summary) == "table" and summary.schema or nil
  return schema == "testing-runner.module-ui-loop-summary.v1"
    or schema == "testing-runner.module-inventory-summary.v1"
    or schema == module_cdp_execution.summary_schema
end

local function write_native_evidence_bundle(result, payload, context, artifact, planning)
  if not supports_evidence_bundle(result.native_summary) then return true end
  local root = result.artifact_root
  if not safe_artifact_root(root) then return nil, "unsafe artifact_root for fkst-native evidence bundle" end
  local writer = writer_for(payload, context)
  local paths = {
    bundle = evidence_bundle_path(root),
    discovery = section_path(root, "discovery"),
    planning = section_path(root, "planning"),
    action_trace = section_path(root, "action-trace"),
    skipped_cases = section_path(root, "skipped-cases"),
    failures = section_path(root, "failures"),
    console_network = section_path(root, "console-network-summary"),
    screenshots = section_path(root, "screenshot-index"),
    dom_state = section_path(root, "dom-state-summary"),
    gap_backlog = outcome.path(root),
  }
  result.native_summary.evidence_bundle_path = paths.bundle
  result.native_summary.gap_backlog_path = paths.gap_backlog
  local backlog = outcome.build(result, payload, artifact, planning)
  result.native_summary.outcome_classification = backlog.outcome_classification
  backlog.evidence_bundle_path = paths.bundle
  local sections = {
    { paths.discovery, discovery_evidence(payload, root) },
    { paths.planning, planning_evidence(planning, root) },
    { paths.action_trace, action_trace_evidence(artifact, root) },
    { paths.skipped_cases, skipped_cases_evidence(planning, root) },
    { paths.failures, failures_evidence(result, artifact, root) },
    { paths.console_network, console_network_evidence(artifact, root) },
    { paths.screenshots, pointer_index("testing-runner.native-evidence-screenshot-index.v1", "native-evidence-screenshot-index", root, {}) },
    { paths.dom_state, pointer_index("testing-runner.native-evidence-dom-state-summary.v1", "native-evidence-dom-state-summary", root, {}) },
    { paths.gap_backlog, backlog },
  }
  for _, section in ipairs(sections) do
    local ok, err = write_json(writer, section[1], section[2])
    if not ok then return nil, err end
  end
  return write_json(writer, paths.bundle, {
    schema = "testing-runner.native-evidence-bundle.v1",
    artifact_kind = "native-evidence-bundle",
    module = payload.module,
    status = result.status,
    artifact_root = root,
    metadata_path = root .. "/metadata.json",
    discovery_path = paths.discovery,
    planning_path = paths.planning,
    execution_trace_path = paths.action_trace,
    skipped_cases_path = paths.skipped_cases,
    failures_path = paths.failures,
    console_network_summary_path = paths.console_network,
    screenshot_index_path = paths.screenshots,
    dom_state_summary_path = paths.dom_state,
    gap_backlog_path = paths.gap_backlog,
  })
end

local function write_metadata(result, payload, context)
  if not safe_artifact_root(result.artifact_root) then
    return nil, "unsafe artifact_root for fkst-native metadata"
  end
  local body = json_encode(metadata_for(result)) .. "\n"
  return writer_for(payload, context)(result.artifact_root .. "/metadata.json", body)
end

local function write_module_inventory(result, payload, context)
  if payload.module_discovery == nil then return true end
  if not safe_artifact_root(result.artifact_root) then
    return nil, "unsafe artifact_root for fkst-native module inventory"
  end
  local writer = writer_for(payload, context)
  local inventory = module_inventory.inventory(payload.module_discovery, payload.ui_loop, result.artifact_root, {
    readiness = readiness_summary(payload.preflight_result),
  })
  local planning = module_planning.build(inventory, payload.ui_loop, result.artifact_root, {
    mutation_fixtures = ((payload.cdp_execution or {}).mutation_fixtures),
  })
  if result.native_summary == nil or result.native_summary.schema ~= module_cdp_execution.summary_schema then
    result.native_summary = module_inventory.summary(inventory, result.artifact_root, payload.module, result.status)
    result.native_summary.feature_inventory_path = planning.feature_inventory_path
    result.native_summary.test_plan_path = planning.test_plan_path
    result.native_summary.plan_status = planning.plan_status
  end

  local ok, err = writer(result.artifact_root .. "/module-inventory.json", json_encode(inventory) .. "\n")
  if not ok then return nil, err end
  ok, err = writer(planning.feature_inventory_path, json_encode(planning.feature_inventory) .. "\n")
  if not ok then return nil, err end
  ok, err = writer(planning.test_plan_path, json_encode(planning.test_plan) .. "\n")
  if not ok then return nil, err end
  return true, nil, planning
end

local function write_cdp_execution_artifact(artifact, payload, context)
  if not safe_artifact_root(artifact.artifact_root) then
    return nil, "unsafe artifact_root for fkst-native cdp execution"
  end
  return writer_for(payload, context)(artifact.execution_path, json_encode(artifact) .. "\n")
end

local function with_metadata(result, payload, context, opts)
  opts = opts or {}
  local inventory_ok, inventory_err, planning = write_module_inventory(result, payload, context)
  if not inventory_ok then
    return context.result_payload("blocked", {
      adapter = result.adapter,
      stderr = "fkst-native artifact write failed: " .. tostring(inventory_err),
    })
  end
  local bundle_ok, bundle_err = write_native_evidence_bundle(result, payload, context, opts.artifact, planning)
  if not bundle_ok then
    return context.result_payload("blocked", {
      adapter = result.adapter,
      stderr = "fkst-native artifact write failed: " .. tostring(bundle_err),
    })
  end
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
    if payload.cdp_execution ~= nil then
      local artifact_root = context.result_payload("planned", {}).artifact_root
      local artifact = module_cdp_execution.build(payload, artifact_root, {
        readiness = readiness_summary(payload.preflight_result),
      })
      local status = artifact.execution_status
      local result = context.result_payload(status, {
        adapter = adapter(status == "blocked" and "module-cdp-execution-blocked" or "module-cdp-execution"),
        stderr = "fkst-native bounded CDP execution " .. tostring(artifact.classification),
      })
      artifact.artifact_root = result.artifact_root
      artifact.execution_path = result.artifact_root .. "/cdp-execution.json"
      artifact.metadata_path = result.artifact_root .. "/metadata.json"
      artifact.inventory_path = artifact.inventory_path and (result.artifact_root .. "/module-inventory.json") or nil
      artifact.feature_inventory_path = artifact.feature_inventory_path and (result.artifact_root .. "/feature-inventory.json") or nil
      artifact.test_plan_path = artifact.test_plan_path and (result.artifact_root .. "/test-plan.json") or nil
      result.native_summary = module_cdp_execution.summary(artifact, payload.module, result.status)
      local ok, err = write_cdp_execution_artifact(artifact, payload, context)
      if not ok then
        return context.result_payload("blocked", {
          adapter = result.adapter,
          stderr = "fkst-native artifact write failed: " .. tostring(err),
        })
      end
      return with_metadata(result, payload, context, { artifact = artifact })
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
