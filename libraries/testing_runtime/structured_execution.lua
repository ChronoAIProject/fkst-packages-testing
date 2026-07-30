local runtime_client = require("testing_runtime.runtime_client")

local M = {}
local default_runtime_cli = "libraries/testing_runtime/bin/fkst-structured-execution-runtime.js"

local function run_root(path)
  if type(path) ~= "string" then return nil end
  return path:match("^(.testing/runs/[^/]+)")
end

local function request_root(payload)
  return run_root(payload.artifact_root)
    or run_root(payload.result_ref)
    or run_root(type(payload.artifact_ref) == "table" and payload.artifact_ref.ref)
end

local function client(options)
  local injected_transport = type(options) == "table" and options.exec_argv ~= nil
    and options.file ~= nil and options.json ~= nil
  local configured = {}
  for key, value in pairs(options or {}) do configured[key] = value end
  local getenv = type(configured.getenv) == "function" and configured.getenv or os.getenv
  local global_cli = rawget(_G, "structured_execution_runtime_cli")
  local global_config = rawget(_G, "structured_execution_runtime_config_ref")
  if global_cli ~= nil then configured.runtime_cli = global_cli
  elseif configured.runtime_cli == nil then
    configured.runtime_cli = getenv("FKST_STRUCTURED_EXECUTION_RUNTIME_CLI")
  end
  if global_config ~= nil then configured.runtime_config_ref = global_config
  elseif configured.runtime_config_ref == nil then
    configured.runtime_config_ref = getenv("FKST_STRUCTURED_EXECUTION_RUNTIME_CONFIG_REF")
  end
  if configured.exec_argv == nil then configured.exec_argv = exec_argv end
  if configured.file == nil then configured.file = file end
  if configured.json == nil then configured.json = json end
  return runtime_client.new({
    cli_global = "structured_execution_runtime_cli",
    cli_env = "FKST_STRUCTURED_EXECUTION_RUNTIME_CLI",
    default_runtime_cli = default_runtime_cli,
    config_global = "structured_execution_runtime_config_ref",
    config_env = "FKST_STRUCTURED_EXECUTION_RUNTIME_CONFIG_REF",
    error_prefix = "testing-runtime: structured-execution",
    runtime_config_required = true,
    runtime_config_unavailable_error = "testing-runtime: structured-execution-runtime-config-unavailable",
    runtime_config_context = function(_request, root) return { artifact_root = root } end,
    validate_runtime_config = function(value, context)
      local root = context.artifact_root
      if value.ref == root or value.ref:sub(1, #root + 1) == root .. "/" then
        error("testing-runtime: structured-execution-runtime-config-inside-run-root")
      end
    end,
    io_root = function(root) return root .. "/structured-runtime" end,
    io_root_invalid_error = "testing-runtime: structured-execution-runtime-io-root-invalid",
    io_root_unavailable_error = "testing-runtime: structured-execution-runtime-io-root-unavailable",
    cli_invalid_error = "testing-runtime: structured-execution-runtime-cli-invalid",
    exec_port_error = "testing-runtime: structured-execution-exec-port-unavailable",
    file_port_error = "testing-runtime: structured-execution-file-port-unavailable",
    json_port_error = "testing-runtime: structured-execution-json-port-unavailable",
    allow_legacy_response = function(cli)
      return cli == default_runtime_cli or cli:match("^fixtures/") ~= nil or injected_transport
    end,
    include_request_id = function(cli) return cli ~= default_runtime_cli end,
    skip_io_prepare = function() return injected_transport end,
  }, configured)
end

local function call_cli(name, payload, timeout, options)
  local root = request_root(payload)
  if root == nil then error("testing-runtime: structured-execution-run-root-missing") end
  local identity = payload.case_id or (type(payload.artifact_ref) == "table" and payload.artifact_ref.ref)
    or payload.result_ref or payload.grant_id or payload.operation_id or payload.trace_id or name
  return client(options).call(name, payload, root, identity, timeout)
end

function M.production(options)
  return {
    load_artifact = function(path)
      return call_cli("load-artifact", {
        artifact_ref = { kind = "artifact", ref = path },
        artifact_root = run_root(path),
      }, 15, options)
    end,
    now = function(request)
      return call_cli("now", request, 15, options).now
    end,
    verify_grant = function(request)
      return call_cli("verify-grant", request, 15, options)
    end,
    replay_guard = function(request)
      return call_cli("replay-guard", request, 15, options)
    end,
    exec_argv = function(request)
      return call_cli("exec-argv", request, (request.timeout_seconds or 30) + 3, options)
    end,
    http_request = function(request)
      return call_cli("http-request", request, (request.timeout_seconds or 30) + 3, options)
    end,
    write_artifact = function(path, value)
      local result = call_cli("write-artifact", {
        artifact_ref = { kind = "artifact", ref = path },
        artifact_root = run_root(path),
        value = value,
      }, 15, options)
      return type(result) == "table" and result.written == true
    end,
    load_result = function(request)
      return call_cli("load-result", request, 15, options)
    end,
    complete_replay = function(request)
      local result = call_cli("complete-replay", request, 15, options)
      return type(result) == "table" and result.completed == true
    end,
  }
end

return M
