local json_codec = require("testing_runtime.json")

local M = {}
local host_json = json

function M.new(responses)
  local files = {}
  local calls = {}
  local modes = {}
  local fixture = { files = files, calls = calls, modes = modes }

  fixture.options = {
    runtime_cli = "fixtures/fake-runtime.js",
    exec_argv = function(request)
      if request.argv[2] == "-e" then
        table.insert(calls, { kind = "prepare", request = request })
        return { exit_code = modes.prepare_exit_code or 0 }
      end
      local name = request.argv[5]
      local request_path = request.argv[7]
      local response_path = request.argv[9]
      local payload = host_json.decode(files[request_path])
      table.insert(calls, { kind = "effect", name = name, request = request, payload = payload })
      local response = responses[name]
      if type(response) == "function" then response = response(payload, request) end
      if modes.no_response ~= true then
        local envelope = type(response) == "table" and response or { ok = true, result = response }
        if envelope.ok == nil then envelope = { ok = true, result = envelope } end
        if modes.missing_request_id ~= true then
          envelope.request_id = modes.request_id or payload.request_id
        end
        files[response_path] = json_codec.encode(envelope) .. "\n"
      end
      return {
        exit_code = modes.exit_code or 0,
        stdout = modes.stdout or "",
        stderr = modes.stderr or "",
      }
    end,
    file = {
      write = function(path, body) files[path] = body return true end,
      read = function(path)
        if modes.read_error then error("read failed") end
        return files[path]
      end,
    },
    json = {
      decode = function(body)
        if modes.decode_error then error("decode failed") end
        return host_json.decode(body)
      end,
    },
  }

  function fixture.effect_calls()
    local result = {}
    for _, call in ipairs(calls) do
      if call.kind == "effect" then table.insert(result, call) end
    end
    return result
  end

  return fixture
end

return M
