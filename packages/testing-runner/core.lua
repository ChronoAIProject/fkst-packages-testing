local M = {}

local fkst_native = require("fkst_native")
local module_cdp_execution = require("module_cdp_execution")
local module_ai_design_loop = require("module_ai_design_loop")
local module_inventory = require("module_inventory")
local testing_contract = require("contract.testing")

local max_string = 512
local max_path = 4096
local max_excerpt = 600
local max_ui_list = 16

local jobs = {
  module = {
    request_schema = "testing-runner.module-test-loop.request.v1",
    subcommand = "module-test-loop",
    output_job = "module-test-loop",
  },
  platform = {
    request_schema = "testing-runner.platform-test-loop.request.v1",
    subcommand = "platform-test-loop",
    output_job = "platform-test-loop",
  },
  online_regression = {
    request_schema = "testing-runner.online-regression.request.v1",
    subcommand = "online-regression-heartbeat",
    output_job = "online-regression",
  },
}

local function bounded_string(value, limit)
  return type(value) == "string" and value ~= "" and #value <= limit
end
M.bounded_string = bounded_string

local function quote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end
M.shell_single_quote = quote

local function dense_list(value)
  if type(value) ~= "table" then
    return false
  end
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
M.dense_list = dense_list

local function safe_key(value)
  local text = tostring(value or "planned")
  text = text:gsub("[^%w%._%-]", "-")
  text = text:gsub("%.+", ".")
  text = text:gsub("^%.", "")
  if text == "" then text = "planned" end
  if #text > 180 then text = text:sub(1, 180) end
  return text
end
M.safe_key = safe_key

local function safe_artifact_root(value)
  if not bounded_string(value, max_path) then return false end
  if value:sub(1, 14) ~= ".testing/runs/" then return false end
  if value:find("..", 1, true) ~= nil or value:find("\0", 1, true) ~= nil then return false end
  return true
end
M.safe_artifact_root = safe_artifact_root

local function spec_for(job)
  local spec = jobs[job]
  if spec == nil then
    error("testing-runner: unknown-job: " .. tostring(job))
  end
  return spec
end
M.spec_for = spec_for

function M.resolve_backend(payload)
  local backend = type(payload) == "table" and payload.backend or nil
  backend = backend or "fkst-native"
  if backend ~= "agentic-testing-cli" and backend ~= "fkst-native" then
    error("testing-runner: unknown-backend: " .. tostring(backend))
  end
  return backend
end

local function validate_preflight(value)
  if value == nil then return end
  if type(value) ~= "table" then
    error("testing-runner: malformed-request: preflight_result must be a table")
  end
  if not bounded_string(value.status, 80) then
    error("testing-runner: malformed-request: preflight_result.status is required")
  end
end

local function http_url(value)
  return bounded_string(value, max_string) and value:match("^https?://") ~= nil
end

local function ui_control_ref(value)
  return testing_contract.is_bounded_id(value) or safe_artifact_root(value)
end

local function validate_allowed_origins(value)
  if not dense_list(value) or #value == 0 or #value > max_ui_list then
    error("testing-runner: malformed-request: ui_loop.allowed_origins must be a non-empty bounded list")
  end
  for _, item in ipairs(value) do
    if not http_url(item) then
      error("testing-runner: malformed-request: ui_loop.allowed_origins must contain http origins")
    end
  end
end

local function validate_priority(value)
  if value == nil then return end
  if not dense_list(value) or #value > max_ui_list then
    error("testing-runner: malformed-request: ui_loop.priority must be a bounded dense list")
  end
  for _, item in ipairs(value) do
    if not testing_contract.is_bounded_id(item) then
      error("testing-runner: malformed-request: ui_loop.priority items must be bounded strings")
    end
  end
end

local function validate_mutation_policy(value)
  if value == nil then return end
  if value ~= "read-only" and value ~= "dry-run" and value ~= "host-approved" then
    error("testing-runner: malformed-request: ui_loop.mutation_policy is unknown")
  end
end

