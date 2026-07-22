local json_codec = require("testing_runtime.json")

local R = {}
local default_runtime_cli = "packages/module-test-loop/bin/module-test-loop-runtime.js"

local function error_excerpt(value)
  local text = tostring(value or "")
  text = text:gsub("[%z\1-\31\127]", " ")
  text = text:gsub("%s+", " ")
  if #text > 1024 then return text:sub(1, 1024) end
  return text
end

local function runtime_cli()
  local value = rawget(_G, "module_test_loop_runtime_cli") or default_runtime_cli
  if type(value) ~= "string" or value == "" or #value > 4096 or value:find("[%z\1-\31\127]") ~= nil then
    error("module-test-loop: runtime-cli-invalid: executable path is invalid")
  end
  return value
end

local function call(name, request)
  if type(exec_argv) ~= "function" then error("module-test-loop: runtime-port-unavailable: exec_argv") end
  if type(json) ~= "table" or type(json.decode) ~= "function" then
    error("module-test-loop: runtime-port-unavailable: json.decode")
  end
  local result = exec_argv({
    argv = { "node", runtime_cli(), name },
    env = { FKST_MODULE_TEST_LOOP_REQUEST_JSON = json_codec.encode(request) },
    timeout = 30,
  })
  local exit_code = type(result) == "table" and tonumber(result.exit_code) or nil
  if exit_code ~= 0 then
    error("module-test-loop: runtime-effect-failed: " .. name .. " exit=" .. tostring(exit_code or -1)
      .. " stderr=" .. error_excerpt(type(result) == "table" and result.stderr or ""))
  end
  local ok, response = pcall(function()
    return json.decode(type(result) == "table" and result.stdout or "")
  end)
  if not ok or type(response) ~= "table" or response.ok ~= true then
    error("module-test-loop: runtime-effect-invalid: " .. name)
  end
  return response
end

local function test_file_read(path)
  if type(file) == "table" and type(file.read) == "function" then
    local ok, value = pcall(file.read, path)
    if not ok then value = nil end
    return value
  end
  local handle = io.open(path, "r")
  if handle == nil then return nil end
  local value = handle:read("*a")
  handle:close()
  return value
end

local function test_file_write(path, value)
  if type(file) == "table" and type(file.write) == "function" then
    file.write(path, value)
    return
  end
  local handle = assert(io.open(path, "w"))
  handle:write(value)
  handle:close()
end

local function test_decode(path)
  local body = test_file_read(path)
  if body == nil or body == "" then return nil end
  return json.decode(body)
end

function R.testing()
  local index_ref = ".testing/runs/module-test-loop-state-index.json"
  local function write_json(path, value)
    test_file_write(path, json_codec.encode(value) .. "\n")
  end
  return {
    load_state = function(state_ref)
      local state = test_decode(state_ref)
      if type(state) == "table" and state.phase == "terminal" then return nil end
      return state
    end,
    save_state = function(state_ref, state, expected)
      local current = test_decode(state_ref)
      local revision = type(current) == "table" and current.version or 0
      if type(current) == "table" and current.phase == "terminal" and expected == 0 then revision = 0 end
      if revision ~= expected or state.version ~= expected + 1 then return false end
      write_json(state_ref, state)
      local index = test_decode(index_ref) or {}
      local found = false
      for _, value in ipairs(index) do if value == state_ref then found = true end end
      if not found then table.insert(index, state_ref) end
      table.sort(index)
      write_json(index_ref, index)
      return true
    end,
    list_pending_states = function(limit)
      local result = {}
      for _, state_ref in ipairs(test_decode(index_ref) or {}) do
        local state = test_decode(state_ref)
        if type(state) == "table" and state.phase ~= "terminal" and #result < limit then
          table.insert(result, state_ref)
        end
      end
      return result
    end,
    artifact_digest = function(pointer)
      local byte = string.format("%02x", (#tostring(pointer) % 251) + 1)
      return string.rep(byte, 32)
    end,
  }
end

function R.production()
  return {
    load_state = function(state_ref)
      local response = call("load-state", { state_ref = state_ref })
      if response.found ~= true then return nil end
      return response.result
    end,
    save_state = function(state_ref, state, expected)
      local response = call("save-state", {
        state_ref = state_ref,
        state = state,
        expected_revision = expected,
      })
      return response.saved == true
    end,
    list_pending_states = function(limit)
      local response = call("list-pending-states", { limit = limit })
      return response.result or {}
    end,
    artifact_digest = function(pointer)
      local response = call("artifact-digest", { pointer = pointer })
      if response.found ~= true then error("module-test-loop: artifact-unavailable: " .. tostring(pointer)) end
      return response.digest
    end,
  }
end

return R
