local M = {}

local agentic_cli = require("agentic_cli")
local fkst_native = require("fkst_native")
local testing_contract = require("contract.testing")

local max_string = 512
local max_path = 4096
local max_excerpt = 600

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
  backend = backend or "agentic-testing-cli"
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

local forbidden_event_fields = {
  native_evidence = true,
  evidence = true,
  screenshots = true,
  screenshot = true,
  screenshot_ref = true,
  dom_state = true,
  console = true,
  network = true,
  traces = true,
  trace = true,
}

local function is_forbidden_event_field(key)
  local text = tostring(key or ""):lower()
  if forbidden_event_fields[text] then return true end
  if text:find("_body$", 1) ~= nil then return true end
  if text:find("storage", 1, true) ~= nil then return true end
  if text:find("credential", 1, true) ~= nil then return true end
  if text:find("secret", 1, true) ~= nil then return true end
  if text:find(("coo" .. "kie"), 1, true) ~= nil then return true end
  if text:find(("pass" .. "word"), 1, true) ~= nil then return true end
  if text:find(("to" .. "ken"), 1, true) ~= nil then return true end
  if text:find("authorization", 1, true) ~= nil then return true end
  return false
end

local function validate_pointer_only_request(payload, depth)
  if type(payload) ~= "table" then return end
  if (depth or 0) > 8 then
    error("testing-runner: malformed-request: payload is too deeply nested")
  end
  for key, _ in pairs(payload) do
    if is_forbidden_event_field(key) then
      error("testing-runner: malformed-request: " .. key .. " must be written as an artifact, not embedded in the event")
    end
  end
  for _, value in pairs(payload) do
    if type(value) == "table" then
      validate_pointer_only_request(value, (depth or 0) + 1)
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
  validate_pointer_only_request(payload)
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
  return agentic_cli.argv(job, payload, spec_for(job), dense_list)
end

function M.command(job, payload)
  M.validate_request(job, payload)
  return agentic_cli.command(job, payload, spec_for(job), dense_list, quote)
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

function M.run(job, payload, exec)
  M.validate_request(job, payload)
  local backend = M.resolve_backend(payload)
  local context = adapter_context(job, payload)
  if backend == "fkst-native" then
    return fkst_native.run(job, payload, context, exec)
  end
  return agentic_cli.run(job, payload, context, exec)
end

return M
