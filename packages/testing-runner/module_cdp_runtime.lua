local execution = require("testing_runtime.execution")
local execution_contract = require("contract.testing_execution")

local M = {}

local supported_actions = {
  navigate = true,
  ["wait-for-load"] = true,
  ["inspect-visible-elements"] = true,
  ["collect-console-network-health"] = true,
  ["bounded-navigation"] = true,
  ["open-visible-surface"] = true,
}

local function local_cdp_url(value)
  if type(value) ~= "string" or value == "" or #value > 512 then return nil end
  if value:find("[%z\1-\31]") ~= nil or value:find("@", 1, true) ~= nil or value:find("#", 1, true) ~= nil then
    return nil
  end
  local authority, suffix = value:match("^http://([^/%?]+)(.*)$")
  if authority == nil or (suffix ~= "" and suffix ~= "/") then return nil end
  local host, port
  if authority:sub(1, 1) == "[" then
    host, port = authority:match("^%[([^%]]+)%](.*)$")
  else
    host, port = authority:match("^([^:]+)(.*)$")
  end
  if host == nil or (port ~= "" and port:match("^:%d+$") == nil) then return nil end
  host = host:lower()
  if host ~= "localhost" and host ~= "127.0.0.1" and host ~= "::1" then return nil end
  local normalized_authority = host == "::1" and "[::1]" or host
  return "http://" .. normalized_authority .. (port or "")
end

local function select_cdp_url(preflight)
  local selected
  for _, session in ipairs(type(preflight) == "table" and preflight.sessions or {}) do
    if type(session) == "table" and session.status == "ready" and session.role ~= "base_url" then
      local candidate = local_cdp_url(session.cdp_url)
      if candidate ~= nil then
        if selected ~= nil and selected ~= candidate then
          return nil, "conflicting ready CDP endpoints"
        end
        selected = candidate
      end
    end
  end
  if selected == nil then return nil, "requires a ready local CDP endpoint" end
  return selected
end

local function assertion(kind, target)
  local value = { type = kind }
  if target ~= nil then value.target = target end
  return value
end

local function assertions_for(action)
  if action.action == "navigate" then
    return { assertion("url-within-scope"), assertion("document-ready") }
  end
  if action.action == "wait-for-load" then
    return { assertion("document-ready"), assertion("url-within-scope") }
  end
  if action.action == "inspect-visible-elements" then
    return { assertion("visible-target-present", action.target), assertion("url-within-scope") }
  end
  if action.action == "collect-console-network-health" then
    return {
      assertion("no-severe-console"),
      assertion("no-failed-document-request"),
      assertion("url-within-scope"),
    }
  end
  if action.action == "bounded-navigation" then
    return { assertion("url-within-scope"), assertion("document-ready") }
  end
  if action.action == "open-visible-surface" then
    return {
      assertion("visible-target-present", action.target),
      assertion("url-within-scope"),
      assertion("document-ready"),
    }
  end
  return nil
end

local function build_request(artifact, result, payload, cdp_url)
  local actions, planner_indexes = {}, {}
  for planner_index, action in ipairs(artifact.actions or {}) do
    local assertions = type(action) == "table" and assertions_for(action) or nil
    if type(action) == "table"
      and action.execution_status == "planned"
      and supported_actions[action.action] == true
      and assertions ~= nil then
      table.insert(actions, {
        step = #actions + 1,
        module_id = action.module_id,
        case_id = action.case_id,
        priority = action.priority,
        action = action.action,
        target = action.target,
        url = action.url,
        assertions = assertions,
      })
      table.insert(planner_indexes, planner_index)
    end
  end
  if #actions == 0 then return nil, planner_indexes end
  local request = {
    schema = execution_contract.schemas.execution_request,
    module = payload.module,
    trace_id = result.trace_id,
    dedup_key = result.dedup_key,
    artifact_root = result.artifact_root,
    base_url = artifact.base_url,
    allowed_origins = artifact.allowed_origins,
    cdp_url = cdp_url,
    step_budget = #actions,
    actions = actions,
  }
  return request, planner_indexes
end

local function copy_assertion_results(value)
  local results = {}
  for _, item in ipairs(value or {}) do
    table.insert(results, {
      type = item.type,
      status = item.status,
      observation = item.observation,
      evidence_pointer = item.evidence_pointer,
    })
  end
  return results
end

