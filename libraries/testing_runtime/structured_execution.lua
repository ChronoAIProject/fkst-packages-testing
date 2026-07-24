local json_codec = require("testing_runtime.json")

local M = {}
local default_runtime_cli = "libraries/testing_runtime/bin/fkst-structured-execution-runtime.js"

local function safe_label(value)
  local label = tostring(value or "request"):gsub("[^A-Za-z0-9._-]", "-")
  return label:sub(1, 160)
end

local function run_root(path)
  if type(path) ~= "string" then return nil end
  return path:match("^(.testing/runs/[^/]+)")
end

local function request_root(payload)
  return run_root(payload.artifact_root)
    or run_root(payload.result_ref)
    or run_root(type(payload.artifact_ref) == "table" and payload.artifact_ref.ref)
end

local function configured_runtime_cli(options)
  local value = rawget(_G, "structured_execution_runtime_cli")
  if value == nil and type(options) == "table" then value = options.runtime_cli end
  if value == nil then value = os.getenv("FKST_STRUCTURED_EXECUTION_RUNTIME_CLI") end
  if value == nil then value = default_runtime_cli end
  if type(value) ~= "string" or value == "" or #value > 4096 or value:find("[%z\1-\31\127]") then
    error("testing-runtime: structured-execution-runtime-cli-invalid")
  end
  return value
end

local function configured_runtime_ref(root, options)
  local value = rawget(_G, "structured_execution_runtime_config_ref")
  if value == nil and type(options) == "table" then value = options.runtime_config_ref end
  if type(value) == "function" then value = value({ artifact_root = root }) end
  if type(value) ~= "table" or value.kind ~= "artifact" or type(value.ref) ~= "string" then
    error("testing-runtime: structured-execution-runtime-config-unavailable")
  end
  if value.ref == root or value.ref:sub(1, #root + 1) == root .. "/" then
    error("testing-runtime: structured-execution-runtime-config-inside-run-root")
  end
  return { kind = value.kind, ref = value.ref }
end

local function option_or(options, name, fallback)
  if type(options) == "table" and options[name] ~= nil then return options[name] end
  return fallback
end

local function host_ports(options)
  local host = {
    exec_argv = option_or(options, "exec_argv", exec_argv),
    file = option_or(options, "file", file),
    json = option_or(options, "json", json),
  }
  if type(host.exec_argv) ~= "function" then error("testing-runtime: structured-execution-exec-port-unavailable") end
  if type(host.file) ~= "table" or type(host.file.write) ~= "function" or type(host.file.read) ~= "function" then
    error("testing-runtime: structured-execution-file-port-unavailable")
  end
  if type(host.json) ~= "table" or type(host.json.decode) ~= "function" then
    error("testing-runtime: structured-execution-json-port-unavailable")
  end
  return host
end

local function call_cli(name, payload, timeout, options)
  local host = host_ports(options)
  local root = request_root(payload)
  if root == nil then error("testing-runtime: structured-execution-run-root-missing") end
  payload.runtime_config_ref = configured_runtime_ref(root, options)
  local io_root = root .. "/structured-runtime"
  local identity = payload.case_id or (type(payload.artifact_ref) == "table" and payload.artifact_ref.ref)
    or payload.result_ref or payload.grant_id or payload.operation_id or payload.trace_id or name
  local label = safe_label(identity)
  local request_path = io_root .. "/" .. safe_label(name) .. "-" .. label .. "-request.json"
  local response_path = io_root .. "/" .. safe_label(name) .. "-" .. label .. "-response.json"
  host.file.write(request_path, json_codec.encode(payload) .. "\n")
  local result = host.exec_argv({
    argv = { "node", configured_runtime_cli(options), "effect", "--name", name,
      "--request", request_path, "--response", response_path },
    timeout = timeout or 30,
  })
  if type(result) ~= "table" or tonumber(result.exit_code) ~= 0 then
    error("testing-runtime: structured-execution-runtime-effect-failed: " .. name)
  end
  local decoded = host.json.decode(host.file.read(response_path))
  if type(decoded) ~= "table" or decoded.ok ~= true then
    error("testing-runtime: structured-execution-runtime-effect-invalid: " .. name)
  end
  return decoded.result
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
