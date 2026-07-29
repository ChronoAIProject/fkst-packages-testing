local json_codec = require("testing_runtime.json")

local M = {}
local host_os = os
local request_sequence = 0

local function safe_label(value)
  local label = tostring(value or "request"):gsub("[^A-Za-z0-9._-]", "-")
  return label:sub(1, 160)
end

local function bounded_text(value, limit)
  local text = tostring(value or ""):gsub("[%z\1-\31\127]", " "):gsub("%s+", " ")
  return text:sub(1, limit or 1024)
end

local function configured_value(spec, options, global_name, option_name, environment_name, fallback)
  local value = type(global_name) == "string" and _G[global_name] or nil
  if value == nil and type(options) == "table" then value = options[option_name] end
  if value == nil and type(environment_name) == "string" then
    local configured_os = _G.os
    local getenv = type(configured_os) == "table" and configured_os.getenv or host_os.getenv
    value = getenv(environment_name)
  end
  if value == nil then value = fallback end
  return value
end

local function option_or(options, name, fallback)
  if type(options) == "table" and options[name] ~= nil then return options[name] end
  return fallback
end

local function valid_path(value)
  return type(value) == "string" and value ~= "" and #value <= 4096
    and value:find("[%z\1-\31\127]") == nil
end

local function valid_io_root(value)
  return valid_path(value) and value:sub(1, 9) == ".testing/"
    and value:find("\\", 1, true) == nil and value:find("..", 1, true) == nil
end

local function next_request_id(error_prefix)
  local temporary = host_os.tmpname()
  if type(temporary) ~= "string" or temporary == "" then
    error(error_prefix .. "-runtime-request-id-unavailable")
  end
  pcall(host_os.remove, temporary)
  local basename = temporary:gsub("\\", "/"):match("([^/]+)$")
  if type(basename) ~= "string" or basename == "" then
    error(error_prefix .. "-runtime-request-id-unavailable")
  end
  request_sequence = request_sequence + 1
  return safe_label(basename) .. "-" .. tostring(request_sequence)
end

local function prepare_io(ports, io_root, request_path, response_path, spec, name)
  if not valid_io_root(io_root) then
    error(spec.io_root_invalid_error or (spec.error_prefix .. "-runtime-io-root-invalid"))
  end
  local result = ports.exec_argv({
    argv = {
      "node", "-e",
      "const fs=require('fs'),r=process.argv[1],q=process.argv[2],s=process.argv[3];"
        .. "if(!r.startsWith('.testing/')||r.includes('..')||r.includes('\\\\'))process.exit(52);"
        .. "if(!q.startsWith(r+'/')||!s.startsWith(r+'/'))process.exit(52);"
        .. "fs.mkdirSync(r,{recursive:true});if(fs.existsSync(q)||fs.existsSync(s))process.exit(53);",
      io_root, request_path, response_path,
    },
    timeout = 5,
  })
  local exit_code = type(result) == "table" and tonumber(result.exit_code) or nil
  if exit_code == 53 then
    error(spec.stale_response_error or (spec.error_prefix .. "-runtime-response-stale: " .. name))
  end
  if exit_code ~= 0 then
    error(spec.io_root_unavailable_error or (spec.error_prefix .. "-runtime-io-root-unavailable"))
  end
end