local function copy_browser_evidence(value)
  if type(value) ~= "table" then return nil end
  local evidence = { console = {}, network = {} }
  for _, fact in ipairs(value.console or {}) do
    table.insert(evidence.console, {
      category = fact.category,
      source = fact.source,
      message = fact.message,
      raw_diagnostic_index = fact.raw_diagnostic_index,
    })
  end
  for _, fact in ipairs(value.network or {}) do
    local item = {
      resource_type = fact.resource_type,
      url_class = fact.url_class,
      failure_reason = fact.failure_reason,
      canceled = fact.canceled,
      initiator_type = fact.initiator_type,
      main_document = fact.main_document,
      raw_diagnostic_index = fact.raw_diagnostic_index,
    }
    if fact.initiator_url_class ~= nil then item.initiator_url_class = fact.initiator_url_class end
    table.insert(evidence.network, item)
  end
  return evidence
end

local function count_actions(artifact)
  local counts = { planned = 0, blocked = 0, executed = 0, failed = 0 }
  for _, action in ipairs(artifact.actions or {}) do
    local status = type(action) == "table" and action.execution_status or nil
    if counts[status] ~= nil then counts[status] = counts[status] + 1 end
  end
  artifact.action_count = #(artifact.actions or {})
  artifact.planned_action_count = counts.planned
  artifact.blocked_action_count = counts.blocked
  artifact.executed_action_count = counts.executed
  artifact.failed_action_count = counts.failed
  return counts
end

local function blocked(artifact, classification, reason)
  artifact.execution_status = "blocked"
  artifact.classification = classification
  artifact.limitations = { reason }
  count_actions(artifact)
  return artifact
end

local function reconcile(artifact, receipt, planner_indexes, paths)
  for receipt_index, action_receipt in ipairs(receipt.actions) do
    local action = artifact.actions[planner_indexes[receipt_index]]
    action.execution_status = action_receipt.execution_status
    action.assertion_status = action_receipt.assertion_status
    action.observation = action_receipt.observation
    action.evidence_pointer = action_receipt.evidence_pointer
    action.assertion_results = copy_assertion_results(action_receipt.assertion_results)
    action.browser_evidence = copy_browser_evidence(action_receipt.browser_evidence)
  end
  artifact.browser_execution_plan_path = paths.plan
  artifact.browser_execution_request_path = paths.request
  artifact.browser_execution_receipt_path = paths.receipt
  local counts = count_actions(artifact)
  if receipt.status == "passed" and counts.planned == 0 and counts.blocked == 0 then
    artifact.execution_status = "passed"
    artifact.classification = receipt.classification
    artifact.limitations = {}
  elseif receipt.status == "passed" then
    artifact.execution_status = "degraded"
    artifact.classification = "browser-execution-partial"
    artifact.limitations = { "some selected actions remain planned or blocked after read-only browser execution" }
  else
    artifact.execution_status = receipt.status
    artifact.classification = receipt.classification
    artifact.limitations = receipt.status == "failed"
      and { "one or more typed browser assertions failed" }
      or { "browser execution did not complete every submitted action" }
  end
  return artifact
end

function M.run(artifact, result, payload, runtime_ports)
  local cdp_url, endpoint_error = select_cdp_url(payload.preflight_result)
  if cdp_url == nil then return blocked(artifact, "missing-cdp-session", endpoint_error) end
  local request, planner_indexes = build_request(artifact, result, payload, cdp_url)
  if request == nil then
    if #(artifact.actions or {}) == 0 then return artifact end
    artifact.execution_status = "degraded"
    artifact.classification = "mutation-execution-deferred"
    artifact.limitations = { "selected actions require unsupported or deferred runtime orchestration" }
    count_actions(artifact)
    return artifact
  end

  local prepared_ok, prepared, paths = pcall(execution.prepare, request, runtime_ports)
  if not prepared_ok then
    return blocked(artifact, "runtime-request-invalid", "browser execution request preparation failed")
  end
  local executed_ok, receipt, execution_paths = pcall(execution.execute, prepared, runtime_ports)
  if not executed_ok then
    local classification = tostring(receipt):find("receipt", 1, true) ~= nil
      and "runtime-receipt-invalid"
      or "cdp-runtime-failure"
    local reason = classification == "runtime-receipt-invalid"
      and "browser execution receipt was invalid or unavailable"
      or "browser runtime process did not complete successfully"
    return blocked(artifact, classification, reason)
  end
  return reconcile(artifact, receipt, planner_indexes, execution_paths or paths)
end

M.local_cdp_url = local_cdp_url
M.select_cdp_url = select_cdp_url

return M
