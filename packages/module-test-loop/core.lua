local strings = require("contract.strings")
local testing_contract = require("contract.testing")
local ports_module = require("ports")

local M = {}

M.schemas = {
  request = "module-test-loop.start.v1",
  state = "module-test-loop.state.v1",
  terminal = "module-test-loop.terminal.v1",
}

local function copy(value)
  if type(value) ~= "table" then return value end
  local out = {}
  for key, item in pairs(value) do out[key] = copy(item) end
  return out
end

local function same(left, right)
  if type(left) ~= type(right) then return false end
  if type(left) ~= "table" then return left == right end
  for key, item in pairs(left) do if not same(item, right[key]) then return false end end
  for key, _ in pairs(right) do if left[key] == nil then return false end end
  return true
end

function M.validate_request(payload)
  if type(payload) ~= "table" then error("module-test-loop: malformed-request: payload must be a table") end
  if payload.schema ~= M.schemas.request then error("module-test-loop: unknown-schema: expected " .. M.schemas.request) end
  if not strings.is_bounded_string(payload.module, 256) then error("module-test-loop: malformed-request: module is required") end
  if payload.artifact_root == nil or not strings.is_artifact_root(payload.artifact_root) then
    error("module-test-loop: malformed-request: artifact_root is required")
  end
  if payload.state_ref ~= nil and payload.state_ref ~= payload.artifact_root .. "/module-loop-state.json" then
    error("module-test-loop: malformed-request: state_ref must use the deterministic module loop path")
  end
  if payload.max_attempts ~= nil then
    error("module-test-loop: unsupported-request: max_attempts has no runner-owned retry contract")
  end
  if type(payload.source_ref) ~= "table" or not strings.is_bounded_string(payload.source_ref.kind, 80)
    or not strings.is_bounded_string(payload.source_ref.ref, 2048) then
    error("module-test-loop: malformed-request: source_ref is required")
  end
  if not testing_contract.is_bounded_id(payload.trace_id) or not testing_contract.is_bounded_id(payload.dedup_key) then
    error("module-test-loop: malformed-request: trace and dedup identity are required")
  end
  local readiness_digest_valid = type(payload.browser_readiness_sha256) == "string"
    and #payload.browser_readiness_sha256 == 64 and payload.browser_readiness_sha256:match("^[0-9a-f]+$") ~= nil
  if (payload.browser_readiness_ref == nil) ~= (payload.browser_readiness_sha256 == nil)
    or (payload.browser_readiness_ref ~= nil
      and (not strings.is_artifact_root(payload.browser_readiness_ref) or not readiness_digest_valid)) then
    error("module-test-loop: malformed-request: browser readiness pointer and digest are invalid")
  end
  return payload
end

local function preflight_context(payload)
  if type(payload.preflight_result) ~= "table" then return nil end
  if type(payload.preflight_result.request_context) ~= "table" then return nil end
  return payload.preflight_result.request_context
end

local function fallback(payload, key)
  if payload[key] ~= nil then return payload[key] end
  local context = preflight_context(payload)
  if context == nil then return nil end
  return context[key]
end

function M.runner_request(payload)
  payload = M.validate_request(payload)
  return {
    schema = "testing-runner.module-test-loop.request.v1",
    module = payload.module,
    config = payload.config,
    e2e_driver = payload.e2e_driver,
    no_browser = fallback(payload, "no_browser"),
    dry_run = fallback(payload, "dry_run"),
    dry_run_github = payload.dry_run_github,
    backend = payload.backend,
    native_argv = fallback(payload, "native_argv"),
    ui_loop = payload.ui_loop,
    module_discovery = payload.module_discovery,
    cdp_execution = payload.cdp_execution,
    ai_design_loop_request = payload.ai_design_loop_request,
    ai_design_loop_state_ref = copy(payload.ai_design_loop_state_ref),
    testing_design_context = payload.testing_design_context,
    browser_readiness_ref = payload.browser_readiness_ref,
    browser_readiness_sha256 = payload.browser_readiness_sha256,
    preflight_result = payload.preflight_result,
    artifact_root = payload.artifact_root,
    source_ref = copy(payload.source_ref),
    trace_id = payload.trace_id,
    dedup_key = payload.dedup_key,
  }
end

local function attempt_request(state)
  local request = M.runner_request(state.request)
  request.source_ref = { kind = "module-test-loop-attempt", ref = state.state_ref }
  request.dedup_key = state.request.dedup_key .. "/attempt/" .. tostring(state.attempt)
  return request
end

local function save(ports, state)
  local expected = state.version
  state.version = expected + 1
  if ports.save_state(state.state_ref, copy(state), expected) ~= true then
    error("module-test-loop: state-save-conflict: durable compare-and-swap failed")
  end
end

local function action(queue, payload)
  return { queue = queue, payload = payload }
end