function M.new(spec, options)
  options = options or {}
  local client = {}

  local function runtime_cli()
    local value = configured_value(spec, options, spec.cli_global, "runtime_cli", spec.cli_env,
      spec.default_runtime_cli)
    if not valid_path(value) then
      error(spec.cli_invalid_error or (spec.error_prefix .. "-runtime-cli-unavailable"))
    end
    return value
  end

  function client.configured()
    return configured_value(spec, options, spec.cli_global, "runtime_cli", spec.cli_env,
      spec.default_runtime_cli) ~= nil
  end

  local function runtime_config_ref(request, root, name)
    local value = configured_value(spec, options, spec.config_global, "runtime_config_ref",
      spec.config_env, spec.default_runtime_config_ref)
    local context = type(spec.runtime_config_context) == "function"
      and spec.runtime_config_context(request, root, name) or { artifact_root = root }
    if type(value) == "function" then value = value(context) end
    if value == nil then
      if spec.runtime_config_required then
        error(spec.runtime_config_unavailable_error or (spec.error_prefix .. "-runtime-config-unavailable"))
      end
      return nil
    end
    if type(value) == "string" then value = { kind = "artifact", ref = value } end
    if type(value) ~= "table" or value.kind ~= "artifact" or not valid_path(value.ref) then
      error(spec.runtime_config_invalid_error or (spec.error_prefix .. "-runtime-config-invalid"))
    end
    local normalized = { kind = "artifact", ref = value.ref }
    if type(spec.validate_runtime_config) == "function" then
      spec.validate_runtime_config(normalized, context, request, root, name)
    end
    return normalized
  end

  local function host_ports()
    local ports = {
      exec_argv = option_or(options, "exec_argv", exec_argv),
      file = option_or(options, "file", file),
      json = option_or(options, "json", json),
    }
    if type(ports.exec_argv) ~= "function" then
      error(spec.exec_port_error or (spec.error_prefix .. "-exec-port-unavailable"))
    end
    if type(ports.file) ~= "table" or type(ports.file.write) ~= "function"
      or type(ports.file.read) ~= "function" then
      error(spec.file_port_error or (spec.error_prefix .. "-file-port-unavailable"))
    end
    if type(ports.json) ~= "table" or type(ports.json.decode) ~= "function" then
      error(spec.json_port_error or (spec.error_prefix .. "-json-port-unavailable"))
    end
    return ports
  end

  local function legacy_response_allowed(cli, request, name)
    if type(spec.allow_legacy_response) == "function" then
      return spec.allow_legacy_response(cli, options, request, name) == true
    end
    return spec.allow_legacy_response == true
  end

  local function read_response(ports, response_path)
    local read_ok, body = pcall(ports.file.read, response_path)
    if not read_ok or type(body) ~= "string" then return nil end
    local decode_ok, decoded = pcall(ports.json.decode, body)
    if not decode_ok or type(decoded) ~= "table" then return false end
    return decoded
  end

  local function validate_request_id(decoded, request_id, allow_legacy, name)
    if decoded.request_id == nil then
      if allow_legacy then return end
      error(spec.request_id_missing_error
        or (spec.error_prefix .. "-runtime-response-request-id-missing: " .. name))
    end
    if decoded.request_id ~= request_id then
      error(spec.request_id_mismatch_error
        or (spec.error_prefix .. "-runtime-response-request-id-mismatch: " .. name))
    end
  end

  local function failure_message(name, exit_code, result, decoded)
    if type(spec.effect_failure_message) == "function" then
      return spec.effect_failure_message(name, exit_code, result, decoded)
    end
    local message = spec.error_prefix .. "-runtime-effect-failed: " .. name
      .. " exit=" .. tostring(exit_code or -1)
      .. " stderr=" .. bounded_text(type(result) == "table" and result.stderr or "", 1024)
    if type(decoded) == "table" and type(decoded.error) == "string" then
      message = message .. " Host error=" .. bounded_text(decoded.error, 1024)
    end
    return message
  end

  function client.call(name, payload, root, identity, timeout, listener_options)
    local ports = host_ports()
    local cli = runtime_cli()
    local request = {}
    for key, value in pairs(payload or {}) do request[key] = value end
    local request_id = next_request_id(spec.error_prefix)
    local include_request_id = type(spec.include_request_id) ~= "function"
      or spec.include_request_id(cli, options, request, name) ~= false
    if include_request_id then request.request_id = request_id end
    request.runtime_config_ref = runtime_config_ref(request, root, name)
    local io_root = root or spec.scratch_root
    if type(spec.io_root) == "function" then io_root = spec.io_root(root, request, name) end
    local label = safe_label(identity or request.run_id or request.dedup_key or name)
    local stem = safe_label(name) .. "-" .. label .. "-" .. request_id
    local request_path = io_root .. "/" .. stem .. "-request.json"
    local response_path = io_root .. "/" .. stem .. "-response.json"
    local skip_prepare = type(spec.skip_io_prepare) == "function"
      and spec.skip_io_prepare(options, request, name) == true
    if skip_prepare then
      if not valid_io_root(io_root) then
        error(spec.io_root_invalid_error or (spec.error_prefix .. "-runtime-io-root-invalid"))
      end
    else
      prepare_io(ports, io_root, request_path, response_path, spec, name)
    end
    ports.file.write(request_path, json_codec.encode(request) .. "\n")

    local exec_request = {
      argv = { "node", cli, "effect", "--name", name,
        "--request", request_path, "--response", response_path },
      timeout = timeout or 30,
    }
    if listener_options ~= nil then
      if type(spec.apply_listener_options) == "function" then
        spec.apply_listener_options(exec_request, listener_options, request, name)
      else
        exec_request.listener_options = listener_options
      end
    end
    local result = ports.exec_argv(exec_request)
    local exit_code = type(result) == "table" and tonumber(result.exit_code) or nil
    local decoded = read_response(ports, response_path)
    local allow_legacy = legacy_response_allowed(cli, request, name)

    if type(decoded) == "table" then validate_request_id(decoded, request_id, allow_legacy, name) end
    if exit_code ~= 0 then error(failure_message(name, exit_code, result, decoded)) end
    if type(decoded) ~= "table" or decoded.ok ~= true then
      local message = type(spec.effect_invalid_message) == "function"
        and spec.effect_invalid_message(name, decoded)
        or spec.effect_invalid_error or (spec.error_prefix .. "-runtime-effect-invalid: " .. name)
      if type(decoded) == "table" and type(decoded.error) == "string" then
        message = message .. " Host error=" .. bounded_text(decoded.error, 1024)
      end
      error(message)
    end
    return decoded.result
  end

  return client
end

return M