local function validate_ui_loop(value)
  if value == nil then return end
  if type(value) ~= "table" then
    error("testing-runner: malformed-request: ui_loop must be a table")
  end
  local allowed = {
    base_url = true,
    allowed_origins = true,
    browser_readiness_ref = true,
    cdp_readiness_ref = true,
    artifact_root = true,
    dry_run = true,
    priority = true,
    mutation_policy = true,
    gap_ref = true,
    backlog_ref = true,
    platform_flow_ref = true,
  }
  for key, _ in pairs(value) do
    if allowed[key] ~= true then
      error("testing-runner: malformed-request: ui_loop contains unsupported field")
    end
  end
  if not bounded_string(value.base_url, max_string) then
    error("testing-runner: malformed-request: ui_loop.base_url must be a bounded string")
  end
  validate_allowed_origins(value.allowed_origins)
  validate_priority(value.priority)
  validate_mutation_policy(value.mutation_policy)
  if value.browser_readiness_ref ~= nil and not ui_control_ref(value.browser_readiness_ref) then
    error("testing-runner: malformed-request: ui_loop.browser_readiness_ref must be a bounded pointer")
  end
  if value.cdp_readiness_ref ~= nil and not ui_control_ref(value.cdp_readiness_ref) then
    error("testing-runner: malformed-request: ui_loop.cdp_readiness_ref must be a bounded pointer")
  end
  if value.artifact_root ~= nil and not safe_artifact_root(value.artifact_root) then
    error("testing-runner: malformed-request: ui_loop.artifact_root must be a safe .testing/runs/... path")
  end
  if value.dry_run ~= nil and type(value.dry_run) ~= "boolean" then
    error("testing-runner: malformed-request: ui_loop.dry_run must be boolean")
  end
  if value.gap_ref ~= nil and not ui_control_ref(value.gap_ref) then
    error("testing-runner: malformed-request: ui_loop.gap_ref must be a bounded pointer")
  end
  if value.backlog_ref ~= nil and not ui_control_ref(value.backlog_ref) then
    error("testing-runner: malformed-request: ui_loop.backlog_ref must be a bounded pointer")
  end
  if value.platform_flow_ref ~= nil and not ui_control_ref(value.platform_flow_ref) then
    error("testing-runner: malformed-request: ui_loop.platform_flow_ref must be a bounded pointer")
  end
end

local function validate_native_argv(job, value)
  if value == nil then return end
  if job ~= "module" then
    error("testing-runner: malformed-request: native_argv is only supported for module jobs")
  end
  if not dense_list(value) or #value == 0 then
    error("testing-runner: malformed-request: native_argv must be a non-empty dense list")
  end
  for _, item in ipairs(value) do
    if not bounded_string(item, max_string) then
      error("testing-runner: malformed-request: native_argv items must be bounded strings")
    end
  end
end

function M.validate_request(job, payload)
  local spec = spec_for(job)
  if type(payload) ~= "table" then
    error("testing-runner: malformed-request: payload must be a table")
  end
  if payload.schema ~= spec.request_schema then
    error("testing-runner: unknown-schema: expected " .. spec.request_schema)
  end
  M.resolve_backend(payload)
  validate_preflight(payload.preflight_result)
  validate_native_argv(job, payload.native_argv)
  if job ~= "module" and payload.ui_loop ~= nil then
    error("testing-runner: malformed-request: ui_loop is only supported for module jobs")
  end
  validate_ui_loop(payload.ui_loop)
  module_ai_design_loop.validate_authority_fields(payload)
  if payload.ai_design_loop_request ~= nil then
    error("testing-runner: ai-design-loop-incomplete: request must be replaced by reviewed state")
  end
  if payload.ai_design_loop_state_ref ~= nil and job ~= "module" then
    error("testing-runner: malformed-request: ai_design_loop_state_ref is only supported for module jobs")
  end
  if payload.cdp_execution ~= nil then
    if job ~= "module" then
      error("testing-runner: malformed-request: cdp_execution is only supported for module jobs")
    end
    if payload.ui_loop == nil then
      error("testing-runner: malformed-request: cdp_execution requires ui_loop scope")
    end
    module_cdp_execution.validate_request(payload.cdp_execution)
  end
  if payload.module_discovery ~= nil then
    if job ~= "module" then
      error("testing-runner: malformed-request: module_discovery is only supported for module jobs")
    end
    if payload.ui_loop == nil then
      error("testing-runner: malformed-request: module_discovery requires ui_loop scope")
    end
    module_inventory.validate_request(payload.module_discovery)
  end
  if job == "module" and not bounded_string(payload.module, max_string) then
    error("testing-runner: malformed-request: module is required")
  end
  if job == "platform" and payload.modules ~= nil and not dense_list(payload.modules) then
    error("testing-runner: malformed-request: modules must be a dense list")
  end
  if job == "online_regression" and payload.heartbeat_url ~= nil and not http_url(payload.heartbeat_url) then
    error("testing-runner: malformed-request: heartbeat_url must be an http URL")
  end
  if payload.artifact_root ~= nil and not safe_artifact_root(payload.artifact_root) then
    error("testing-runner: malformed-request: artifact_root must be a safe .testing/runs/... path")
  end
  if payload.trace_id ~= nil and not testing_contract.is_bounded_id(payload.trace_id) then
    error("testing-runner: malformed-request: trace_id must be a bounded string")
  end
  if payload.dedup_key ~= nil and not testing_contract.is_bounded_id(payload.dedup_key) then
    error("testing-runner: malformed-request: dedup_key must be a bounded string")
  end
  return payload
