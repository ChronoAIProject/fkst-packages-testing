local json_codec = require("testing_runtime.json")

local R = {}
local default_runtime_cli = "packages/testing-design/bin/testing-design-runtime.js"

local function bounded(value, limit)
  local text = tostring(value or ""):gsub("[%z\1-\31\127]", " "):gsub("%s+", " ")
  return text:sub(1, limit or 1024)
end

local function runtime_cli()
  local value = rawget(_G, "testing_design_runtime_cli") or default_runtime_cli
  if type(value) ~= "string" or value == "" or #value > 4096 or value:find("[%z\1-\31\127]") ~= nil then
    error("testing-design: runtime-cli-invalid: executable path is invalid")
  end
  return value
end

local function require_capabilities()
  if type(exec_argv) ~= "function" then error("testing-design: runtime-port-unavailable: exec_argv") end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    error("testing-design: runtime-port-unavailable: json.decode")
  end
end

function R.production()
  return {
    analyze = function(request)
      require_capabilities()
      local encoded_request = json_codec.encode(request)
      local result = exec_argv({
        argv = { "node", runtime_cli(), "analyze-env" },
        env = { FKST_TESTING_DESIGN_REQUEST_JSON = encoded_request },
        timeout = 120,
      })
      local exit_code = type(result) == "table" and tonumber(result.exit_code) or nil
      if exit_code ~= 0 then
        error("testing-design: runtime-effect-failed: exit=" .. tostring(exit_code or -1)
          .. " stderr=" .. bounded(type(result) == "table" and result.stderr or ""))
      end
      local ok, response = pcall(function()
        return json.decode(type(result) == "table" and result.stdout or "")
      end)
      if not ok or type(response) ~= "table" or response.ok ~= true or type(response.result) ~= "table" then
        error("testing-design: runtime-effect-invalid: response envelope is invalid")
      end
      return response.result
    end,
  }
end

return R
