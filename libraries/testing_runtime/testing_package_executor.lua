local executor = require("testing_package_executor.executor")
local resolver = require("testing_runtime.package_resolver")

local M = {}

function M.resolve(request, host_ports) return resolver.resolve(request, host_ports) end

function M.try_resolve(request, host_ports)
  local ok, resolved = pcall(resolver.resolve, request, host_ports)
  if ok then return resolved end
  return resolver.failure_receipt(request, resolved)
end

function M.execute(request, host_ports)
  local resolved = resolver.resolve(request, host_ports)
  return executor.execute(resolved, host_ports)
end

return M
