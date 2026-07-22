local M = {}

local required = { "load_state", "save_state", "list_pending_states", "artifact_digest" }

function M.production()
  local ports = _G.module_test_loop_runtime
  if type(ports) ~= "table" then
    local runtime = require("runtime")
    if os.getenv("FKST_MODULE_TEST_LOOP_TEST_RUNTIME") == "1" then
      ports = runtime.testing()
    else
      ports = runtime.production()
    end
  end
  for _, name in ipairs(required) do
    if type(ports[name]) ~= "function" then
      error("module-test-loop: runtime-port-unavailable: " .. name)
    end
  end
  return ports
end

function M.resolve(ports)
  if ports == nil then return M.production() end
  for _, name in ipairs(required) do
    if type(ports[name]) ~= "function" then error("module-test-loop: invalid-runtime: " .. name) end
  end
  return ports
end

return M