function M.start(payload, supplied_ports)
  payload = M.validate_request(payload)
  local ports = ports_module.resolve(supplied_ports)
  local state_ref = payload.state_ref or (payload.artifact_root .. "/module-loop-state.json")
  local state = ports.load_state(state_ref)
  if state ~= nil then
    if state.schema ~= M.schemas.state or not same(state.request, payload) then
      error("module-test-loop: foreign-state: saved loop request differs")
    end
    return copy(state.pending_actions or {})
  end
  state = {
    schema = M.schemas.state,
    version = 0,
    state_ref = state_ref,
    request = copy(payload),
    attempt = 1,
    max_attempts = 1,
    phase = "runner-pending",
    pending_actions = {},
  }
  state.pending_actions = { action("testing-runner.module_test_request", attempt_request(state)) }
  save(ports, state)
  return copy(state.pending_actions)
end

local function result_for_terminal(result)
  return {
    schema = result.schema,
    job = result.job,
    status = result.status,
    artifact_root = result.artifact_root,
    source_ref = copy(result.source_ref),
    trace_id = result.trace_id,
    dedup_key = result.dedup_key,
    adapter = testing_contract.copy_scalar_map(result.adapter),
    stderr_excerpt = type(result.stderr_excerpt) == "string" and result.stderr_excerpt:sub(1, 600) or nil,
    native_summary = testing_contract.copy_native_summary(result.native_summary),
  }
end

function M.handle_result(result, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  if type(result) ~= "table" or result.schema ~= testing_contract.schemas.runner_result
    or result.job ~= "module-test-loop" or type(result.source_ref) ~= "table"
    or result.source_ref.kind ~= "module-test-loop-attempt" then
    error("module-test-loop: foreign-result: runner result does not belong to an attempt")
  end
  local state = ports.load_state(result.source_ref.ref)
  if type(state) ~= "table" or state.schema ~= M.schemas.state then
    error("module-test-loop: state-unavailable: runner result has no durable loop")
  end
  if state.phase == "terminal" then return copy(state.pending_actions or {}) end
  if state.phase ~= "runner-pending" or result.trace_id ~= state.request.trace_id
    or result.dedup_key ~= state.request.dedup_key .. "/attempt/" .. tostring(state.attempt) then
    error("module-test-loop: stale-result: runner attempt identity differs")
  end
  local native = type(result.native_summary) == "table" and result.native_summary or nil
  local plan_ref = native and native.test_plan_path or nil
  local plan_sha256
  if type(plan_ref) == "string" then
    local ok, value = pcall(ports.artifact_digest, plan_ref)
    if ok and type(value) == "string" and #value == 64 and value:match("^[0-9a-f]+$") then
      plan_sha256 = value
    end
  end
  local terminal = {
    schema = M.schemas.terminal,
    status = result.status,
    attempt = state.attempt,
    max_attempts = state.max_attempts,
    runner_result = result_for_terminal(result),
    module_plan_ref = plan_ref,
    module_plan_sha256 = plan_sha256,
    state_ref = state.state_ref,
    source_ref = copy(state.request.source_ref),
    trace_id = state.request.trace_id,
    dedup_key = state.request.dedup_key .. "/terminal",
  }
  state.phase = "terminal"
  state.terminal = copy(terminal)
  state.pending_actions = { action("module_loop_terminal", terminal) }
  save(ports, state)
  return copy(state.pending_actions)
end

function M.redrive(payload, supplied_ports)
  local ports = ports_module.resolve(supplied_ports)
  local limit = type(payload) == "table" and payload.limit or 32
  if type(limit) ~= "number" or limit < 1 or limit > 64 or limit ~= math.floor(limit) then
    error("module-test-loop: malformed-redrive: limit must be from 1 to 64")
  end
  local states = ports.list_pending_states(limit)
  if type(states) ~= "table" then error("module-test-loop: redrive-unavailable: pending state list is invalid") end
  local actions = {}
  for index, state_ref in ipairs(states) do
    if index > limit then break end
    local state = ports.load_state(state_ref)
    if type(state) == "table" then
      for _, pending in ipairs(state.pending_actions or {}) do table.insert(actions, copy(pending)) end
    end
  end
  return actions
end

local function add_error(errors, id, message)
  table.insert(errors, { id = id, message = message })
end

function M.saga_conformance_errors()
  local errors = {}
  local request = {
    schema = M.schemas.request,
    module = "conformance-module",
    backend = "fkst-native",
    preflight_result = {
      schema = "browser-readiness.result.v1",
      status = "ready",
      request_context = { native_argv = { "conformance-module-check" }, dry_run = false, no_browser = true },
    },
    artifact_root = ".testing/runs/conformance-module",
    source_ref = { kind = "host-module", ref = "conformance-module" },
    trace_id = "trace-conformance-module",
    dedup_key = "conformance-module-run",
  }
  local ok, runner = pcall(M.runner_request, request)
  if not ok then add_error(errors, "module-test-loop.saga.runner-request", tostring(runner))
  elseif runner.schema ~= "testing-runner.module-test-loop.request.v1" then
    add_error(errors, "module-test-loop.saga.schema", "runner request schema differs")
  end
  return errors
end

return M
