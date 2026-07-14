local M = {}

local fkst_native = require("fkst_native")
local module_cdp_execution = require("module_cdp_execution")
local module_inventory = require("module_inventory")
local strings = require("contract.strings")
local testing_contract = require("contract.testing")
local artifact_attempt = require("testing_runtime.artifact_attempt")
local artifact_manifest = require("testing_runtime.artifact_manifest")
local run_ledger = require("testing_runtime.run_ledger")

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

local function durable_replay_path(job, payload)
  return job == "module"
    and M.resolve_backend(payload) == "fkst-native"
    and payload.dry_run == false
    and payload.no_browser == true
    and payload.native_argv ~= nil
    and testing_contract.is_bounded_id(payload.trace_id)
    and testing_contract.is_bounded_id(payload.dedup_key)
    and payload.artifact_writer == nil
end

local function run_identity(job, payload)
  return {
    schema = run_ledger.identity_schema,
    job = spec_for(job).output_job,
    trace_id = payload.trace_id,
    dedup_key = payload.dedup_key,
  }
end

local function attempt_intent(identity, fence_version)
  return {
    schema = "test-artifacts.attempt-commit-intent.v1",
    run_id = safe_key(identity.job .. "-" .. identity.dedup_key),
    trace_id = identity.trace_id,
    dedup_key = identity.dedup_key,
    artifact_kind = "testing-run",
    attempt_id = "attempt-1",
    fence_version = fence_version,
  }
end

local function staging_writer(staged_root, artifact_pointer)
  local prefix = artifact_pointer .. "/"
  local recorded = {}
  local function write(path, body)
    if type(path) ~= "string" or path:sub(1, #prefix) ~= prefix then return nil, "artifact path is outside the acquired attempt" end
    local relative = path:sub(#prefix + 1)
    if relative == "" or relative:find("..", 1, true) ~= nil or relative:find("\\", 1, true) ~= nil then return nil, "artifact path is unsafe" end
    if recorded[relative] then return nil, "staged artifact overwrite is forbidden" end
    local target = staged_root .. "/" .. relative
    local directory = target:match("^(.*)/[^/]+$")
    local ok = os.execute("mkdir -p " .. quote(directory))
    if ok ~= true and ok ~= 0 then return nil, "failed to create staging directory" end
    local existing = io.open(target, "r")
    if existing ~= nil then existing:close(); return nil, "staged artifact already exists" end
    local handle, open_error = io.open(target, "w")
    if handle == nil then return nil, open_error or "failed to open staged artifact" end
    local wrote, write_error = handle:write(body)
    handle:close()
    if not wrote then return nil, write_error or "failed to write staged artifact" end
    recorded[relative] = true
    return true
  end
  local function paths()
    local values = {}
    for relative, _ in pairs(recorded) do table.insert(values, relative) end
    table.sort(values)
    return values
  end
  return write, paths
end

local function cleanup_staging(staged_root)
  if not safe_artifact_root(staged_root) or staged_root:find("/staged-attempts/", 1, true) == nil then return end
  pcall(os.execute, "rm -rf -- " .. quote(staged_root))
end

local function run_durable(job, payload, dependencies)
  local identity = run_identity(job, payload)
  local ledger = run_ledger.new(dependencies.runtime_ports)
  local existing = ledger:lookup(identity)
  if existing ~= nil then
    if existing.state ~= "completed" then error("testing-runner: durable-run-incomplete: acquired run has no terminal result") end
    return existing.terminal_result, true
  end

  local acquired, created = ledger:acquire(identity)
  if not created and acquired.state == "completed" then return acquired.terminal_result, true end
  if not created then error("testing-runner: durable-run-contended: another delivery acquired the run") end

  local intent = attempt_intent(identity, acquired.fence_version)
  local attempts = artifact_attempt.new(dependencies.runtime_ports)
  local artifact_pointer = attempts:artifact_pointer(intent)
  local durable_generation = strings.decimal_checksum(tostring(os.getenv("FKST_DURABLE_ROOT") or "default"))
  local staged_root = ".testing/runs/" .. intent.run_id .. "/staged-attempts/" .. intent.attempt_id
    .. "/fence-" .. tostring(intent.fence_version) .. "-" .. durable_generation
  local write, staged_paths = staging_writer(staged_root, artifact_pointer)
  local execution_payload = {}
  for key, value in pairs(payload) do execution_payload[key] = value end
  execution_payload.artifact_root = artifact_pointer
  execution_payload.artifact_writer = write

  local result = fkst_native.run(job, execution_payload, adapter_context(job, execution_payload), dependencies)
  if result.artifact_root ~= artifact_pointer or result.trace_id ~= identity.trace_id or result.dedup_key ~= identity.dedup_key then error("testing-runner: durable-result-mismatch: terminal result identity changed") end
  local paths = staged_paths()
  if #paths == 0 then error("testing-runner: durable-artifacts-empty: run produced no staged artifacts") end
  artifact_manifest.build_staged(staged_root, artifact_pointer, paths, dependencies.runtime_ports)
  local completion = attempts:commit(intent, staged_root)
  local verified = attempts:lookup(intent)
  if verified == nil or verified.artifact_pointer ~= completion.artifact_pointer or verified.manifest_sha256 ~= completion.manifest_sha256 then error("testing-runner: durable-attempt-invalid: artifact attempt verification failed") end
  cleanup_staging(staged_root)
  local completed = ledger:complete(identity, acquired.fence_version, verified, result)
  return completed.terminal_result, false
end

function M.run(job, payload, dependencies)
  M.validate_request(job, payload)
  local backend = M.resolve_backend(payload)
  local context = adapter_context(job, payload)
  local normalized = normalize_dependencies(dependencies)
  if backend == "fkst-native" then
    if durable_replay_path(job, payload) then return run_durable(job, payload, normalized) end
    return fkst_native.run(job, payload, context, normalized)
  end
  return M.result_payload(job, payload, "blocked", {
    adapter = { name = "fkst-native", mode = "legacy-backend-blocked" },
    stderr = "testing-runner legacy agentic-testing backend is not executable",
  })
end

return M