end

function M.artifact_root(job, payload)
  if bounded_string(payload.artifact_root, max_path) then
    return payload.artifact_root
  end
  return ".testing/runs/" .. safe_key(payload.run_id or payload.dedup_key or payload.module or job)
end

function M.argv(job, payload)
  M.validate_request(job, payload)
  if payload.native_argv ~= nil then return payload.native_argv end
  return {}
end

function M.command(job, payload)
  M.validate_request(job, payload)
  local quoted = {}
  for _, value in ipairs(M.argv(job, payload)) do
    table.insert(quoted, quote(value))
  end
  return table.concat(quoted, " ")
end

local function excerpt(value)
  local text = tostring(value or "")
  if #text > max_excerpt then
    return text:sub(1, max_excerpt)
  end
  return text
end

local function source_ref(payload)
  return testing_contract.copy_source_ref(
    payload.source_ref,
    "testing-runner-request",
    safe_key(payload.dedup_key or payload.run_id or payload.module or "planned")
  )
end
M.source_ref = source_ref

local function trace_id(payload, src, artifact_root)
  return testing_contract.trace_id(payload.trace_id, src, artifact_root)
end

local function dedup_key(payload, src, artifact_root, job)
  return testing_contract.dedup_key(payload.dedup_key, {
    "testing-runner",
    job,
    src.kind,
    src.ref,
    artifact_root,
  })
end

function M.result_payload(job, payload, status, opts)
  local spec = spec_for(job)
  opts = opts or {}
  local artifact_root = M.artifact_root(job, payload)
  local src = source_ref(payload)
  local result = {
    schema = testing_contract.schemas.runner_result,
    job = spec.output_job,
    status = status,
    artifact_root = artifact_root,
    source_ref = src,
    trace_id = trace_id(payload, src, artifact_root),
    dedup_key = dedup_key(payload, src, artifact_root, spec.output_job),
    adapter = opts.adapter or { name = M.resolve_backend(payload) },
  }
  if opts.exit_code ~= nil then result.exit_code = opts.exit_code end
  if opts.stderr ~= nil then result.stderr_excerpt = excerpt(opts.stderr) end
  return result
end

local function adapter_context(job, payload)
  return {
    spec = spec_for(job),
    dense_list = dense_list,
    quote = quote,
    result_payload = function(status, opts)
      return M.result_payload(job, payload, status, opts)
    end,
  }
end

local function normalize_dependencies(value)
  if value == nil then return {} end
  if type(value) == "function" then return { exec = value } end
  if type(value) ~= "table" then
    error("testing-runner: invalid-dependencies: expected function or table")
  end
  for key, _ in pairs(value) do
    if key ~= "exec" and key ~= "runtime_ports" then
      error("testing-runner: invalid-dependencies: unsupported field " .. tostring(key))
    end
  end
  if value.exec ~= nil and type(value.exec) ~= "function" then
    error("testing-runner: invalid-dependencies: exec must be a function")
  end
  if value.runtime_ports ~= nil then
    if type(value.runtime_ports) ~= "table" then
      error("testing-runner: invalid-dependencies: runtime_ports must be a table")
    end
    for _, name in ipairs({ "exec_argv", "read", "write", "decode" }) do
      if type(value.runtime_ports[name]) ~= "function" then
        error("testing-runner: invalid-dependencies: runtime_ports." .. name .. " must be a function")
      end
    end
  end
  return { exec = value.exec, runtime_ports = value.runtime_ports }
end

function M.run(job, payload, dependencies)
  M.validate_request(job, payload)
  local backend = M.resolve_backend(payload)
  local context = adapter_context(job, payload)
  if backend == "fkst-native" then
    return fkst_native.run(job, payload, context, normalize_dependencies(dependencies))
  end
  return M.result_payload(job, payload, "blocked", {
    adapter = { name = "fkst-native", mode = "legacy-backend-blocked" },
    stderr = "testing-runner legacy agentic-testing backend is not executable",
  })
end

return M
