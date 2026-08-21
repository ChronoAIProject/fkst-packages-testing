local executor = require("testing_package_executor.executor")

local M = {}

function M.resolve(request, host_ports) return executor.resolve(request, host_ports) end

function M.execute(request, host_ports)
  local resolved = executor.resolve(request, host_ports)
  return executor.execute(resolved, host_ports)
end

return M
