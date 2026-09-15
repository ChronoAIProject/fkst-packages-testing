local json_codec = require("testing_runtime.json")
local generation_contract = require("contract.testing_design_generation")

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

local function codex_options()
  local configured = rawget(_G, "testing_design_codex")
  if configured ~= nil and type(configured) ~= "table" then
    error("testing-design: codex-config-invalid: expected table")
  end
  configured = configured or {}
  local options = {
    model_id = configured.model_id,
  }
  if type(options.model_id) ~= "string" or options.model_id == "" or #options.model_id > 4096
      or options.model_id:find("[%z\1-\31\127]") ~= nil then
    error("testing-design: codex-config-invalid: model_id is invalid")
  end
  for key, value in pairs(options) do
    if type(value) ~= "string" or value == "" or #value > 4096 or value:find("[%z\1-\31\127]") ~= nil then
      error("testing-design: codex-config-invalid: " .. key .. " is invalid")
    end
  end
  return options
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
    generate = function(request, control)
      require_capabilities()
      if type(control) == "table" and control.cancelled == true then
        return { ok = false, failure = { code = "cancellation" } }
      end
      generation_contract.validate_request(request)
      local options = codex_options()
      local payload = {
        input = {
          canonical_request = generation_contract.canonical_bytes(request),
          request_digest = generation_contract.canonical_digest(request),
          policy = request.policy,
          prompt_template = request.prompt_template,
          provider = {
            adapter_id = "codex-cli",
            adapter_version = "1.0.0",
            model_id = options.model_id,
          },
        },
      }
      local result = exec_argv({
        argv = { "node", runtime_cli(), "generate-codex-env" },
        env = { FKST_TESTING_DESIGN_GENERATION_JSON = json_codec.encode(payload) },
        timeout = math.ceil(request.policy.timeout_ms / 1000) + 5,
      })
      local exit_code = type(result) == "table" and tonumber(result.exit_code) or nil
      if exit_code ~= 0 then return { ok = false, failure = { code = "nonzero-exit" } } end
      local ok, response = pcall(function()
        return json.decode(type(result) == "table" and result.stdout or "")
      end)
      if not ok or type(response) ~= "table" or response.ok ~= true or type(response.result) ~= "table" then
        return { ok = false, failure = { code = "malformed-output" } }
      end
      return response.result
    end,
  }
end

return R
