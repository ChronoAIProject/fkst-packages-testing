local contract = require("contract.testing_package_executor")
local executor = require("testing_package_executor.executor")
local resolver = require("testing_runtime.package_resolver")

local M = {}

function M.resolve(request, host_ports) return resolver.resolve(request, host_ports) end

function M.failure_receipt(request, failure)
  return resolver.failure_receipt(request, failure)
end

local function execution_ports(host_ports)
  if type(host_ports) ~= "table" then return host_ports end
  return {
    check_freshness = host_ports.check_freshness,
    browser_read_title = host_ports.browser_read_title,
    write_canonical = host_ports.write_canonical,
    now = host_ports.now,
    sha256 = host_ports.sha256,
  }
end

function M.execute(request, host_ports)
  local resolved = resolver.resolve(request, host_ports)
  if resolved.schema == contract.schemas.admission_conflict then return resolved end
  return executor.execute(resolved, execution_ports(host_ports))
end

return M
